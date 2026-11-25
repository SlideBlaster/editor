import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createFakeCore } from "../src/fixture/fake-core.ts";
import { sampleDefs } from "../src/fixture/sample-view.ts";
import { routeForKey, commandForKey, createChannelBus, createPresenterHub, createWindowState, formatTimer, type PresenterCommand } from "../src/presenter/model.ts";
import { requests } from "../src/protocol/session.ts";

const source = new Uint8Array(readFileSync(new URL("../fixtures/plans/sample-deck.slideBlaster.md", import.meta.url)));

/** Independent reference: the audience-capped beat list and a clamped zipper over it. */
const beats = sampleDefs.flatMap((def) => Array.from({ length: def.steps }, (_, step) => ({ frame: def.frame, step: step + 1, steps: def.steps })));
const clamp = (n: number) => Math.max(0, Math.min(beats.length - 1, n));

async function setup(theme: () => { name: string; css: string } | null = () => null) {
  const core = createFakeCore({ source, figureDelayMs: null });
  const bus = createChannelBus();
  const hubEndpoint = bus.endpoint();
  const audienceEndpoint = bus.endpoint();
  const consoleEndpoint = bus.endpoint();
  const navigatorOf = async () => {
    const response = await core.request(requests.workspaceSnapshot());
    if (!response.ok) throw new Error("snapshot");
    return response.view.navigator.items;
  };
  const items = await navigatorOf();
  const errors: string[] = [];
  const hub = createPresenterHub({
    channel: hubEndpoint, request: (r) => core.request(r), navigator: () => items, title: () => "P4Check", theme,
    now: () => 1_000_000, onError: (m) => errors.push(m),
  });
  const audience = createWindowState();
  const console_ = createWindowState();
  audienceEndpoint.onmessage = (e) => { audience.receive(e.data); };
  consoleEndpoint.onmessage = (e) => { console_.receive(e.data); };
  return { core, hub, audience, console_, audienceEndpoint, consoleEndpoint, errors };
}

test("opening the show tells both windows the first beat, the timer origin and the title", async () => {
  const s = await setup();
  await s.hub.open();
  for (const w of [s.audience, s.console_]) {
    assert.equal(w.views?.cursor, 0);
    assert.equal(w.views?.total, beats.length);
    assert.equal(w.timerOriginMs, 1_000_000);
    assert.equal(w.title, "P4Check");
  }
  assert.equal(s.audience.views?.audience.frame, "title");
  assert.equal(s.console_.views?.next?.frame, "why");
});

test("both windows get the deck theme's CSS with the slides, and again when it changes", async () => {
  let theme = { name: "fns", css: ".sb-slide .sb-code { font-size: .72em; }" };
  const s = await setup(() => theme);
  await s.hub.open();
  for (const w of [s.audience, s.console_]) assert.deepEqual(w.theme, theme);
  theme = { name: "fns", css: ".sb-slide .sb-code { font-size: .6em; }" };
  s.hub.refresh();
  for (const w of [s.audience, s.console_]) assert.deepEqual(w.theme, theme);
});

test("100 scripted commands from either window keep both windows on the core's cursor", async () => {
  const s = await setup();
  await s.hub.open();
  const commands: PresenterCommand[] = ["next", "back", "home", "end"];
  let seed = 7;
  const random = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  let cursor = 0;
  let clampedMoves = 0;
  for (let i = 0; i < 100; i += 1) {
    // Bias towards "next" so the script crosses slides and steps, with regular excursions.
    const command = random() < 0.55 ? "next" : commands[Math.floor(random() * commands.length)]!;
    const from = random() < 0.5 ? s.audienceEndpoint : s.consoleEndpoint;
    from.postMessage({ t: "command", command });
    await s.hub.idle();
    const before = cursor;
    cursor = command === "next" ? clamp(cursor + 1) : command === "back" ? clamp(cursor - 1) : command === "home" ? 0 : beats.length - 1;
    if (cursor === before) clampedMoves += 1;
    const expected = beats[cursor]!;
    for (const [name, w] of [["audience", s.audience], ["console", s.console_]] as const) {
      const v = w.views!;
      assert.equal(v.cursor, cursor, `${name} cursor after command ${i} (${command})`);
      assert.equal(v.audience.frame, expected.frame, `${name} frame after command ${i}`);
      assert.equal(v.audience.step, expected.step, `${name} step after command ${i}`);
      assert.equal(v.steps, expected.steps);
      assert.equal(v.total, beats.length, "notes cannot add beats");
      if (v.notes !== null) { assert.equal(v.notes.step, v.audience.step, "notes are projected at the audience's step"); assert.equal(v.notes.frame, v.audience.frame); }
      const next = beats[cursor + 1];
      assert.equal(v.next === null, next === undefined, `${name} next preview at ${cursor}`);
      if (next !== undefined) { assert.equal(v.next!.frame, next.frame); assert.equal(v.next!.step, next.step); }
    }
    assert.deepEqual(s.audience.views, s.console_.views, `windows diverged after command ${i}`);
  }
  assert.ok(clampedMoves > 0, "the script exercised both clamps");
  assert.equal(s.errors.length, 0);
  assert.equal(s.core.debug().cursor, cursor, "the core cursor is the single source of truth");
});

