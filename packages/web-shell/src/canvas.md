# interactive canvas (canvas.ts)

W4: direct manipulation of the rendered slide, driving the engine's E1 edit ops.

- **Overlay, not re-render.** `paintCanvas(stage, {picture, layout, selected, actions})`
  paints `renderSlide` output, then lays a transparent `.sb-overlay` of `.sb-handle`
  boxes over it, one per named node, positioned from the same `Layout` via the
  ADR-0014 slide(0..16 x 0..9, y-up) -> percentage map. No render logic is duplicated;
  only that coordinate mapping.
- **Gestures -> intent.** A handle reports `select` on pointer-down, and `move` on
  pointer-up if it actually dragged past a small threshold (a bare click is just
  selection). Empty overlay: click to deselect, double-click to `create` a node at
  that slide point. Delete is a keyboard action wired in the controller.
- **Live drag.** During a drag the handle and its rendered content
  (`.sb-node[data-node]`) are translated together for preview; the committed position
  is computed from the total pixel delta converted to slide units (y flips), then the
  controller applies `moveNodeTo` and re-renders (which clears the transforms).
- **Zoom-aware.** The whole canvas magnifies by scaling the slide width via
  `--zoom` ([zoom.ts](./zoom.md)). Rect-based conversions (`pointToUnits`,
  `pixelsToUnits`) stay correct because `getBoundingClientRect` returns the scaled
  slide rect; the live-drag preview translates in plain pixels (no transform/zoom
  context), so it already tracks the pointer 1:1.
- **Selection must not re-render.** `actions.select` only toggles handle state — a
  full re-render would replace the very element mid-drag and break pointer capture.
  `move`/`create`/`remove` re-serialize and re-render.
