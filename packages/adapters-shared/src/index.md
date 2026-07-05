# @slideblaster/adapters-shared — public surface

Platform-independent adapter implementations shared by the browser and native
shells. Exposes the shared `Compile` adapter; the Collab client attaches here at
M6.

## Exports

- `WasmLatexmlCompiler` — the `Compile` port (ADR 0009) via WASM latexml.
  Currently a scaffold: functional glue around an unbuilt engine (see
  `compile/wasmLatexmlCompiler.md`). Not wired into any shell yet.
- `LatexmlEngine` — the WASM conversion primitive the compiler is injected with;
  produced by `compile/engine/` (roadmap phases P0-P4).
- `buildTableDocument`, `finalizeHtml`, `CompileError` — the compiler's tested
  helpers, exported for reuse and golden-file testing.
