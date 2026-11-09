import { test } from "node:test";
import assert from "node:assert/strict";
import { anchoredScroll, centring, clampZoom, wheelFactor } from "../src/ui/free-zoom.ts";

test("zoom is clamped and a mouse notch is capped", () => {
  assert.equal(clampZoom(100), 6);
  assert.equal(clampZoom(0), 0.25);
  assert.equal(clampZoom(Number.NaN), 1);
  assert.ok(wheelFactor(-100, 0) < 1.4 && wheelFactor(-100, 0) > 1.3);
  assert.equal(wheelFactor(-3, 1), wheelFactor(-100, 0));
  assert.ok(Math.abs(wheelFactor(4, 0) * wheelFactor(-4, 0) - 1) < 1e-12);
});

test("the point under the pointer stays put", () => {
  // content x = (scroll + focal - inset) / zoom must be unchanged after the zoom
  const before = { scroll: 200, focal: 300, inset: 0, zoom: 1 };
  const after = anchoredScroll(before.scroll, before.focal, before.inset, before.zoom, 0, 2);
  assert.equal((after + before.focal - 0) / 2, (before.scroll + before.focal - before.inset) / before.zoom);
  assert.equal(centring(1000, 600), 200);
  assert.equal(centring(1000, 1600), 0);
  assert.equal(anchoredScroll(0, 100, 0, 1, 0, 0.5), 0);
});
