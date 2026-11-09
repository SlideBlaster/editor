import test from "node:test";
import assert from "node:assert/strict";
import { createWebSocketTransport, sessionUrlFor, TransportError, type ConnectionState, type SocketLike } from "../src/transport/transport.ts";
import { decodeSessionResponse, requests, SessionWireError } from "../src/protocol/session.ts";
import { createFakeCore } from "../src/fixture/fake-core.ts";
import { createProjectStore, memoryBackend, ConflictError } from "../src/storage/project-store.ts";
import { readFileSync } from "node:fs";

class FakeSocket implements SocketLike {
  static all: FakeSocket[] = [];
  readyState = 0; sent: any[] = [];
  onopen: SocketLike["onopen"] = null; onclose: SocketLike["onclose"] = null; onerror: SocketLike["onerror"] = null; onmessage: SocketLike["onmessage"] = null;
  constructor() { FakeSocket.all.push(this); }
  open() { this.readyState = 1; this.onopen?.({}); }
  send(data: string) { this.sent.push(JSON.parse(data)); }
  close() { this.readyState = 3; this.onclose?.({}); }
  reply(body: unknown) { this.onmessage?.({ data: typeof body === "string" ? body : JSON.stringify(body) }); }
}
const source = new Uint8Array(readFileSync(new URL("../fixtures/plans/sample-deck.slideBlaster.md", import.meta.url)));
const okFrame = async (kind: string) => JSON.stringify((await createFakeCore({ source, figureDelayMs: null }).request(requests.workspaceSnapshot())) && { ...(await createFakeCore({ source, figureDelayMs: null }).request(requests.workspaceSnapshot())), kind });

function make() {
  FakeSocket.all = [];
  const timers: { cb: () => void; ms: number }[] = [];
  const transport = createWebSocketTransport({ url: "ws://x/session", createSocket: () => new FakeSocket(), schedule: (cb, ms) => timers.push({ cb, ms }), cancel: () => {} });
  const states: ConnectionState[] = [];
  transport.onState((s) => states.push(s));
  return { transport, timers, states };
}

test("requests are serialised: one in flight, answered in order", async () => {
  const { transport } = make();
  const socket = FakeSocket.all[0]!;
  socket.open();
  const a = transport.request(requests.workspaceSnapshot());
  const b = transport.request(requests.command("save"));
  assert.equal(socket.sent.length, 1, "the second request waits for the first answer");
  socket.reply(await okFrame("workspace_snapshot"));
  assert.equal((await a).kind, "workspace_snapshot");
  assert.equal(socket.sent.length, 2);
  assert.equal(socket.sent[1].command, "command");
  socket.reply(await okFrame("saved"));
  assert.equal((await b).kind, "saved");
});

test("requests made before the socket opens are sent once it does", async () => {
  const { transport, states } = make();
  const socket = FakeSocket.all[0]!;
  const pending = transport.request(requests.workspaceSnapshot());
  assert.equal(socket.sent.length, 0);
  socket.open();
  assert.equal(socket.sent.length, 1);
  socket.reply(await okFrame("workspace_snapshot"));
  await pending;
  assert.deepEqual(states, ["open"]);
});

test("view_updated frames are pushes, never mistaken for an answer", async () => {
  const { transport } = make();
  const socket = FakeSocket.all[0]!;
  socket.open();
  const pushes: string[] = [];
  transport.onPush((p) => pushes.push(p.kind));
  const pending = transport.request(requests.workspaceSnapshot());
  socket.reply(await okFrame("view_updated"));
  assert.deepEqual(pushes, ["view_updated"]);
  socket.reply(await okFrame("workspace_snapshot"));
  assert.equal((await pending).kind, "workspace_snapshot");
});

test("a dropped connection rejects the in-flight request, reports reconnecting and retries with backoff", async () => {
  const { transport, timers, states } = make();
  const first = FakeSocket.all[0]!;
  first.open();
  const pending = transport.request(requests.workspaceSnapshot());
  first.close();
  await assert.rejects(pending, TransportError);
  assert.deepEqual(states, ["open", "reconnecting"]);
  assert.equal(timers[0]!.ms, 250);
  timers[0]!.cb();
  assert.equal(FakeSocket.all.length, 2);
  FakeSocket.all[1]!.close();
  assert.equal(timers[1]!.ms, 500, "backoff doubles");
  timers[1]!.cb();
  FakeSocket.all[2]!.open();
  assert.equal(transport.state(), "open");
  const after = transport.request(requests.workspaceSnapshot());
  assert.equal(FakeSocket.all[2]!.sent.length, 1);
  FakeSocket.all[2]!.reply(await okFrame("workspace_snapshot"));
  await after;
});

