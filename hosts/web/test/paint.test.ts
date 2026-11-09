import test from "node:test";
import assert from "node:assert/strict";
import { parseHTML } from "linkedom";
import { paintPlan } from "../src/plan/paint.ts";
import { validatePlan, PlanError, type Plan } from "../src/protocol/plan.ts";
import { buildSampleView } from "../src/fixture/sample-view.ts";
import { katexProvider } from "../src/content/math.ts";
import { createShikiHighlighter } from "../src/content/highlight.ts";
import { readFileSync } from "node:fs";

const source = new Uint8Array(readFileSync(new URL("../fixtures/plans/sample-deck.slideBlaster.md", import.meta.url)));
const view = (figure: "pending" | "compiled" | "stale" | "absent" = "compiled") => buildSampleView({ revision: 3, source, figure });
const doc = () => parseHTML("<!doctype html><html><body></body></html>").document as unknown as Document;
const plan = (frame: string, surface: "audience" | "notes" = "audience", figure: "pending" | "compiled" | "stale" | "absent" = "compiled") => {
  const item = view(figure).navigator.items.find((i) => i.frame === frame)!;
  return validatePlan(surface === "audience" ? item.audience : item.notes);
};

test("the fixture plans satisfy the plan validator, including every beat", () => {
  const v = view();
  assert.equal(v.navigator.items.length, 6);
  for (const item of v.navigator.items) {
    validatePlan(item.audience);
    if (item.notes !== null) validatePlan(item.notes);
  }
});

test("layers: geometry svg, content, overlay; items are positioned in percent of the design size", () => {
  const painted = paintPlan(plan("results"), { doc: doc(), math: katexProvider, interactive: true });
  const slide = painted.element;
  assert.equal(slide.className, "sb-slide");
  assert.equal(slide.dataset.frame, "results");
  assert.deepEqual([...slide.children].map((c) => c.getAttribute("class")), ["sb-layer sb-layer-geometry", "sb-layer sb-layer-content", "sb-layer sb-layer-overlay"]);
  assert.equal(slide.querySelectorAll("svg.sb-layer-geometry rect.sb-rect").length, 1);
  assert.equal(slide.querySelectorAll("svg.sb-layer-geometry line[marker-end]").length, 1, "the arrow connector carries its marker");
  const flow = slide.querySelector(".sb-flow") as HTMLElement;
  assert.match(flow.style.left, /^(?:7\.\d+|5\.625)%$/);
  assert.equal(slide.querySelectorAll("table th").length, 3);
  assert.equal(slide.querySelectorAll("td")[1]!.getAttribute("style")?.includes("right"), true);
  assert.equal(slide.querySelectorAll(".sb-cite").length, 1);
});

test("interaction targets exist only on interactive surfaces and carry the node id", () => {
  const inert = paintPlan(plan("results"), { doc: doc(), math: katexProvider }).element;
  assert.equal(inert.querySelectorAll(".sb-hit").length, 0);
  const live = paintPlan(plan("results"), { doc: doc(), math: katexProvider, interactive: true, selection: "tk" }).element;
  const hits = [...live.querySelectorAll<HTMLElement>(".sb-hit")];
  assert.deepEqual(hits.map((h) => h.dataset.nodeId), ["tk", "tk-arrow"]);
  assert.equal(hits[0]!.getAttribute("aria-pressed"), "true");
  assert.equal(hits[1]!.getAttribute("aria-pressed"), "false");
});

test("overlay beats: reserved content keeps its place but is hidden", () => {
  const p = plan("why");
  assert.equal(p.step, 4);
  const step1 = (buildSampleView({ revision: 3, source, activeFrame: "why", activeStep: 0 }).active!.plan);
  const slide = paintPlan(validatePlan(step1), { doc: doc(), math: katexProvider }).element;
  const hidden = slide.querySelectorAll(".sb-reserved");
  assert.equal(hidden.length, 3, "two bullets and the definition box are reserved at step 1");
  for (const h of hidden) assert.equal((h as HTMLElement).style.visibility, "hidden");
  const full = paintPlan(p, { doc: doc(), math: katexProvider }).element;
  assert.equal(full.querySelectorAll(".sb-reserved").length, 0);
  assert.equal(full.querySelectorAll(".sb-box").length, 1);
  assert.equal(full.querySelectorAll(".katex").length, 2);
});

test("a missing math provider degrades to a labelled placeholder, not a failure", () => {
  const slide = paintPlan(plan("why"), { doc: doc() }).element;
  const absent = slide.querySelectorAll(".sb-math-absent");
  assert.equal(absent.length, 2);
  assert.match(absent[0]!.textContent ?? "", /math provider unavailable/);
});

