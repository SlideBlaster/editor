import test from "node:test";
import assert from "node:assert/strict";
import { sanitizeSvg } from "../src/plan/svg-sanitize.ts";

const clean = (svg: string) => sanitizeSvg(svg)?.svg ?? null;

test("a plain dvisvgm-style figure survives and gains a viewBox from its size", () => {
  const out = sanitizeSvg(`<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="212.5pt" height="96" ><defs><path id="g1" d="M0 0L1 1"/></defs><use xlink:href="#g1" x="3"/><rect x="1" y="2" width="3" height="4"/></svg>`)!;
  assert.match(out.svg, /^<svg [^>]*viewBox="0 0 283\.3\d* 96"/);
  assert.equal(out.height, 96);
  assert.match(out.svg, /<use xlink:href="#g1" x="3"\/>/);
  assert.match(out.svg, /<rect x="1" y="2" width="3" height="4"\/>/);
});

test("script, foreignObject, event handlers and external references are removed", () => {
  const out = clean(`<svg viewBox="0 0 1 1" onload="evil()"><script>alert(1)</script><foreignObject><div>x</div></foreignObject><a href="http://evil"><rect onclick="x()" width="1" height="1"/></a><image href="http://evil/x.png"/><image href="data:image/png;base64,AAA"/><use href="#ok"/><use href="https://evil/#x"/><rect style="fill:url(http://evil/p)" width="1" height="1"/><rect style="fill:url(#grad)" width="1" height="1"/></svg>`)!;
  for (const bad of ["script", "alert", "foreignObject", "onload", "onclick", "evil", "<a"]) assert.equal(out.includes(bad), false, `still contains ${bad}: ${out}`);
  assert.match(out, /<image href="data:image\/png;base64,AAA"\/>/);
  assert.match(out, /<use href="#ok"\/>/);
  assert.match(out, /fill:url\(#grad\)/);
});

test("non-svg and malformed input is rejected", () => {
  assert.equal(clean("<div>hi</div>"), null);
  assert.equal(clean(""), null);
  assert.equal(clean("<svg"), null);
});

test("entities and doctype tricks do not smuggle markup", () => {
  const out = clean(`<!DOCTYPE svg [<!ENTITY x "<script>">]><svg viewBox="0 0 1 1"><text>&lt;script&gt; a &amp; b</text></svg>`)!;
  assert.equal(out.includes("<script"), false);
  assert.match(out, /&lt;script&gt; a &amp; b/);
});
