# layout measure

`Measurer.measure(input) -> Size`: how big a node's content is, in slide units. The
layout pass depends only on this interface, never on real font metrics — the seam
that makes `resolve` headless and testable.

- `naiveMeasurer` — a deterministic character/line estimate (no DOM). Enough to
  place boxes; NOT faithful to rendered output. `title` style scales up; empty
  content is a small min box; `text width` fixes width and wraps for height.
- The real **DOM-measurement adapter** (render the node's HTML, read its box) is the
  flagged Track-0 risk and drops in behind this same interface with no change to
  `resolve`.

Contract: pure and deterministic. `MeasureInput` is `{ content, styleClasses,
textWidth? }`.
