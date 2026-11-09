import test from "node:test";
import assert from "node:assert/strict";
import { createShikiHighlighter, canonicalLanguage, languageLoaders } from "../src/content/highlight.ts";
import { p4Keywords } from "../src/content/p4.tmLanguage.ts";
import { renderMath } from "../src/content/math.ts";

const p4Code = "control Ingress(inout headers h) {\n  table fwd { key = { h.ipv4.dst: lpm; } actions = { route; drop; } }\n  apply { fwd.apply(); }\n}";

test("the P4 grammar highlights the lstdefinestyle keywords and loads lazily", async () => {
  const loads: string[] = [];
  const highlighter = createShikiHighlighter({ onLoad: (name) => loads.push(name) });
  assert.deepEqual(loads, [], "nothing is loaded before the first block");
  const lines = await highlighter.highlight(p4Code, "p4");
  assert.ok(lines !== null);
  assert.equal(lines.length, 4);
  const colourOf = (line: number, text: string) => lines[line]!.find((t) => t.text === text)?.color;
  assert.ok(colourOf(0, "control") !== undefined, "control is a coloured keyword");
  assert.ok(colourOf(1, "table") !== undefined);
  assert.ok(colourOf(1, "lpm") !== undefined);
  assert.notEqual(colourOf(0, "control"), colourOf(0, "h"), "keywords differ from identifiers");
  assert.deepEqual(loads, ["p4"], "only the requested grammar was loaded");
  await highlighter.highlight("x = 1", "python");
  assert.deepEqual(loads, ["p4", "python"]);
});

test("unknown languages yield null so the painter keeps plain text", async () => {
  const highlighter = createShikiHighlighter();
  assert.equal(await highlighter.highlight("???", "klingon"), null);
  assert.equal(await highlighter.highlight("???", null), null);
  assert.equal(canonicalLanguage("hs"), "haskell");
  assert.equal(canonicalLanguage("P4_16"), "p4");
  for (const name of ["p4", "haskell", "c", "python", "bash"]) assert.ok(name in languageLoaders);
});

test("highlighting preserves the exact source text per line", async () => {
  const highlighter = createShikiHighlighter();
  const lines = await highlighter.highlight(p4Code, "p4");
  assert.deepEqual(lines!.map((line) => line.map((t) => t.text).join("")), p4Code.split("\n"));
});

test("KaTeX renders formulas and never throws on bad input", () => {
  assert.match(renderMath("\\mathsf{AG}\\,\\neg x", false), /class="katex"/);
  assert.match(renderMath("\\int_0^1 x\\,dx", true), /katex-display/);
  assert.doesNotThrow(() => renderMath("\\notamacro{", false));
  assert.match(renderMath("\\notamacro{", false), /katex-error|notamacro/);
});

test("every keyword of the LDWG p4style listing definition is coloured", async () => {
  const highlighter = createShikiHighlighter();
  for (const keyword of p4Keywords) {
    const lines = await highlighter.highlight(`${keyword} ident;`, "p4");
    const token = lines![0]!.find((t) => t.text === keyword);
    const plain = lines![0]!.find((t) => t.text.trim() === "ident");
    assert.ok(token !== undefined, `${keyword} is its own token`);
    assert.notEqual(token.color, plain?.color, `${keyword} is not painted like an identifier`);
  }
});
