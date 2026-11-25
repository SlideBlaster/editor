import test from "node:test";
import assert from "node:assert/strict";
import { bendThrough, shiftTrail, stepMiddle, alignDeltas, distributeDeltas, normalDegrees, rotationOf, slideTextPreset, writtenReplacement, attachSlot, filterPresets, followersOf, lineStyleButtons, nodeStyleButtons, optionOf, presets, snapDelta, toGrid } from "../src/ui/canvas-edit.ts";

test("the creation menu filters by typed words and puts a prefix match first", () => {
  assert.deepEqual(filterPresets("").map((p) => p.label), presets.map((p) => p.label));
  assert.deepEqual(filterPresets("box").map((p) => p.label), ["Box", "Accent box"]);
  assert.deepEqual(filterPresets("acc").map((p) => p.label), ["Accent box"]);
  assert.deepEqual(filterPresets("no").map((p) => p.label), ["Note"]);
  assert.deepEqual(filterPresets("zzz"), []);
});

test("a dragged centre snaps to another centre within reach, one axis at a time", () => {
  const others = [{ x: 400, y: 300 }, { x: 900, y: 120 }];
  assert.deepEqual(snapDelta({ x: 100, y: 100 }, { x: 294, y: 50 }, others, 10), { dx: 300, dy: 50, guideX: 400, guideY: null });
  assert.deepEqual(snapDelta({ x: 100, y: 100 }, { x: 50, y: 25 }, others, 10), { dx: 50, dy: 20, guideX: null, guideY: 120 });
  assert.deepEqual(snapDelta({ x: 100, y: 100 }, { x: 50, y: 60 }, others, 10), { dx: 50, dy: 60, guideX: null, guideY: null });
});

test("points land on a grid so the written coordinates stay short", () => {
  assert.equal(toGrid(327, 8), 328);
  assert.equal(toGrid(322, 4), 324);
});

test("a box dropped beside another takes the place on that side; elsewhere it stays free", () => {
  const box = { x: 0, y: 0, width: 100, height: 40 };
  const others = [{ id: "a", box: { x: 400, y: 300, width: 200, height: 60 } }];
  // below a: centre x 500, a's bottom edge 360 + gap 60 + half height 20 = 440
  assert.deepEqual(attachSlot(box, { x: 440, y: 410 }, others, 60, 30), { to: "a", side: "below", distance: null, dx: 450, dy: 420, x: 500, y: 440 });
  assert.equal(attachSlot(box, { x: 660, y: 300 }, others, 60, 30)?.side, "right");
  // past the top right corner: right edge 600 + 60 + 50 = 710, top edge 300 - 60 - 20 = 220
  assert.deepEqual(attachSlot(box, { x: 655, y: 205 }, others, 60, 30), { to: "a", side: "above right", distance: null, dx: 660, dy: 200, x: 710, y: 220 });
  assert.equal(attachSlot(box, { x: 100, y: 100 }, others, 60, 30), null);
  assert.equal(attachSlot(box, { x: 440, y: 410 }, [{ ...others[0]!, sides: ["above"] }], 60, 30), null, "a target offers only its own sides");
});

test("an attached box slides along its side to change the gap, and leaves it sideways", () => {
  const box = { x: 450, y: 420, width: 100, height: 40 };
  const others = [{ id: "a", box: { x: 400, y: 300, width: 200, height: 60 } }];
  const current = { to: "a", side: "below" as const };
  // dragged 101 further down, 6 sideways: gap 60 + 101 = 161 -> 160
  assert.deepEqual(attachSlot(box, { x: 6, y: 101 }, others, 60, 30, current), { to: "a", side: "below", distance: 160, dx: 0, dy: 100, x: 500, y: 540 });
  assert.equal(attachSlot(box, { x: 90, y: 101 }, others, 60, 30, current), null);
  assert.equal(attachSlot(box, { x: 6, y: 101 }, others, 60, 30), null, "a free box does not slide");
});

test("what is attached to a node, directly or through others, follows it", () => {
  const nodes = [
    { id: "a", attached: null },
    { id: "b", attached: { side: "below" as const, to: "a", distance: null } },
    { id: "c", attached: { side: "right" as const, to: "b", distance: 40 } },
    { id: "d", attached: null },
  ];
  assert.deepEqual(followersOf("a", nodes), ["b", "c"]);
  assert.deepEqual(followersOf("c", nodes), []);
});

test("the style bar shows what is on and offers one option change per button", () => {
  const options = [{ key: "draw", value: null }, { key: "fill", value: "yellow!30" }, { key: "fill", value: "blue!15" }];
  assert.equal(optionOf(options, "fill"), "blue!15", "a later option wins");
  assert.equal(optionOf(options, "draw"), true);
  assert.equal(optionOf(options, "thick"), undefined);
  const [fill, border, shape] = nodeStyleButtons(options);
  assert.deepEqual(fill!.filter((b) => b.on).map((b) => b.title), ["Fill: Blue"]);
  assert.deepEqual(fill![0]!.change, { set: [], remove: ["fill"] });
  assert.deepEqual(border![0], { label: "\u25a2", title: "Border", on: true, change: { set: [], remove: ["draw"] } });
  assert.deepEqual(shape!.find((b) => b.title === "Circle")!.change, { set: [{ key: "circle", value: null }], remove: ["rounded corners"] });
  const [tips] = lineStyleButtons([{ key: "->", value: null }]);
  assert.deepEqual(tips!.filter((b) => b.on).map((b) => b.title), ["Arrow at the end"]);
  assert.deepEqual(tips!.find((b) => b.title === "Arrows at both ends")!.change.set, [{ key: "<->", value: null }]);
  assert.ok(tips!.find((b) => b.title === "No arrowhead")!.change.remove.includes("->"));
});

