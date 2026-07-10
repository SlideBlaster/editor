# Browser export (export.ts)

The browser adapter for the engine's export port. Turns `RenderedSlide[]` (engine
renderer output, sized by the DOM measurer so the artifact is faithful) into one
self-contained document that is both a presenter and a print-to-PDF source.

- **One document, two jobs.** `buildDeckDocument` inlines the engine `slideStylesheet()`
  and the shared `SLIDE_TYPE_CSS`, then adds screen chrome (each slide fits the viewport,
  scroll-snap + arrow/space/Home/End keys step through) and a `@media print` block (each
  slide becomes one 13.333in x 7.5in — standard 16:9 — page). So the exported `.html`
  presents offline AND prints to a clean slide PDF.
- **PDF = the browser's own print pipeline.** `printDeck` writes the document into a
  hidden iframe and calls `window.print()`; the user picks "Save as PDF". This renders
  the exact same DOM+CSS, the highest-fidelity path, and is what export.md commits to for
  the browser. It returns no `Blob` (the print dialog can't), so the port's
  `toPdf(): Promise<Blob>` remains the native (Tauri webview) / managed (hosted renderer)
  adapters' responsibility. The browser exposes the port-conformant `toStandaloneHtml`
  plus `downloadDeckHtml` and `printDeck`.
- **Trusted input.** Slide HTML is the engine's own output (no external assets); only the
  document `<title>` is escaped. The iframe is same-origin and removed on `afterprint`
  (with a timer fallback, since `afterprint` is not universally reliable).
- **Working-copy zip download.** `downloadZip(bytes, filename)` saves raw bytes as a `.zip`
  via the same Blob + object-URL + `<a download>` path as `downloadDeckHtml`. It is the
  browser glue for a whole-working-copy export (the codec is [workspaceZip.md](./workspaceZip.md));
  the app chrome hands it the codec's bytes.

The controller ([createApp.ts](./createApp.md)) builds `RenderedSlide[]` by rendering each
frame against `resolveLayoutAsync(picture, measurer)` — the same cached DOM measurements
the canvas uses — so what you export is what you see. **Overlays expand to one page per
step (ADR 0018):** a slide with N steps (`slideStepCount`) becomes N consecutive
`RenderedSlide`s, each rendered at `{ step }`, so both the on-screen presenter (arrow keys
advance step then slide, Beamer-style) and the printed PDF get one page per build step.
Geometry is step-invariant, so the layout is resolved once per slide and reused.
