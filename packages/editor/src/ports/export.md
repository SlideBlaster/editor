# Export port

Durable output artifacts built from already-rendered slides: PDF and a standalone
presenter HTML file. Client-side by default — the payoff of the own-renderer
decision (ADR 0008/0009).

## Contract

- Input is `RenderedSlide[]` — self-contained HTML the editor's renderer already
  produced (inline styles and SVG, no external assets). The port does not re-render
  or reach into the AST.
- `toPdf` returns a `Blob`. `toStandaloneHtml` returns one HTML string for the whole
  deck, openable offline.
- Deterministic given identical input, so exports are testable against golden files.

## Adapters

Browser: print-to-PDF via the browser. Native: Tauri webview print. Managed: a
hosted render service (later). Cross-shell print parity is a launch gate. See ADR 0009.
