# Compile port

The escape hatch for content the client renderer cannot draw itself. In v1 that is
exactly one thing: LaTeX **tables** to HTML (ADR 0009). TikZ is native (own
renderer), math is KaTeX, inline/list content is the AST — none of those touch this
port. General LaTeX is deferred.

## Contract

- `supports(kind)` is a capability probe so the editor can degrade gracefully when
  an adapter lacks a compiler.
- `tableToHtml` takes a LaTeX table environment and returns standalone HTML with
  inline styling (no external stylesheet). It is a pure transform: no filesystem,
  no network beyond the adapter's own engine.
- Failure is a hard, surfaced error (consistent with the out-of-subset policy), not
  a silent empty result.

## Adapters

Browser and native: WASM latexml. A JS table-subset is the interim fallback if the
WASM port slips (ADR 0009). Managed: server-side latexml fallback.
