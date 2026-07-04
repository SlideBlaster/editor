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
- **Arrows.** `\draw` path bodies are parsed here (they were verbatim until now):
  straight `--`/`-|`/`|-` segments whose `(name)` endpoints resolve to layout node
  anchors (B1) and `(x,y)` endpoints to points. Arrowheads come from `->`/`<-`/`<->`
  in the path options.
- **Content.** Each node's box holds `renderContent` output (B2); style classes
  become `sb-style-*` classes on both the SVG box and the content div.

Contract: pure, deterministic string output; headless and snapshot-testable. Limits:
straight segments only (no curves/`controls` yet); endpoints use node centers, not
border-clipped anchors; the stylesheet is a starting point, not the theme system.