test("typed slide text replaces what was written, and a new body brings its separators", () => {
  const body = { part: "body" as const, source: "Old text", before: "", after: "" };
  assert.equal(writtenReplacement(body, "New text\n\n"), "New text");
  assert.equal(writtenReplacement(body, "Old text"), null);
  assert.equal(writtenReplacement(body, ""), "");
  const empty = { part: "body" as const, source: "", before: "\n", after: "\n\n" };
  assert.equal(writtenReplacement(empty, "- one\n- two"), "\n- one\n- two\n\n");
  assert.equal(writtenReplacement(empty, "   "), null);
});

test("a title stays one line and is never emptied", () => {
  const title = { part: "title" as const, source: "Old", before: "", after: "" };
  assert.equal(writtenReplacement(title, "Two\nlines "), "Two lines");
  assert.equal(writtenReplacement(title, "  "), null);
});

test("slide text is offered in the menu only as an extra preset", () => {
  assert.deepEqual(filterPresets("slide", [...presets, slideTextPreset]).map((p) => p.label), ["Slide text"]);
  assert.equal(filterPresets("slide").length, 0);
});

const boxOf = (x: number, y: number, width: number, height: number) => ({ x, y, width, height });

test("lining up moves edges to the outermost edge and centres to the middle of the group", () => {
  const boxes = [boxOf(10, 10, 20, 10), boxOf(50, 40, 40, 20), boxOf(100, 0, 10, 60)];
  assert.deepEqual(alignDeltas(boxes, "left").map((d) => d.dx), [0, -40, -90]);
  assert.deepEqual(alignDeltas(boxes, "right").map((d) => d.dx), [80, 20, 0]);
  assert.deepEqual(alignDeltas(boxes, "centre").map((d) => d.dx), [40, -10, -45]);
  assert.deepEqual(alignDeltas(boxes, "top").map((d) => d.dy), [-10, -40, 0]);
  assert.deepEqual(alignDeltas(boxes, "bottom").map((d) => d.dy), [40, 0, 0]);
  assert.deepEqual(alignDeltas(boxes, "middle").map((d) => d.dy), [15, -20, 0]);
  assert.ok(alignDeltas(boxes, "left").every((d) => d.dy === 0));
});

test("even spacing keeps the outermost two and equalises the gaps between", () => {
  // given out of order: gaps of 10 and 50 become 30 and 30
  const boxes = [boxOf(100, 0, 20, 10), boxOf(0, 0, 20, 10), boxOf(30, 0, 20, 10)];
  assert.deepEqual(distributeDeltas(boxes, "x"), [{ dx: 0, dy: 0 }, { dx: 0, dy: 0 }, { dx: 20, dy: 0 }]);
  assert.deepEqual(distributeDeltas(boxes.slice(0, 2), "x"), [{ dx: 0, dy: 0 }, { dx: 0, dy: 0 }]);
  assert.deepEqual(distributeDeltas([boxOf(0, 0, 5, 10), boxOf(0, 12, 5, 10), boxOf(0, 90, 5, 10)], "y").map((d) => d.dy), [0, 33, 0]);
});

test("a turn is read from the rotate option and written in (-180, 180]", () => {
  assert.equal(rotationOf([{ key: "draw", value: null }, { key: "rotate", value: "30" }]), 30);
  assert.equal(rotationOf([{ key: "rotate", value: "x" }]), 0);
  assert.equal(rotationOf([]), 0);
  assert.deepEqual([0, 90, 180, 270, -90, 360, 450, -180].map(normalDegrees), [0, 90, 180, -90, -90, 0, 90, 180]);
});

test("a trail follows its ends: an elbow keeps its right angle, a curve carries its control points", () => {
  const none = { dx: 0, dy: 0 };
  // across then down: the corner keeps the start's height and the end's column
  assert.equal(shiftTrail("M 10 20 L 50 20 L 50 60", { dx: 4, dy: 6 }, none), "M 14 26 L 50 26 L 50 60");
  assert.equal(shiftTrail("M 10 20 L 50 20 L 50 60", none, { dx: 5, dy: 7 }), "M 10 20 L 55 20 L 55 67");
  // down then across
  assert.equal(shiftTrail("M 10 20 L 10 60 L 50 60", { dx: 4, dy: 6 }, { dx: 1, dy: 2 }), "M 14 26 L 14 62 L 51 62");
  assert.equal(shiftTrail("M 0 0 C 10 -10 30 -10 40 0", { dx: 1, dy: 2 }, { dx: 3, dy: 4 }), "M 1 2 C 11 -8 33 -6 43 4");
  assert.equal(shiftTrail("M 0 0 Q 1 1 2 2", none, none), "M 0 0 Q 1 1 2 2");
});

test("the middle of a step and the bend through a dragged point", () => {
  const el = (attrs: Record<string, string>) => ({ getAttribute: (k: string) => attrs[k] ?? null });
  assert.deepEqual(stepMiddle(el({ x1: "0", y1: "0", x2: "10", y2: "20" })), { x: 5, y: 10, tx: 10, ty: 20 });
  assert.deepEqual(stepMiddle(el({ d: "M 10 20 L 50 20 L 50 60" })), { x: 50, y: 20, tx: 40, ty: 40 });
  assert.deepEqual(stepMiddle(el({ d: "M 0 0 C 0 -8 8 -8 8 0" })), { x: 4, y: -6, tx: 8, ty: 0 });
  // travelling right on the screen, above the line is to the left
  assert.equal(bendThrough({ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 50, y: 0 }), 0);
  assert.equal(bendThrough({ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 50, y: -14.68 }), 30);
  assert.equal(bendThrough({ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 50, y: 14.68 }), -30);
  assert.equal(bendThrough({ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 50, y: -500 }), 90);
});