test("compiled and stale figures carry their badge; placeholders say what is wrong", () => {
  const compiled = paintPlan(plan("arch"), { doc: doc() }).element;
  assert.equal(compiled.querySelector(".sb-badge")?.textContent, "compiled");
  assert.equal(compiled.querySelectorAll(".sb-artifact svg").length, 1);
  const stale = paintPlan(plan("arch", "audience", "stale"), { doc: doc() }).element;
  assert.equal(stale.querySelector(".sb-badge")?.textContent, "stale");
  assert.equal(stale.querySelector(".sb-figure-item")?.getAttribute("data-status"), "stale");
  const pending = paintPlan(plan("arch", "audience", "pending"), { doc: doc() }).element;
  assert.match(pending.querySelector(".sb-placeholder")?.textContent ?? "", /compiling/);
  const absent = paintPlan(plan("arch", "audience", "absent"), { doc: doc() }).element;
  assert.match(absent.querySelector(".sb-placeholder")?.textContent ?? "", /provider absent.*latex is not installed/);
});

test("code blocks show the step's highlighted lines and are upgraded by the highlighter", async () => {
  const painted = paintPlan(plan("prog"), { doc: doc(), math: katexProvider, highlighter: createShikiHighlighter() });
  const pre = painted.element.querySelector("pre.sb-code") as HTMLElement;
  assert.equal(pre.dataset.emphasis, "true");
  const flagged = [...pre.querySelectorAll<HTMLElement>(".sb-code-line")].filter((l) => l.dataset.hl === "1").map((l) => l.dataset.line);
  assert.deepEqual(flagged, ["3", "4"], "the last beat highlights lines 3-4");
  assert.equal(pre.dataset.highlighted, undefined);
  await painted.settled;
  assert.equal(pre.dataset.highlighted, "true");
  assert.ok(pre.querySelectorAll(".sb-code-line span").length > 6);
  assert.equal(pre.textContent!.split("\n").slice(0, 6).join("\n"), [
    "control Ingress(inout headers h) {",
    "  table fwd { key = { h.ipv4.dst: lpm; } actions = { route; drop; } }",
    "  apply {",
    "    fwd.apply();",
    "  }",
    "}",
  ].join("\n"));
});

test("unsafe links and hostile figure content never reach the DOM", () => {
  const base = plan("why") as Plan;
  const hostile: Plan = {
    ...base,
    items: [
      { kind: "text", id: "x", box: { x: 0, y: 0, width: 100, height: 40 }, visibility: "visible",
        style: { font: "serif", size: 20, weight: 400, italic: false, color: "#000000", align: "left", lineHeight: 1.2 },
        content: [{ t: "link", href: "javascript:alert(1)", children: [{ t: "text", text: "click" }] }] },
      { kind: "figure", id: "f", box: { x: 0, y: 50, width: 100, height: 100 }, fingerprint: "ff", fit: "contain", stale: false,
        artifact: { mime: "image/svg+xml", bytesBase16: Buffer.from(`<svg viewBox="0 0 1 1"><script>alert(1)</script><rect onclick="x()" width="1" height="1"/></svg>`).toString("hex") } },
    ],
  };
  const slide = paintPlan(validatePlan(hostile), { doc: doc() }).element;
  assert.equal(slide.querySelectorAll("a").length, 0);
  assert.equal(slide.querySelectorAll("script").length, 0);
  assert.equal(slide.innerHTML.includes("onclick"), false);
});

test("an unknown content kind is a protocol error, never silently skipped", () => {
  const bad = structuredClone(plan("why")) as any;
  bad.items[bad.items.length - 1].content?.push({ t: "marquee", children: [] });
  const flow = bad.items.find((i: any) => i.kind === "flow");
  flow.content.push({ t: "marquee", children: [] });
  assert.throws(() => validatePlan(bad), PlanError);
});

test("a route choice paints as a button carrying its route id", () => {
  const base = plan("results");
  const withRoute = JSON.parse(JSON.stringify(base));
  const flow = withRoute.items.find((i: { kind: string }) => i.kind === "flow");
  flow.content = [{ t: "route", route: "ai-first", children: [{ t: "text", text: "AI and software development", bold: false, italic: false, mono: false, color: null }] }];
  const painted = paintPlan(validatePlan(withRoute), { doc: doc(), math: katexProvider, interactive: false });
  const button = painted.element.querySelector("a.sb-route") as HTMLElement;
  assert.equal(button.getAttribute("data-route"), "ai-first");
  assert.equal(button.textContent, "AI and software development");
});
