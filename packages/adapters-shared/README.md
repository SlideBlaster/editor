# @slideblaster/adapters-shared

Platform-independent adapter implementations shared by browser and native shells:
the WASM latexml **Compile** adapter (ADR 0009) and the **Collab** client (Yjs
binding + y-webrtc / y-websocket providers, ADR 0011/0012).

## Present

- **Compile adapter** (`src/compile/`) — the `Compile` port via WASM latexml, as a
  **scaffold**: the LaTeX-document wrapping and standalone-HTML finalization are
  real and tested (unit tests + golden tests against the native `latexml` oracle);
  the WASM engine it drives is not built yet. `supports('table')` is `false` until
  an engine is injected, and `tableToHtml` throws a surfaced `CompileError`. **Not
  wired into any shell.** Engine build plan in `src/compile/engine/README.md`;
  feasibility record at project-root `spikes/wasm-latexml/`.

Collab client is empty until M6. See `../../PROJECT.md`.
