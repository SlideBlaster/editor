# layout measure

`Measurer.measure(input) -> Size`: how big a node's content is, in slide units. The
layout pass depends only on this interface, never on real font metrics — the seam
that makes `resolve` headless and testable.

- `naiveMeasurer` — a deterministic character/line estimate (no DOM). Enough to
  place boxes; NOT faithful to rendered output. `title` style scales up; empty
  content is a small min box; `text width` fixes width and wraps for height.
- The real **DOM-measurement adapter** (render the node's HTML, read its box) is the
  flagged Track-0 risk. It needs a DOM and must await fonts/math, so it can't satisfy
  the sync `Measurer` — it implements `BatchMeasurer` instead and drops in behind
  `resolveLayoutAsync` with no change to the geometry solve.

- `BatchMeasurer.measureAll(inputs) -> Promise<Size[]>` — the async, batched twin.
  Batched because a DOM measurer wants to insert all of a slide's nodes, force one
  reflow, and read every box together; async because it may await `document.fonts.ready`
  or math typesetting. `asBatch(measurer)` lifts any sync `Measurer` (e.g. the naive
  one) to a `BatchMeasurer`, the headless default and the browser fallback.

Contract: `Measurer` is pure and deterministic. `MeasureInput` is `{ content,
styleClasses, textWidth? }`. A `BatchMeasurer` returns one `Size` per input, in order.
