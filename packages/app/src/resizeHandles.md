# resizeHandles — contract

The node **resize** affordance on the interactive canvas. Over the *selected* node's
`.sb-handle`, `wireResizeGrips` attaches eight drag grips (four corners + four edges) that
resize the node by **scaling its content** — the rendered text, tables, and images grow
with the box, not just the frame.

## Model

Resize writes the TikZ content-scale options `scale` / `xscale` / `yscale` (via the engine
`resizeNode` op). The renderer (`render/slide.ts` `nodeDiv`) applies them as a
`transform: scale(sx, sy)` on the content div (origin top-left), and the layout
(`layout/resolve.ts`) multiplies the measured natural box by the scale, so relative peers
still reflow around the scaled box. `nodeScale(node)` reads the combined factor.

Scaling stays vector-sharp (it is a transform on live DOM, not a bitmap), and covers every
node kind uniformly (title, body, note, text, math, and table/image/column-containing
nodes are all just nodes). The natural box can still be shaped with `text width` (wrap) and
`minimum height` (floor); those compose with the scale.

## Interaction

- Grips are children of `.sb-handle`, hidden by CSS until `.sb-handle.is-selected`, so they
  ride the repaint-free selection toggle (`showSelection`) with no separate mount path.
- A grip drag previews live by setting the content div's `transform: scale(...)` and
  re-anchoring its top-left, tracking the handle to the reflowed box (DOM-measured). It
  commits ONCE on pointerup via `CanvasActions.resize` (→ `DeckActions.resize` →
  controller → `resizeNode`, mirroring `move`). For an absolutely-positioned node the
  controller also updates `at` (`center`) so the dragged edge's opposite side stays put.
- Holding **Shift** locks the aspect ratio (both axes scale by one dominant factor).
- The new scale is `currentScale × boxGrowthRatio` (the natural size cancels), so the
  gesture needs only the placed box + current scale — no natural-size lookup.
- Zoom scales the slide by width (no transform/zoom context), so the px→slide-unit math
  needs no zoom compensation — same as `wireHandle`.

## Notes

- A node's own `scale(...)` is composed with the move-preview translate in `wireHandle`, so
  a scaled node stays scaled while it is dragged to move (not just while it is resized).
- Resizing a node that contains a compiled table triggers the same out-of-band recompile as
  any commit on that slide; the table shows "render pending" briefly, then pops back scaled.
