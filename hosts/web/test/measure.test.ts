import test from "node:test";
import assert from "node:assert/strict";
import { parseHTML } from "linkedom";
import { createDomMeasurer } from "../src/measure.ts";

const doc = () => parseHTML("<!doctype html><html><body></body></html>").document as unknown as Document;
const text = (s: string) => [{ t: "p", children: [{ t: "text", text: s }] }];
// A fake layout: 10 px per character, wrapping at the element's style width, 20 px per line.
const readBox = (el: HTMLElement) => {
  const width = Number.parseFloat(el.style.width);
  const chars = (el.textContent ?? "").length;
  const lines = Math.max(1, Math.ceil((chars * 10) / width));
  return { width, height: lines * 20 };
};

test("measurement answers one result per item, keyed as asked, and wraps at the requested width", async () => {
  const measurer = createDomMeasurer({ doc: doc(), paint: {}, readBox, fontsReady: async () => undefined });
  const results = await measurer.measureAll([
    { key: "a", content: text("x".repeat(10)), width: 400 },
    { key: "b", content: text("x".repeat(100)), width: 400 },
  ]);
  assert.deepEqual(results, [{ key: "a", width: 400, height: 20 }, { key: "b", width: 400, height: 60 }]);
});

test("results are cached by content, width and font; unchanged items are not re-read", async () => {
  const measurer = createDomMeasurer({ doc: doc(), paint: {}, readBox, fontsReady: async () => undefined, fontFamily: "serif" });
  const item = { key: "a", content: text("hello"), width: 300 };
  await measurer.measureAll([item]);
  assert.equal(measurer.stats.reads, 1);
  await measurer.measureAll([{ ...item, key: "renamed" }, item]);
  assert.equal(measurer.stats.reads, 1, "same content/width/font is a hit even under another key");
  assert.equal(measurer.stats.hits, 2);
  const again = await measurer.measureAll([{ ...item, width: 150 }]);
  assert.equal(measurer.stats.reads, 2, "a different width is a miss");
  assert.equal(again[0]!.height, 20);
  measurer.reset();
  await measurer.measureAll([item]);
  assert.equal(measurer.stats.reads, 3);
});

test("the offscreen slide is hidden, exactly design-width wide, and emptied after each batch", async () => {
  const d = doc();
  const measurer = createDomMeasurer({ doc: d, paint: {}, readBox, fontsReady: async () => undefined });
  await measurer.measureAll([{ key: "a", content: text("hi"), width: 100 }]);
  const root = d.querySelector(".sb-measure-root") as HTMLElement;
  assert.match(root.style.cssText, /visibility:\s*hidden/);
  assert.equal((root.querySelector(".sb-measure-slide") as HTMLElement).style.width, "1280px");
  assert.equal(root.querySelector(".sb-measure-slide")!.children.length, 0);
  measurer.dispose();
  assert.equal(d.querySelector(".sb-measure-root"), null);
});
