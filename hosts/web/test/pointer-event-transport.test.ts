import test from "node:test";
import assert from "node:assert/strict";

import { createPointerEventTransport } from "../src/ui/pointer-event-transport.ts";

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

function fact(type, pointerId = 7, sequence = 0) {
  return { type, pointerId, sequence };
}

async function turn() {
  await new Promise((resolve) => setImmediate(resolve));
}

test("one move is in flight and pointerup keeps only the captured final move", async () => {
  const calls: any[] = [];
  const firstMove = deferred();
  const finalMove = deferred();
  const transport = createPointerEventTransport((value) => {
    calls.push(value);
    if (value.type === "move" && value.sequence === 1) return firstMove.promise;
    if (value.type === "move" && value.sequence === 4) return finalMove.promise;
    return Promise.resolve();
  });

  await transport.begin(fact("down"));
  transport.move(fact("move", 7, 1));
  transport.move(fact("move", 7, 2));
  transport.move(fact("move", 7, 3));
  const terminal = transport.finish(7, fact("move", 7, 4), fact("up", 7, 4));
  assert.deepEqual(calls.map((value) => [value.type, value.sequence]), [
    ["down", 0], ["move", 1],
  ]);

  firstMove.resolve();
  await turn();
  assert.deepEqual(calls.map((value) => [value.type, value.sequence]), [
    ["down", 0], ["move", 1], ["move", 4],
  ]);
  finalMove.resolve();
  await terminal;
  assert.deepEqual(calls.map((value) => [value.type, value.sequence]), [
    ["down", 0], ["move", 1], ["move", 4], ["up", 4],
  ]);
  transport.move(fact("move", 7, 5));
  await turn();
  assert.equal(calls.length, 4, "events after terminal state are discarded");
});

test("cancel discards unsent moves and follows the already-dispatched move once", async () => {
  const calls: any[] = [];
  const inFlight = deferred();
  const transport = createPointerEventTransport((value) => {
    calls.push(value);
    return value.type === "move" ? inFlight.promise : Promise.resolve();
  });

  await transport.begin(fact("down", 9));
  transport.move(fact("move", 9, 1));
  transport.move(fact("move", 9, 2));
  const terminal = transport.cancel(9, fact("cancel", 9));
  const duplicate = transport.cancel(9, fact("lost_capture", 9));
  assert.deepEqual(calls.map((value) => value.type), ["down", "move"]);
  inFlight.resolve();
  await Promise.all([terminal, duplicate]);
  assert.deepEqual(calls.map((value) => value.type), ["down", "move", "cancel"]);
});

test("rejected dispatches settle the queue without unhandled terminal loss", async () => {
  const calls: any[] = [];
  const transport = createPointerEventTransport((value) => {
    calls.push(value.type);
    return value.type === "move" ? Promise.reject(new Error("transport failed")) : undefined;
  });

  await transport.begin(fact("down", 11));
  transport.move(fact("move", 11, 1));
  await transport.finish(11, fact("move", 11, 2), fact("up", 11, 2));
  assert.deepEqual(calls, ["down", "move", "move", "up"]);
});

async function assertImmediateReuseAfter(terminalType) {
  const calls: any[] = [];
  const oldMove = deferred();
  const oldTerminal = deferred();
  const newDown = deferred();
  const newMove = deferred();
  let unresolvedMoves = 0;
  let maximumUnresolvedMoves = 0;
  const transport = createPointerEventTransport((value) => {
    calls.push([value.type, value.sequence]);
    let pending: Promise<any> = Promise.resolve();
    if (value.type === "move" && value.sequence === 1) pending = oldMove.promise;
    if (value.type === terminalType) pending = oldTerminal.promise;
    if (value.type === "down" && value.sequence === 2) pending = newDown.promise;
    if (value.type === "move" && value.sequence === 3) pending = newMove.promise;
    if (value.type === "move") {
      unresolvedMoves += 1;
      maximumUnresolvedMoves = Math.max(maximumUnresolvedMoves, unresolvedMoves);
      pending = pending.finally(() => { unresolvedMoves -= 1; });
    }
    return pending;
  });

  await transport.begin(fact("down", 17, 0));
  transport.move(fact("move", 17, 1));
  const oldSettled = transport.cancel(17, fact(terminalType, 17, 1));
  const admitted: string[] = [];
  const nextDown = transport.begin(fact("down", 17, 2), () => admitted.push("new"));
  transport.move(fact("move", 17, 3));
  assert.deepEqual(calls, [["down", 0], ["move", 1]]);
  assert.deepEqual(admitted, []);

  oldMove.resolve();
  await turn();
  assert.deepEqual(calls, [["down", 0], ["move", 1], [terminalType, 1]]);
  assert.deepEqual(admitted, []);

  oldTerminal.resolve();
  await oldSettled;
  await turn();
  assert.deepEqual(calls, [["down", 0], ["move", 1], [terminalType, 1], ["down", 2]]);
  assert.deepEqual(admitted, ["new"]);

  newDown.resolve();
  await nextDown;
  await turn();
  assert.deepEqual(calls, [
    ["down", 0], ["move", 1], [terminalType, 1], ["down", 2], ["move", 3],
  ]);
  assert.equal(maximumUnresolvedMoves, 1);
  newMove.resolve();
  await transport.cancel(17, fact("cancel", 17, 3));
}

test("same pointer ID waits for cancel settlement before a new down", async () => {
  await assertImmediateReuseAfter("cancel");
});

test("same pointer ID waits for lost capture settlement before a new down", async () => {
  await assertImmediateReuseAfter("lost_capture");
});
