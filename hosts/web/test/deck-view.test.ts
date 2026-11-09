import test from "node:test";
import assert from "node:assert/strict";
import { parseHTML } from "linkedom";
import { readFileSync } from "node:fs";
import { createDeckView, frameAtReadingLine } from "../src/ui/deck-view.ts";
import { clientToPlan } from "../src/ui/pointer-facts.ts";
import { buildSampleView } from "../src/fixture/sample-view.ts";
import { katexProvider } from "../src/content/math.ts";

const source = new Uint8Array(readFileSync(new URL("../fixtures/plans/sample-deck.slideBlaster.md", import.meta.url)));

function harness() {
  const { document } = parseHTML("<!doctype html><html><body><div id=s><div id=c></div></div><nav id=r></nav></body></html>");
  const selected: string[] = [];
  (document.getElementById("s") as any).scrollTo = () => {}; // layout-free DOM has no scrolling
  const view = createDeckView({
    doc: document as unknown as Document,
    scroller: document.getElementById("s") as unknown as HTMLElement,
    canvas: document.getElementById("c") as unknown as HTMLElement,
    rail: document.getElementById("r") as unknown as HTMLElement,
    paint: { math: katexProvider },
    sink: { pointer: async () => undefined, activate: async () => undefined },
    onSelect: (frame) => selected.push(frame),
  });
  return { document, view, selected, canvas: document.getElementById("c")!, rail: document.getElementById("r")! };
}

test("every navigator item is painted in the continuous preview and the rail; only the active slide is interactive", async () => {
  const h = harness();
  await h.view.update(buildSampleView({ revision: 1, source, activeFrame: "results" }));
  assert.equal(h.canvas.querySelectorAll(".deck-row").length, 6);
  assert.equal(h.rail.querySelectorAll(".slide-thumb").length, 6);
  assert.deepEqual([...h.canvas.querySelectorAll(".deck-row")].map((r) => r.getAttribute("data-frame")), ["title", "why", "prog", "arch", "results", "refs"]);
  const interactive = [...h.canvas.querySelectorAll(".deck-row")].filter((r) => r.querySelector(".sb-hit") !== null).map((r) => r.getAttribute("data-frame"));
  assert.deepEqual(interactive, ["results"]);
  assert.equal(h.rail.querySelectorAll(".sb-hit").length, 0, "thumbnails are never interactive");
  assert.equal(h.canvas.querySelector(".deck-row.is-current")?.getAttribute("data-frame"), "results");
  assert.equal(h.rail.querySelector(".slide-thumb.is-current")?.getAttribute("data-frame"), "results");
  assert.match(h.canvas.querySelector('[data-frame="why"] .deck-note')!.textContent ?? "", /outage story/);
  assert.match(h.canvas.querySelector('[data-frame="prog"] .deck-note')!.textContent ?? "", /No notes/);
});

test("an unchanged view repaints nothing; a new revision repaints only the slides whose plan changed", async () => {
  const h = harness();
  const first = buildSampleView({ revision: 1, source, activeFrame: "title" });
  await h.view.update(first);
  const before = new Map([...h.canvas.querySelectorAll(".deck-slide")].map((e) => [e.getAttribute("data-frame"), e.firstElementChild]));
  await h.view.update(buildSampleView({ revision: 1, source, activeFrame: "title" }));
  for (const el of h.canvas.querySelectorAll(".deck-slide")) assert.equal(el.firstElementChild, before.get(el.getAttribute("data-frame")));
  await h.view.update(buildSampleView({ revision: 2, source, activeFrame: "title" }));
  for (const el of h.canvas.querySelectorAll(".deck-slide")) assert.notEqual(el.firstElementChild, before.get(el.getAttribute("data-frame")), "a new revision carries new tickets");
});

test("removing a slide removes its row and thumbnail; clicking a thumbnail asks the core to select", async () => {
  const h = harness();
  const full = buildSampleView({ revision: 1, source });
  await h.view.update(full);
  const trimmed = { ...full, navigator: { ...full.navigator, slideCount: 5, items: full.navigator.items.filter((i) => i.frame !== "prog") } };
  await h.view.update(trimmed);
  assert.equal(h.canvas.querySelectorAll(".deck-row").length, 5);
  assert.equal(h.rail.querySelector('[data-frame="prog"]'), null);
  (h.rail.querySelector('[data-frame="arch"]') as unknown as HTMLElement).click();
  assert.deepEqual(h.selected, ["arch"]);
});

test("the rail follows the slide under the reading line, and the nearest one in gaps", () => {
  const rows = [{ frame: "a", top: 0, bottom: 400 }, { frame: "b", top: 440, bottom: 840 }, { frame: "c", top: 880, bottom: 1280 }];
  assert.equal(frameAtReadingLine(rows, { top: 0, height: 600 }), "a");
  assert.equal(frameAtReadingLine(rows, { top: 300, height: 600 }), "b");
  assert.equal(frameAtReadingLine(rows, { top: 700, height: 600 }), "c");
  assert.equal(frameAtReadingLine(rows, { top: 400 - 0.35 * 600 + 5, height: 600 }), "a", "in the gap, the nearer row wins");
  assert.equal(frameAtReadingLine([], { top: 0, height: 10 }), null);
});

test("client points map to plan pixels and reject points outside the slide", () => {
  const rect = { left: 100, top: 50, width: 640, height: 360 };
  const plan = { size: { width: 1280, height: 720 } };
  assert.deepEqual(clientToPlan(420, 230, rect, plan), { x: 640, y: 360 });
  assert.equal(clientToPlan(99, 230, rect, plan), null);
  assert.deepEqual(clientToPlan(99, 230, rect, plan, true), { x: 0, y: 360 });
  assert.equal(clientToPlan(0, 0, { ...rect, width: 0 }, plan), null);
});

test("an included slide is read-only: no interaction targets, and a badge that opens its deck", async () => {
  const opened: string[] = [];
  const { document } = parseHTML("<!doctype html><html><body><div id=s><div id=c></div></div><nav id=r></nav></body></html>");
  (document.getElementById("s") as any).scrollTo = () => {};
  const view = createDeckView({
    doc: document as unknown as Document,
    scroller: document.getElementById("s") as unknown as HTMLElement,
    canvas: document.getElementById("c") as unknown as HTMLElement,
    rail: document.getElementById("r") as unknown as HTMLElement,
    paint: { math: katexProvider },
    sink: { pointer: async () => undefined, activate: async () => undefined },
    onSelect: () => {},
    onOpenOrigin: (path) => opened.push(path),
  });
  const base = buildSampleView({ revision: 1, source, activeFrame: "results" });
  const origin = { deck: "kid", path: "../kid/talk.slideBlaster.md", readOnly: true, code: "include.read_only" };
  const items = base.navigator.items.map((i) => (i.frame === "results" ? { ...i, origin } : i));
  await view.update({ ...base, navigator: { ...base.navigator, items } });
  const row = document.querySelector('.deck-row[data-frame="results"]')!;
  assert.equal(row.querySelector(".sb-hit"), null, "the active included slide is not interactive");
  assert.match(row.querySelector(".deck-origin")!.textContent ?? "", /from kid/);
  (row.querySelector(".deck-origin-open") as HTMLElement).click();
  assert.deepEqual(opened, ["../kid/talk.slideBlaster.md"]);
  assert.equal(document.querySelector('.deck-row[data-frame="why"] .deck-origin'), null);
});
