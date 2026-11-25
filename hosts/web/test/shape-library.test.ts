import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { validatePlan } from "../src/protocol/plan.ts";
import { createShapeLoader, isOutline, shapeLibrary } from "../src/ui/shape-library.ts";
import { filterPresets, menuShapeLimit, presets, shapePreset } from "../src/ui/canvas-edit.ts";

const catalog = JSON.parse(readFileSync(new URL("../../../packages/slideblaster-catalog/data/drawio/catalog-v1.json", import.meta.url), "utf8")) as unknown;

test("the shipped catalog loads whole, grouped, and every outline is plain path data", () => {
  const library = shapeLibrary(catalog);
  assert.equal(library.shapes.length, 2257);
  assert.equal(library.groups.reduce((n, g) => n + g.count, 0), 2257);
  assert.equal(library.groups[0]!.name, "Electrical");
  assert.ok(library.shapes.every((s) => s.width > 0 && s.height > 0 && /^[a-z0-9_-]+\./.test(s.id)));
});

test("search needs every word, ranks label matches first, and can stay inside a group", () => {
  const library = shapeLibrary(catalog);
  const clouds = library.search("cloud");
  assert.ok(clouds.length > 3);
  assert.ok(clouds[0]!.label.toLowerCase().startsWith("cloud"));
  assert.deepEqual(library.search("zzzz no such shape"), []);
  assert.ok(library.search("", "Flowchart").every((s) => s.category.startsWith("Flowchart")));
  assert.equal(library.search("", "Flowchart").length, library.groups.find((g) => g.name === "Flowchart")!.count);
  assert.equal(library.search("").length, 2257);
  const both = library.search("cloud callout");
  assert.ok(both.length >= 1 && both.every((s) => /cloud/i.test(`${s.label} ${s.keywords.join(" ")} ${s.category} ${s.id}`)));
});

test("a shape's menu entry writes only its style name", () => {
  const shape = shapeLibrary(catalog).search("decision")[0]!;
  const preset = shapePreset(shape);
  assert.deepEqual([preset.options, preset.text, preset.shape], [shape.id, "", shape]);
  assert.ok(menuShapeLimit < 10);
  assert.deepEqual(filterPresets("box", [...presets, preset]).map((p) => p.label), ["Box", "Accent box"]);
});

test("outline path data: only M L Q C A Z and numbers", () => {
  assert.ok(isOutline("M 0.5 0 L 1 0.5 Q .2 .3 1 1 C 0 0 1 1 0 1 A 0.1 0.1 0 0 1 1 1 Z"));
  assert.ok(isOutline("M0,0L1,1Z"));
  for (const bad of ["", "L 0 0", "M 0 0 H 1", "M 0 0 url(#x)", "M 0 0\" onload=\"x", "m 0 0 l 1 1", 5, null]) assert.equal(isOutline(bad), false, String(bad));
});

test("a plan path item is validated like the rest of the plan", () => {
  const item = { kind: "path", id: "pic-bg-a", box: { x: 0, y: 0, width: 10, height: 10 }, d: "M 0 0 L 1 1 Z", fill: null, stroke: { color: "#112233", width: 2, dash: null }, opacity: 1, hit: null };
  const plan = (it: unknown): unknown => ({ frame: "one", step: 1, steps: 1, size: { width: 1280, height: 720 }, items: [it] });
  let accepted = true;
  try { validatePlan(plan(item)); } catch (failure) { accepted = !/\.d\b|path/.test(String(failure)); }
  assert.ok(accepted, "a well-formed outline is not what a plan is refused for");
  assert.throws(() => validatePlan(plan({ ...item, d: "M 0 0 <script>" })));
});

test("the catalog is fetched once, and a failed fetch can be retried", async () => {
  let calls = 0;
  let ok = false;
  const load = createShapeLoader("x", async () => { calls += 1; return { ok, json: async () => catalog }; });
  await assert.rejects(load());
  ok = true;
  const [a, b] = await Promise.all([load(), load()]);
  assert.equal(a, b);
  assert.equal(calls, 2);
});
