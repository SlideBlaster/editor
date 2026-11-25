/**
 * The session/1 core as a Wasm reactor in the page (milestone W-web): one request frame in, one
 * response frame out, both UTF-8 JSON. It performs no effects; `transport/in-page.ts` does.
 */
import { BrowserWasiPreview1 } from "./browser-wasi.ts";

export interface SessionCore {
  dispatch(frame: Uint8Array): Promise<Uint8Array>;
  /** The measured node sizes to keep in the project's cache, or `null`. */
  nodeSizes(): Promise<Uint8Array | null>;
}

type Exports = Record<string, (...args: unknown[]) => unknown>;

export async function loadSessionCore(baseUri: string, fetcher: (url: string) => Promise<Response> = (url) => fetch(url)): Promise<SessionCore> {
  const wasmUrl = new URL("./dist/slideblaster-web-wasm.wasm", baseUri);
  const jsffiUrl = new URL("./dist/slideblaster-web-wasm.js", baseUri);
  const exported: Exports = {};
  const jsffi = (await import(jsffiUrl.href)) as { default: (exports: Exports) => WebAssembly.ModuleImports };
  const wasi = new BrowserWasiPreview1();
  const imports: WebAssembly.Imports = { ghc_wasm_jsffi: jsffi.default(exported), wasi_snapshot_preview1: wasi.imports as WebAssembly.ModuleImports };
  const started = performance.now();
  const response = await fetcher(wasmUrl.href);
  if (!response.ok) throw new Error(`Could not load the SlideBlaster core: HTTP ${response.status}`);
  // Compiled as it arrives: quicker than waiting for all of it, and the browser keeps the compiled
  // code beside the file, so the next start does not compile again. (That needs the file served as
  // application/wasm; anything else falls back to compiling the bytes.)
  const spare = response.clone();
  const instantiated = await WebAssembly.instantiateStreaming(response, imports)
    .catch(async () => WebAssembly.instantiate(await spare.arrayBuffer(), imports));
  note("core.load", started, 0, 0);
  Object.assign(exported, instantiated.instance.exports);
  wasi.initialize(instantiated.instance);
  for (const name of ["sb_session_dispatch", "sb_session_node_sizes"]) {
    if (typeof exported[name] !== "function") throw new Error(`The SlideBlaster core does not export ${name}; rebuild it (scripts/build-wasm.sh)`);
  }
  return {
    async dispatch(frame) {
      const began = performance.now();
      const answer = (await exported.sb_session_dispatch!(frame)) as Uint8Array;
      note("core.dispatch", began, frame.length, answer.length);
      return answer;
    },
    async nodeSizes() { return ((await exported.sb_session_node_sizes!()) as Uint8Array | null) ?? null; },
  };
}

/** How long the core took: the last few hundred loads and requests, for whoever asks (`globalThis.__sbTimings`). */
function note(what: string, began: number, bytesIn: number, bytesOut: number): void {
  const holder = globalThis as { __sbTimings?: { what: string; ms: number; in: number; out: number }[] };
  const list = (holder.__sbTimings ??= []);
  list.push({ what, ms: Math.round((performance.now() - began) * 10) / 10, in: bytesIn, out: bytesOut });
  if (list.length > 400) list.splice(0, list.length - 400);
}
