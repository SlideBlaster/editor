# render slide (assembly)

`renderSlide(picture, layout, options?) -> string`: assemble the full layered DOM of
a slide (ADR 0014), and `slideStylesheet()` a minimal base stylesheet so it is
viewable when mounted.

```
<div class="sb-slide">
  <svg class="sb-geometry" viewBox="0 0 16 9">  node boxes + \draw arrows
  <div class="sb-content">                      one absolutely-% -positioned node per box
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
- **Content.** Each node's box holds `renderContent` output (B2); style classes
  become `sb-style-*` classes on both the SVG box and the content div. A named node's
  content div also carries `data-node="<name>"` so an editor can hit-test and address
  it (selection, drag, inline edit); harmless in the export DOM.

Contract: pure, deterministic string output; headless and snapshot-testable. Limits:
the stylesheet is a starting point, not the theme system.