test("stale or reordered broadcasts are ignored by a window", () => {
  const w = createWindowState();
  const views = (cursor: number) => ({ t: "views" as const, seq: cursor, timerOriginMs: 0, title: "t", views: { cursor } as never });
  assert.equal(w.receive(views(5)), true);
  assert.equal(w.receive(views(4)), false);
  assert.equal(w.views?.cursor, 5);
  assert.equal(w.receive({ t: "closed", seq: 6 }), true);
  assert.equal(w.closed, true);
});

test("closing the show tells the windows; keys map to commands; timer formats", async () => {
  const s = await setup();
  await s.hub.open("prog");
  assert.equal(s.audience.views?.audience.frame, "prog");
  await s.hub.close();
  assert.equal(s.audience.closed, true);
  assert.equal(s.console_.closed, true);
  assert.deepEqual(["ArrowRight", " ", "PageDown", "ArrowLeft", "Home", "End", "x"].map(commandForKey), ["next", "next", "next", "back", "home", "end", null]);
  assert.equal(formatTimer(0), "00:00");
  assert.equal(formatTimer(61_999), "01:01");
  assert.equal(formatTimer(3_725_000), "1:02:05");
});

test("a late window that says hello is brought to the current beat", async () => {
  const s = await setup();
  await s.hub.open();
  s.audienceEndpoint.postMessage({ t: "command", command: "next" });
  await s.hub.idle();
  const late = createWindowState();
  s.consoleEndpoint.onmessage = (e) => { late.receive(e.data); };
  s.consoleEndpoint.postMessage({ t: "hello", role: "console" });
  assert.equal(late.views?.cursor, 1);
});

test("digit keys select the n-th route choice of the current slide, nothing elsewhere", () => {
  const views = { frame: "pick", step: 1, steps: 1, audience: null, notes: null, next: null, choices: [{ route: "ai", label: "AI" }, { route: "fm", label: "FM" }] } as never;
  assert.equal(routeForKey("1", views), "ai");
  assert.equal(routeForKey("2", views), "fm");
  assert.equal(routeForKey("3", views), null);
  assert.equal(routeForKey("0", views), null);
  assert.equal(routeForKey("a", views), null);
  assert.equal(routeForKey("1", { ...(views as object), choices: undefined } as never), null);
  assert.equal(routeForKey("1", null), null);
});

test("a route message becomes a present_route request and the hub follows the route's frame order for home and end", async () => {
  const sent: unknown[] = [];
  const bus = createChannelBus();
  const hubEndpoint = bus.endpoint();
  const windowEndpoint = bus.endpoint();
  const hub = createPresenterHub({
    channel: hubEndpoint,
    request: async (request) => { sent.push(request); return { ok: false, error: { code: "x", message: "stub" } } as never; },
    navigator: () => [{ frame: "a", steps: 1 }, { frame: "b", steps: 2 }, { frame: "c", steps: 1 }],
    title: () => "T",
  });
  windowEndpoint.postMessage({ t: "route", route: "fm" });
  await hub.idle();
  assert.deepEqual(sent[0], requests.presentRoute("fm"));
  hub.accept({ ok: true, view: { presenter: { frame: "c", step: 1, steps: 1, audience: null, notes: null, next: null, route: { id: "fm", default: "ai", frames: ["c", "a", "b"] } } } } as never);
  windowEndpoint.postMessage({ t: "command", command: "end" });
  await hub.idle();
  assert.deepEqual(sent[1], requests.presentGoto("b", 2));
  windowEndpoint.postMessage({ t: "command", command: "home" });
  await hub.idle();
  assert.deepEqual(sent[2], requests.presentGoto("c", 1));
});

test("an open window accepts a reloaded editor whose seq restarts", () => {
  const w = createWindowState();
  const views = {} as never;
  assert.equal(w.receive({ t: "views", hub: "a", seq: 7, views, timerOriginMs: 0, title: "x" }), true);
  assert.equal(w.receive({ t: "views", hub: "a", seq: 3, views, timerOriginMs: 0, title: "x" }), false);
  assert.equal(w.receive({ t: "views", hub: "b", seq: 1, views, timerOriginMs: 0, title: "x" }), true);
});
