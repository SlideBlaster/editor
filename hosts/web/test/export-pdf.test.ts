import test from "node:test";
import assert from "node:assert/strict";
import { exportPdf, exportPdfUrl, pdfStatus } from "../src/ui/export-pdf.ts";

test("the request names the deck entry, with steps on demand", () => {
  assert.equal(exportPdfUrl("http://127.0.0.1:4290", "talk.slideBlaster.md", false), "http://127.0.0.1:4290/export/pdf?entry=talk.slideBlaster.md");
  assert.equal(exportPdfUrl("http://h", "a b/c.slideBlaster.md", true), "http://h/export/pdf?entry=a%20b%2Fc.slideBlaster.md&steps=1");
});

test("a successful export reports the path; failures carry the server's reason", async () => {
  const seen: { url: string; method: string }[] = [];
  const ok = await exportPdf(async (url, init) => { seen.push({ url, method: init.method }); return { json: async () => ({ ok: true, path: "/d/talk.pdf", name: "talk.pdf" }) }; }, "http://h", "talk.slideBlaster.md", false);
  assert.deepEqual(seen, [{ url: "http://h/export/pdf?entry=talk.slideBlaster.md", method: "POST" }]);
  assert.equal(pdfStatus(ok), "PDF written: /d/talk.pdf");
  const over = await exportPdf(async () => ({ json: async () => ({ ok: true, path: "/d/talk.pdf", warnings: ["f: \"x\" runs 2% past the bottom"] }) }), "http://h", "talk.slideBlaster.md", false);
  assert.equal(pdfStatus(over), "PDF written: /d/talk.pdf, but 1 out of bounds: f: \"x\" runs 2% past the bottom");
  const no = await exportPdf(async () => ({ json: async () => ({ ok: false, error: "no Chrome or Chromium found" }) }), "http://h", "t.slideBlaster.md", false);
  assert.equal(pdfStatus(no), "PDF export failed: no Chrome or Chromium found");
  const down = await exportPdf(async () => { throw new Error("offline"); }, "http://h", "t.slideBlaster.md", false);
  assert.match(pdfStatus(down), /could not reach sb serve: offline/);
});
