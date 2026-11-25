import assert from "node:assert/strict";
import { test } from "node:test";
import { dragInFigure, drawingFills, drawingLines, drawingRoutes, pointInFigure, sizeFromCorner } from "../src/ui/drawing-edit.ts";
import { tipShape } from "../src/plan/paint.ts";

test("a drag on the page is a move in the figure: centimetres, right and up, in twentieths", () => {
  // a figure 800 plan pixels wide shown 400 wide, at 100 plan pixels to the centimetre
  assert.deepEqual(dragInFigure(100, -50, 400, 800, 100), { dx: 2, dy: 1 });
  assert.deepEqual(dragInFigure(-26, 13, 400, 800, 100), { dx: -0.5, dy: -0.25 });
  // a figure scaled to fit: fewer pixels to the centimetre, so the same drag goes further
  assert.deepEqual(dragInFigure(100, 0, 400, 800, 50), { dx: 4, dy: 0 });
  // a drag too short to matter is no move at all (and never minus zero)
  assert.deepEqual(dragInFigure(0.4, -0.4, 400, 800, 100), { dx: 0, dy: 0 });
});

test("the bar's colours are written as xcolor reads them, and each can be taken away", () => {
  for (const all of [drawingFills, drawingLines]) {
    assert.equal(all[0]![1], "none");
    assert.equal(new Set(all.map((entry) => entry[0])).size, all.length);
    for (const [, written] of all) assert.match(written, /^[a-z]+(![0-9]+(![a-z]+)?)?$/);
  }
});

test("a place on the page is a place in the picture: from the drawing's corner, y up", () => {
  // the drawing's top-left corner is the picture's (-1, 3); shown at half size, 100 plan pixels to the centimetre
  const shown = { left: 200, top: 100, width: 400 };
  assert.deepEqual(pointInFigure(200, 100, shown, 800, 100, { x: -1, y: 3 }), { x: -1, y: 3 });
  assert.deepEqual(pointInFigure(300, 150, shown, 800, 100, { x: -1, y: 3 }), { x: 1, y: 2 });
});

test("a node pulled by its corner grows about its centre, and never to nothing", () => {
  assert.deepEqual(sizeFromCorner({ x: 100, y: 100 }, { x: 175, y: 125 }, 400, 800, 100), { width: 3, height: 1 });
  assert.deepEqual(sizeFromCorner({ x: 100, y: 100 }, { x: 101, y: 100 }, 400, 800, 100), { width: 0.3, height: 0.3 });
});

test("every route the bar offers is one the core knows, and every tip has a shape", () => {
  assert.deepEqual(drawingRoutes.map((route) => route[0]), ["straight", "hv", "vh", "bend left", "bend right"]);
  for (const kind of ["to", "latex", "stealth", "triangle", "bar", "circle", "diamond", "square"] as const) {
    const shape = tipShape(kind);
    assert.match(shape.d, /^M /);
    assert.ok(shape.ref > 8 && shape.ref <= 10 && shape.wide > 0);
  }
});
