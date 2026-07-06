# @slideblaster/adapters-shared — public surface

Platform-independent adapter implementations shared by the browser and native
shells. Exposes the shared `Compile` adapter; the Collab client attaches here at
M6.

## Exports

- `WasmLatexmlCompiler` — the `Compile` port (ADR 0009) via WASM latexml. The
  engine is built (`compile/engine/dist`) and wired into web-shell (tables render
  in the product); see `compile/wasmLatexmlCompiler.md`.
- `LatexmlEngine` — the WASM conversion primitive the compiler is injected with
  (one `tex document -> LaTeXML HTML5 page` transform).
- `createBrowserLatexmlEngine(opts)` — a `LatexmlEngine` driving the emscripten
  module in-process (Node/tests, or the worker's inner loop); `PerlModule`,
  `PerlModuleFactory`, `BrowserLatexmlEngineOptions` are its injected types.
- `createWorkerLatexmlEngine(worker)` — a `LatexmlEngine` that proxies each
  conversion to a Web Worker owning the interpreter, so the multi-second WASM
  boot/convert never blocks the UI thread; `LatexmlWorker` is its minimal Worker
  surface. The worker half is a static script the shell supplies (web-shell
  `public/latexml/worker.js`). See `compile/workerLatexmlEngine.md`.
- `buildTableDocument`, `finalizeHtml`, `CompileError` — the compiler's tested
  helpers, exported for reuse and golden-file testing.
