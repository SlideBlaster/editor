import test from "node:test";
import assert from "node:assert/strict";
import { anchorOf, pageGeometry, printOrder, printPages, type DeckSlide } from "../src/offline-print.ts";

const plan = (n: number) => ({ step: n }) as never;
const slide = (frame: string, steps: number): DeckSlide => ({ frame, title: frame, steps, plans: Array.from({ length: steps }, (_, i) => plan(i + 1)) });
const deck = [slide("a", 1), slide("b", 3), slide("c", 2), slide("d", 1)];

test("print order follows the export order, then leftovers in file order", () => {
  assert.deepEqual(printOrder(deck, ["c", "a", "zzz"]).map((s) => s.frame), ["c", "a", "b", "d"]);
  assert.equal(printOrder(deck, undefined), deck);
});

test("default prints one page per slide with its final step", () => {
  const pages = printPages(deck, ["a", "b", "c", "d"], false);
  assert.equal(pages.length, 4);
  assert.deepEqual(pages.map((p) => (p.plan as unknown as { step: number }).step), [1, 3, 2, 1]);
  assert.ok(pages.every((p) => p.first && p.last));
});

test("steps prints one page per step; only the first page anchors the slide, the last carries the continue line", () => {
  const pages = printPages(deck, undefined, true);
  assert.equal(pages.length, 1 + 3 + 2 + 1);
  const b = pages.filter((p) => p.slide.frame === "b");
  assert.deepEqual(b.map((p) => [p.first, p.last]), [[true, false], [false, false], [false, true]]);
});

test("page is 960 px wide at the slide aspect (254 mm x 142.875 mm for 16:9)", () => {
  assert.deepEqual(pageGeometry(16 / 9), { width: 960, height: 540 });
  assert.deepEqual(pageGeometry(4 / 3), { width: 960, height: 720 });
  assert.equal(anchorOf("kid/x"), "sbframe-kid/x");
});
