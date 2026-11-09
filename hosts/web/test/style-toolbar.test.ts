import test from "node:test";
import assert from "node:assert/strict";
import { parseHTML } from "linkedom";
import { installStyleToolbar, readCanvasSelection, styleValueFrom, themeDialectOf } from "../src/ui/style-toolbar.ts";
import { paintPlan } from "../src/plan/paint.ts";
import { validatePlan } from "../src/protocol/plan.ts";

const page = () => parseHTML(`<!doctype html><html><body>
<div class="sb-item" data-node-id="tk"><span data-run-path="0.1">hello</span><span data-run-path="0.2">world</span></div>
<div class="sb-item" data-node-id="other"><span data-run-path="0">x</span></div>
<select id="theme-dialect"><option value="html">HTML</option><option value="latex" selected>LaTeX</option></select>
<input id="style-foreground" value="blue!40!black"><button id="style-apply-colour">Apply</button>
<button data-style-property="weight" data-style-value="bold">B</button>
<button data-style-property="underline" data-style-value="true">U</button>
</body></html>`).document as unknown as Document;

const selectionOf = (a: Node, ao: number, b: Node, bo: number) => ({ rangeCount: 1, getRangeAt: () => ({ startContainer: a, startOffset: ao, endContainer: b, endOffset: bo }) });

test("a selection across runs of one node reads as run paths and offsets", () => {
  const d = page();
  const [first, second] = [...d.querySelectorAll("[data-node-id=tk] span")];
  const selection = readCanvasSelection(selectionOf(first!.firstChild!, 2, second!.firstChild!, 3));
  assert.deepEqual(selection, { nodeId: "tk", start: { path: [0, 1], offset: 2 }, end: { path: [0, 2], offset: 3 } });
});

test("collapsed, cross-node and unaddressed selections are not styled", () => {
  const d = page();
  const spans = [...d.querySelectorAll("span")];
  assert.equal(readCanvasSelection(selectionOf(spans[0]!.firstChild!, 1, spans[0]!.firstChild!, 1)), null);
  assert.equal(readCanvasSelection(selectionOf(spans[0]!.firstChild!, 0, spans[2]!.firstChild!, 1)), null);
  assert.equal(readCanvasSelection(selectionOf(d.body, 0, d.body, 0)), null);
  assert.equal(readCanvasSelection(null), null);
  assert.equal(readCanvasSelection({ rangeCount: 0, getRangeAt: () => { throw new Error("none"); } }), null);
});

test("style values follow the wire vocabulary; colour expressions cross as text", () => {
  assert.deepEqual(styleValueFrom("weight", "bold"), { property: "weight", value: "bold" });
  assert.deepEqual(styleValueFrom("underline", "true"), { property: "underline", value: true });
  assert.deepEqual(styleValueFrom("strike", "false"), { property: "strike", value: false });
  assert.deepEqual(styleValueFrom("foreground", "blue!40!black"), { property: "foreground", colour: { kind: "expression", text: "blue!40!black" } });
  assert.equal(themeDialectOf("markdown"), "markdown");
  assert.throws(() => themeDialectOf("rtf"));
});

test("buttons send toggle and set intents; the host never decides what a toggle resolves to", async () => {
  const d = page();
  const sent: any[] = []; const status: string[] = [];
  const [first, second] = [...d.querySelectorAll("[data-node-id=tk] span")];
  installStyleToolbar({
    root: d as unknown as ParentNode, selection: () => selectionOf(first!.firstChild!, 0, second!.firstChild!, 5),
    revision: () => 7, send: async (r) => { sent.push(r); return { ok: true }; }, status: (m) => status.push(m),
  });
  (d.querySelector("[data-style-property=weight]") as HTMLElement).click();
  (d.querySelector("#style-apply-colour") as HTMLElement).click();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(sent.length, 2);
  assert.equal(sent[0].command, "style_node");
  assert.deepEqual([sent[0].revision, sent[0].nodeId, sent[0].themeDialect], [7, "tk", "latex"]);
  assert.deepEqual(sent[0].target, { kind: "between", start: { path: [0, 1], offset: 0 }, end: { path: [0, 2], offset: 5 } });
  assert.deepEqual(sent[0].effect, { kind: "toggle", style: { property: "weight", value: "bold" } });
  assert.deepEqual(sent[1].effect, { kind: "set", style: { property: "foreground", colour: { kind: "expression", text: "blue!40!black" } } });
  assert.equal(status.at(-1), "Verified Haskell style change adopted as exact source");
});
