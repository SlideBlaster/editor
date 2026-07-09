# resizeHandles — contract

The node **resize** affordance on the interactive canvas. Over the *selected* node's
`.sb-handle`, `wireResizeGrips` attaches eight drag grips (four corners + four edges). What a
drag *does* depends on the node kind — `isReflowable(node.content)` picks the mode:

- A **text** node (prose, or an empty text box — anything whose content is text and holds no
  image / table / column-group run) **reflows**: the drag sets the box's `text width` /
  `minimum height`, so the text **rewraps at a constant font size** (the Google-Docs feel).
  The glyphs never stretch, and any stale content `scale` is cleared, so a box that had been
  stretched under the old behavior snaps back to natural on its first reflow drag.
- Every **other** node (built around an image, table, or column group) **scales**: the
  rendered content grows with the box via `scale` / `xscale` / `yscale`, so a picture keeps
  its aspect ratio and a table its typography.

## Model

Both modes go through the engine `resizeNode` op (and the canvas `resize` action):

- **Reflow** writes `text width=<n>` / `minimum height=<n>` — the natural box, wrapped by the
  measurer — and `scale=1` to drop any leftover stretch. The renderer lays the content out at
  that width and the browser rewraps it; font size is slide-relative (`cqw`), so it is
  unaffected. Horizontal grips (+ corners) set `text width`; vertical grips (+ corners) set
  `minimum height` (grow-only: it can't shrink the box below its content).
- **Scale** writes `scale` / `xscale` / `yscale`. The renderer (`render/slide.ts` `nodeDiv`)
  applies them as a `transform: scale(sx, sy)` on the content div (origin top-left), and the
  layout (`layout/resolve.ts`) multiplies the measured natural box by the scale, so relative
  peers reflow around the scaled box. `nodeScale(node)` reads the combined factor; scaling
  stays vector-sharp (a transform on live DOM, not a bitmap).

## Interaction

- Grips are children of `.sb-handle`, hidden by CSS until `.sb-handle.is-selected`, so they
  ride the repaint-free selection toggle (`showSelection`) with no separate mount path.
- A grip drag previews live and re-anchors the content div's top-left, tracking the handle to
  the resulting box (DOM-measured): a **reflow** drag sets the div's `width` / `min-height`
  and drops its transform so the browser rewraps the text; a **scale** drag sets
  `transform: scale(...)`. It commits ONCE on pointerup via `CanvasActions.resize` (→
  `DeckActions.resize` → controller → `resizeNode`, mirroring `move`). For an
  absolutely-positioned node the controller also updates `at` (`center`) so the dragged edge's
  opposite side stays put — a pure-width reflow keeps the TOP put and grows downward.
- Holding **Shift** locks the aspect ratio of a **scale** drag (both axes by one dominant
  factor); a reflow drag has no aspect to lock, so Shift is inert.
- A scale drag's new scale is `currentScale × boxGrowthRatio` (the natural size cancels) and a
  reflow drag reads the box straight off the placed geometry, so neither needs a natural-size
  lookup.
- Zoom scales the slide by width (no transform/zoom context), so the px→slide-unit math
  needs no zoom compensation — same as `wireHandle`.

## Notes

- A node's own `scale(...)` is composed with the move-preview translate in `wireHandle`, so
  a scaled node stays scaled while it is dragged to move (not just while it is resized).
- Resizing a node that contains a compiled table triggers the same out-of-band recompile as
  any commit on that slide; the table shows "render pending" briefly, then pops back scaled.
