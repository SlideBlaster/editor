import { BrowserWasiPreview1 } from "./browser-wasi.ts";

const wasmUrl = new URL("./dist/slideblaster-web-wasm.wasm", document.baseURI);
const jsffiUrl = new URL("./dist/slideblaster-web-wasm.js", document.baseURI);

/**
 * Instantiate, knot-tie, and initialize the GHC wasm32-wasi reactor.
 *
 * @returns {Promise<{
 *   dispatch(rawRequest: string): Promise<string>,
 *   productDispatch(rawRequest: string): Promise<string>,
 *   productV2Dispatch(rawRequest: string): Promise<string>
 * }>}
 */
export async function loadSlideBlasterReactor() {
  const exportedFunctions: Record<string, any> = {};
  const jsffi = await import(jsffiUrl.href);
  const wasi = new BrowserWasiPreview1();
  const imports = {
    ghc_wasm_jsffi: jsffi.default(exportedFunctions),
    wasi_snapshot_preview1: wasi.imports,
  };

  const response = await fetch(wasmUrl);
  if (!response.ok) {
    throw new Error(`Could not load Wasm artifact: HTTP ${response.status}`);
  }

  const instantiated = await instantiate(response, imports);
  Object.assign(exportedFunctions, instantiated.instance.exports);
  wasi.initialize(instantiated.instance);

  for (const name of [
    "sb_start",
    "sb_dispatch",
    "sb_product_dispatch",
    "sb_product_v2_dispatch",
  ]) {
    if (typeof exportedFunctions[name] !== "function") {
      throw new Error(`The Wasm reactor does not export ${name}`);
    }
  }

  await exportedFunctions.sb_start();
  return Object.freeze({
    async dispatch(rawRequest) {
      return await exportedFunctions.sb_dispatch(rawRequest);
    },
    async productDispatch(rawRequest) {
      return await exportedFunctions.sb_product_dispatch(rawRequest);
    },
    async productV2Dispatch(rawRequest) {
      return await exportedFunctions.sb_product_v2_dispatch(rawRequest);
    },
  });
}

async function instantiate(response, imports) {
  if (typeof WebAssembly.instantiateStreaming === "function") {
    try {
      return await WebAssembly.instantiateStreaming(response.clone(), imports);
    } catch (failure) {
      globalThis.console.warn(
        "Streaming Wasm instantiation failed; retrying from an ArrayBuffer",
        failure,
      );
    }
  }
  return await WebAssembly.instantiate(await response.arrayBuffer(), imports);
}
