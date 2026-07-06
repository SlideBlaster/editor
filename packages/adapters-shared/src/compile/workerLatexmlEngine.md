# worker latexml engine (workerLatexmlEngine.ts)

`createWorkerLatexmlEngine(worker) -> LatexmlEngine`: the main-thread half of a
worker-hosted latexml. The WASM conversion is synchronous and multi-second on the
first (boot) call, so running it on the UI thread would freeze the editor. This
proxies every `convert(document)` to a Web Worker that owns the Perl interpreter.

## Split of responsibility

- **This module (main thread).** Correlates request/response by an incrementing id:
  `convert` posts `{ type: 'convert', id, tex }` and resolves when a matching
  `{ id, html }` returns (or rejects on `{ id, error }`). No queue here — the worker
  serializes — just a `Map<id, {resolve, reject}>`. `LatexmlWorker` is a minimal,
  DOM-lib-free Worker surface (`postMessage` + `addEventListener('message')`) so the
  proxy is testable with a fake.
- **The worker (shell-supplied static script).** `web-shell/public/latexml/worker.js`
  is a dependency-free classic worker so it can `importScripts` the emscripten
  MODULARIZE glue (module workers cannot). It boots the module once, serializes
  conversions on one promise chain (the interpreter is not re-entrant), and mirrors
  the `@INC` / driver constants of [browserLatexmlEngine.ts](./browserLatexmlEngine.md)
  — those two MUST stay in lockstep.

## Wiring (bundler-agnostic)

Like `createBrowserLatexmlEngine`, this takes no bundler knowledge. The shell owns
that: it constructs the `Worker`, hands the worker the asset URLs its bundler produced
via an `init` message (`{ type: 'init', jsUrl, wasmUrl, dataUrl }`), and passes the
worker here. The resulting `LatexmlEngine` is injected into `WasmLatexmlCompiler`,
which wraps the returned LaTeXML page with `buildTableDocument` / `finalizeHtml`.

`convert` returns the full LaTeXML HTML5 **page** (the compiler finalizes it to the
embeddable fragment on the main thread), matching the `LatexmlEngine` contract.
