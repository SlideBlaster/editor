// esbuild driver. One self-contained ES module per entry, mirrored under dist/src/
// so the HTML pages and the browser smoke address them by stable paths.
import { build, context } from "esbuild";
import { cp, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";

const watch = process.argv.includes("--watch");
const entryPoints = [
  "src/main.ts",
  "src/alpha.ts",
  "src/presenter/audience-window.ts",
  "src/presenter/console-window.ts",
  "src/wasm/load-reactor.ts",
  "src/protocol/product-v2.ts",
].filter((entry) => existsSync(entry));

const options = {
  entryPoints,
  outdir: "dist/src",
  outbase: "src",
  bundle: true,
  format: "esm",
  splitting: true,
  chunkNames: "chunks/[name]-[hash]",
  target: "es2022",
  sourcemap: true,
  logLevel: "info",
  loader: { ".woff2": "dataurl", ".woff": "dataurl", ".svg": "text" },
};

await mkdir("dist", { recursive: true });
if (existsSync("../../themes")) {
  await cp("../../themes", "dist/themes", { recursive: true, force: true });
}
// The shape library: the catalog for the picker, and each family's shapes as named styles
// (`shapes/<family>.tikz`), which is what a deck's `\\node[family.name]` refers to.
const catalogDir = "../../packages/slideblaster-catalog";
if (existsSync(`${catalogDir}/data/drawio/catalog-v1.json`)) {
  await mkdir("dist/catalog", { recursive: true });
  await mkdir("dist/shapes", { recursive: true });
  await cp(`${catalogDir}/data/drawio/catalog-v1.json`, "dist/catalog/catalog-v1.json");
  await cp(`${catalogDir}/THIRD_PARTY_NOTICES.md`, "dist/catalog/THIRD_PARTY_NOTICES.md");
  const catalog = JSON.parse(await readFile(`${catalogDir}/data/drawio/catalog-v1.json`, "utf8"));
  const families = new Map();
  for (const shape of catalog.shapes) {
    const family = shape.id.split(".")[0];
    if (!families.has(family)) families.set(family, []);
    families.get(family).push(`\\tikzset{${shape.id}/.style={outline={${shape.path}}, minimum width=${shape.size.width}, minimum height=${shape.size.height}}}`);
  }
  const header = `% ${catalog.attribution.title}, ${catalog.attribution.author}, ${catalog.attribution.license}.\n% Generated from the SlideBlaster shape catalog. One named style per shape: its outline in a unit box\n% (x right, y down) and a starting size. A deck can define its own shapes the same way.\n`;
  for (const [family, lines] of families) await writeFile(`dist/shapes/${family}.tikz`, header + lines.join("\n") + "\n");
}
// The in-page core has no directory to list: name every bundled theme file for it.
if (existsSync("dist/themes")) {
  const walk = async (dir) => (await Promise.all((await readdir(dir, { withFileTypes: true })).map((e) => (e.isDirectory() ? walk(`${dir}/${e.name}`) : [`${dir}/${e.name}`])))).flat();
  const files = (await walk("dist/themes")).map((f) => f.slice("dist/themes/".length)).filter((f) => f !== "manifest.json").sort();
  await writeFile("dist/themes/manifest.json", JSON.stringify(files));
}
// Single-file bundle inlined into `sb build --html` pages (no splitting, no network).
await mkdir("dist/offline", { recursive: true });
await build({
  entryPoints: ["src/offline-viewer.ts"], outfile: "dist/offline/viewer.js", bundle: true, format: "iife",
  target: "es2022", minify: true, logLevel: "info", loader: options.loader,
});
await writeFile("dist/offline/viewer.css", (await readFile("app.css", "utf8")) + "\n" + (await readFile("offline-viewer.css", "utf8")));
if (watch) {
  const ctx = await context(options);
  await ctx.watch();
} else {
  await build(options);
}
