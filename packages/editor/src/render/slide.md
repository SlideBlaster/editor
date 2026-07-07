# render slide (assembly)

`renderSlide(picture, layout, options?) -> string`: assemble the full layered DOM of
a slide (ADR 0014), `slideStylesheet()` a minimal base stylesheet so it is viewable
when mounted, and `slideStepCount(picture)` the number of overlay steps the slide
plays as (ADR 0018).

```
<div class="sb-slide">
  <svg class="sb-geometry" viewBox="0 0 16 9">  node boxes + \draw arrows
  <div class="sb-content">                      one absolutely-% -positioned node per box
  <div class="sb-footnotes">                     slide-foot band (only if \citefootnote used)
```

- **One mapping, two layers.** Slide space is `0..16 x 0..9`, y-up. The SVG geometry
  layer uses `viewBox="0 0 16 9"` with y flipped to SVG's y-down; content nodes are
  positioned by percentage of the same box. The layers register by construction (no
  two coordinate systems to sync — the ADR 0014 promise).
- **Arrows.** `connectorsOf(picture, layout)` resolves every drawable `\draw`. The
  **editable subset** (straight `--` + cubic `.. controls ..`, via
  [connector.ts](../tikz/connector.md)) yields both a structured `ConnectorPath`
  (`editable`, for the canvas) and SVG `pathData` (`M`/`L`/`C`, y flipped); a body
  outside the subset (`-|`, `to[...]`, …) falls back to a straight polyline path and
  `editable: null`. `(name)` endpoints resolve to the node's current center and
  `(name.north)` to that border anchor (N/S/E/W, corners, or centre); `(x,y)` to points;
  arrowheads come from `->`/`<-`/`<->`. Each `<path>` carries `data-arrow="<index>"`
  (index among path statements) so an editor can select / delete / reshape it
  (`deleteConnector`, `updateConnector`); because endpoints re-resolve every paint, a
  connector re-routes automatically when its nodes move.
- **Shape geometry.** Each node's SVG box is drawn by `shapeGeometrySvg` (see `shape.md`):
  a `<rect>` by default, an `<ellipse>` for a shape node, stroked (`sb-drawn`) when the node
  has `draw` and filled from `fill=…`. A plain text node has neither, so its box stays
  invisible — the outline is what makes a dragged-in shape a shape.
- **Content.** Each node's box holds `renderContent` output (B2); style classes
  become `sb-style-*` classes on both the SVG box and the content div. A named node's
  content div also carries `data-node="<name>"` so an editor can hit-test and address
  it (selection, drag, inline edit); harmless in the export DOM.
- **Overlays (ADR 0018).** `options.step` flows into `renderContent` so inline overlays
  step-gate. A node's own `overlay=<spec>` option (via `nodeOverlay`) reveals the whole
  node: when its spec is inactive at `options.step` the content div gets `sb-ov-hidden`
  (space reserved — geometry is the union of all steps, so nothing reflows) and carries
  `data-overlay="<spec>"`. With no step, every node shows (authoring view).
  `slideStepCount` is the max step any node references (its overlay spec or its inline
  content), at least 1 — it drives the step navigator and the one-page-per-step export.
- **Footnotes.** `renderSlide` supplies a per-slide `FootnoteSink` to the content
  render: each `\citefootnote` numbers in reading order across the slide's nodes, and
  the definitions collect into a `.sb-footnotes` band at the slide foot (Beamer-style).
  `options.renderFootnoteText(keys)` (app-supplied, has the bibliography) formats each
  reference; absent, it falls back to the raw keys. No footnotes -> no band. Numbering
  is per-slide; inline `\cite` numbering is deck-wide and lives in the app
  ([citeCompiler](../../../app/src/citeCompiler.md)).

- **Content block layout.** `slideStylesheet()` also carries the base visual layout for
  the structured content blocks `renderContent` emits, so a mounted slide is viewable
  without an app-level sheet: `columns` become a flex row (`.sb-columns`; each
  `.sb-column` grows by its inline `flex:<width>`), and a `matrix` is a spacing-only,
  centred grid of cells (`.sb-matrix`). This is the render (B) track of the otherwise
  fully-structured `columns`/`matrix` runs ([content.md](../model/content.md)). Type
  scale and richer theming layer on top (the app's `SLIDE_TYPE_CSS`).

Contract: pure, deterministic string output; headless and snapshot-testable. Limits:
the stylesheet is a starting point, not the theme system.
