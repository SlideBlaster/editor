# citeCompiler

The async->sync bridge for citations — the mirror of `tableCompiler` for the
bibliography. Loads the `.bib` (Storage port), numbers the whole deck, and serves the
engine's citation seams synchronously from a cache.

The render/measure seams are synchronous by contract (a slide re-renders in
isolation); loading + parsing the bibliography is async, and `\cite` numbering is
deck-wide and document-ordered. This module resolves both out of band, exactly once
per settled document, then the seams are pure lookups — so every render surface
(canvas, measurer, navigator, export) agrees.

## Seams (composed into `renderOptions` by `tableCompiler`)

- `renderCite(keys) -> string | undefined` — inline marker HTML, or undefined until
  the bibliography resolves (engine shows `[?]`).
- `renderBibliography() -> string | undefined` — the `\printbibliography` list.
- `renderFootnoteText(keys) -> string | undefined` — a footnote's reference text (the
  slide renderer numbers it).

## Lifecycle (called from createApp, like tableCompiler)

- `installCiteCompiler(storagePort, { onReady })` — wire the Storage port + a
  re-render callback. Absent port -> citations stay as placeholders (graceful degrade).
- `scheduleCiteCompile(doc)` — debounced (200 ms) recompute after edits; a no-op when
  nothing citation-relevant changed (see the signature guard). Fires `onReady`.
- `ensureCitations(doc)` — resolve now and await (export path).
- `resetCiteCompiler()` — test seam.

## Contract

- **`bibliography:` frontmatter** names the `.bib`, read via the Storage port relative
  to the working-copy root. Reloaded only when the path changes.
- **Deck-wide numbering** — one ordered walk (frames -> node statements -> runs, depth
  first) assigns each `\cite` key a number on first appearance in document order; the
  bibliography reads the completed counter, so it lists every cited key regardless of
  where `\printbibliography` sits.
- **Signature guard** — recompute/`onReady` fire only when a citation-relevant input
  (bib path, style, or any `\cite`/`\citefootnote`/`\printbibliography` in order)
  changed, so an `onReady` re-render cannot loop.
- **Graceful degradation** — no port, no `bibliography:`, or an unreadable/invalid
  `.bib` all leave citations unresolved (placeholders), never a crash.

Formatting + `.bib` parsing live in `citeRenderer`; footnote NUMBERING and the
slide-foot band are the engine's `render/slide` (numbering is per-slide, placement is
slide-level).
