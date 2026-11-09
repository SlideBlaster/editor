// esbuild driver. One self-contained ES module per entry, mirrored under dist/src/
// so the HTML pages and the browser smoke address them by stable paths.
import { build, context } from "esbuild";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
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