test("closing the transport rejects waiting requests and stops reconnecting", async () => {
  const { transport, timers } = make();
  FakeSocket.all[0]!.open();
  const pending = transport.request(requests.workspaceSnapshot());
  transport.close();
  await assert.rejects(pending, TransportError);
  assert.equal(transport.state(), "closed");
  assert.equal(timers.length, 0);
  await assert.rejects(transport.request(requests.workspaceSnapshot()), TransportError);
});

test("the session URL follows the page origin unless overridden", () => {
  assert.equal(sessionUrlFor({ protocol: "http:", host: "127.0.0.1:4173", search: "" }), "ws://127.0.0.1:4173/session");
  assert.equal(sessionUrlFor({ protocol: "https:", host: "h", search: "" }), "wss://h/session");
  assert.equal(sessionUrlFor({ protocol: "http:", host: "h", search: "?session=ws://other/session" }), "ws://other/session");
});

test("responses are validated before use: wrong protocol, unknown effects and bad plans reject", async () => {
  const good = JSON.parse(await okFrame("workspace_snapshot"));
  assert.doesNotThrow(() => decodeSessionResponse(good));
  assert.throws(() => decodeSessionResponse({ ...good, protocol: "slideblaster.product/2" }), SessionWireError);
  assert.throws(() => decodeSessionResponse({ ...good, effects: [{ kind: "launch_missiles" }] }), SessionWireError);
  const badPlan = structuredClone(good);
  badPlan.view.navigator.items[0].audience.items[0].kind = "hologram";
  assert.throws(() => decodeSessionResponse(badPlan));
  assert.throws(() => decodeSessionResponse("not json"), SessionWireError);
  const failure = decodeSessionResponse({ protocol: "slideblaster.session/1", ok: false, kind: "error", error: { code: "stale_revision", message: "m" } });
  assert.equal(failure.ok, false);
});

test("requests are exact-keyed session/1 objects with base16 bytes", () => {
  const request = requests.applySourceReplace(4, { start: 2, end: 5 }, new Uint8Array([0x61]), new Uint8Array([0xc3, 0xa9]));
  assert.deepEqual(request, { protocol: "slideblaster.session/1", command: "apply_source_replace", revision: 4, start: 2, end: 5, expectedBase16: "61", replacementBase16: "c3a9" });
  assert.deepEqual(requests.command("undo", 3), { protocol: "slideblaster.session/1", command: "command", name: "undo", revision: 3 });
  assert.deepEqual(requests.selectSlide("why"), { protocol: "slideblaster.session/1", command: "select_slide", frame: "why" });
});

test("fixture core honours the revision fence and the expected-bytes fence", async () => {
  const core = createFakeCore({ source, figureDelayMs: null });
  const stale = await core.request(requests.applySourceReplace(9, { start: 0, end: 1 }, source.slice(0, 1), new Uint8Array([0x2d])));
  assert.equal(stale.ok === false && stale.error.code, "stale_revision");
  const wrong = await core.request(requests.applySourceReplace(0, { start: 0, end: 1 }, new Uint8Array([0x7a]), new Uint8Array([0x2d])));
  assert.equal(wrong.ok === false && wrong.error.code, "expected_mismatch");
  const fine = await core.request(requests.applySourceReplace(0, { start: 0, end: 3 }, source.slice(0, 3), new Uint8Array([0x2d, 0x2d, 0x2d])));
  assert.equal(fine.ok && fine.view.revision, 1);
  assert.equal(core.debug().source.startsWith("---"), true);
});

test("project store: create-only, compare-and-replace and path rules mirror /cap storage.save", async () => {
  const store = createProjectStore(memoryBackend());
  const a = new Uint8Array([1]); const b = new Uint8Array([2]);
  await store.save("talk.md", null, a);
  await assert.rejects(store.save("talk.md", null, b), ConflictError);
  await assert.rejects(store.save("talk.md", b, b), ConflictError);
  await store.save("talk.md", a, b);
  assert.deepEqual([...(await store.read("talk.md"))!], [2]);
  await assert.rejects(store.read("../x"), ConflictError);
  await assert.rejects(store.read("/abs"), ConflictError);
  assert.deepEqual(await store.list(), [{ path: "talk.md" }]);
});
