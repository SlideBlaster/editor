import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadTheme, validateTheme, ThemeError } from "../src/theme.ts";

const themes = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../themes");

for (const name of ["default", "fns"]) {
  test(`theme ${name}: data validates, files exist, prelude carries the design 3.4 defines`, () => {
    const data = validateTheme(JSON.parse(readFileSync(path.join(themes, name, "theme.json"), "utf8")));
    assert.equal(data.name, name);
    assert.deepEqual(data.aspect, [16, 9]);
    for (const file of [data.prelude, data.css]) assert.ok(existsSync(path.join(themes, name, file)), file);
    for (const item of data.furniture) if (typeof item.asset === "string") assert.ok(existsSync(path.join(themes, name, item.asset)), String(item.asset));
    const prelude = readFileSync(path.join(themes, name, data.prelude), "utf8");
    for (const define of ["\\newenvironment{block}", "\\newenvironment{alertblock}", "\\newcommand{\\defn}", "\\newcommand{\\lemma}"]) {
      assert.ok(prelude.includes(define), define);
    }
    for (const region of Object.values(data.regions)) {
      assert.ok(region.x >= 0 && region.y >= 0 && region.x + region.w <= 16 && region.y + region.h <= 9, "regions lie inside the 16x9 slide");
    }
  });
}

test("fns differs from default in furniture and fonts, not in region coordinates semantics", () => {
  const read = (n: string) => validateTheme(JSON.parse(readFileSync(path.join(themes, n, "theme.json"), "utf8")));
  const fns = read("fns"); const base = read("default");
  assert.ok(fns.furniture.some((f) => f.kind === "logo"));
  assert.ok(!base.furniture.some((f) => f.kind === "logo"));
  assert.notEqual(fns.fonts.sizes.title, base.fonts.sizes.title);
});

test("theme loading is by name only and tolerates a missing stylesheet", async () => {
  await assert.rejects(loadTheme("/", "../etc", async () => { throw new Error("no"); }), ThemeError);
  const files: Record<string, string> = { "/themes/x/theme.json": readFileSync(path.join(themes, "fns", "theme.json"), "utf8").replace('"fns"', '"x"') };
  const fetcher = async (url: string) => ({ ok: url in files, json: async () => JSON.parse(files[url]!), text: async () => files[url] ?? "" });
  const loaded = await loadTheme("/", "x", fetcher);
  assert.equal(loaded.css, "");
  assert.equal(loaded.data.name, "x");
});
