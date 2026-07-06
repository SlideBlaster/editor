# wasmLatexmlCompiler

The `Compile` port (ADR 0009) implemented with WASM latexml, shared by the browser
and native shells. Turns a LaTeX table environment into self-contained HTML.

## Status: built and wired

The engine is built (`engine/dist/perl-web.{js,wasm,data}`, Git LFS) and wired into
web-shell: a slide `tabular` renders as compiled HTML in the running product. The
compiler is injected with a `LatexmlEngine` — `createBrowserLatexmlEngine`
(in-process; Node/tests) or `createWorkerLatexmlEngine` (off the UI thread; the
shell). The app bridges the async port to the synchronous render/measure seam and
caches results ([app/tableCompiler.md](../../../app/src/tableCompiler.md)). Build
record: `engine/README.md`, project-root `spikes/wasm-latexml/`.

## Responsibility

Pure glue around a single conversion primitive:

- `buildTableDocument(latex)` wraps a bare `tabular` in the minimal `article`
  document + package set (`booktabs`, `multirow`, `threeparttable`, `array`) that
  latexml compiles. Kept identical to the prototype oracle so WASM output matches
  native latexml golden files.
- `finalizeHtml(raw)` reduces a LaTeXML HTML5 page to the embeddable fragment
  (extracts `<body>`, strips the LaTeXML footer, rejects empty output).
- `WasmLatexmlCompiler` composes those around the injected `LatexmlEngine`.

## Interface

- `LatexmlEngine.convert(latexDocument): Promise<string>` — the WASM boundary. One
  in-process tex -> HTML5 transform (no fork/exec; drives the LaTeXML Perl API,
  not a `latexml`+`latexmlpost` subprocess pair). Implemented by `engine/`.
- `new WasmLatexmlCompiler({ engine? })` — engine injected so the same glue is
  tested against a fake and, later, bundled per shell.
- `supports('table')` — true only when an engine is present, so the editor
  degrades gracefully when a shell ships without the compiler.
- `tableToHtml(latex)` — the port method. Throws `CompileError` (surfaced, never
  silent) when no engine is present or the engine fails.

## Invariants

- Pure transform: no filesystem, no network beyond the engine. Caching is the
  editor's concern, not this adapter's.
- Failure is a hard, surfaced `CompileError`, per the port contract.
- The document preamble is kept in lockstep with the table-compile oracle.

## Relates to

- Port contract: `@slideblaster/editor` `ports/compile.md`.
- Engine build: `engine/README.md`.
