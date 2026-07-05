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
- **Inline content editing (W6, whole-node).** Double-click a handle opens a raw-body
  `textarea` (`.sb-inline-editor`) over the node, seeded from the engine's
  `serializeBody(content)` and positioned by the same slide-space box (scales with
  zoom). It **commits on blur or Ctrl/Cmd+Enter** by firing `editContent(name, body)`;
  plain Enter stays a newline (lists, `\\`); **Escape cancels**. A no-op edit does not
  commit. The controller re-parses the body (`parseContent`) — out-of-subset input
  becomes preserved error content (ADR 0015), never a crash. `keydown` is stopped so
  Delete / Space / zoom shortcuts stay inert while typing. Per-construct (sub-node)
  editing is a later refinement; this replaces the whole node body.
- **Live drag with snapping.** During a drag the pointer's free target (slide space,
  y-up) is passed through the [snap resolver](./snap.md) against every other box on the
  slide; the snapped center drives the preview (handle + `.sb-node[data-node]`
  translated together) and is what commits on pointer-up via `moveNodeTo`. **Hold Alt**
  to bypass snapping and place freely (ux/positioning-snapping.md). The re-render after
  commit clears the transforms. Snapping only adjusts the *absolute* drop point —
  choosing relative binding (`[below=of img]`) is the E2 drop, deferred.
- **Snap guides.** While a drag engages a snap, `drawGuides` paints an SVG layer
  (`svg.sb-guides`, viewBox `0 0 16 9`, stretched, non-scaling strokes) over the slide:
  solid accent lines for edge/center/slide-guide alignment, dashed segments for the two
  equal gaps of a spacing snap. The layer is rebuilt each move and removed on pointer-up
  / cancel. Slide space is y-up, the viewBox y-down, so guide y flips to `9 - y`.
- **Zoom-aware.** The whole canvas magnifies by scaling the slide width via
  `--zoom` ([zoom.ts](./zoom.md)). Rect-based conversions (`pointToUnits`, and the
  drag's own px->unit math) stay correct because `getBoundingClientRect` returns the
  scaled slide rect; the snap threshold is derived from a fixed pixel radius per drag,
  so snapping feels the same at every zoom. The live-drag preview translates in plain
  pixels (no transform/zoom context), so it already tracks the pointer 1:1.
- **Selection must not re-render.** `actions.select` only toggles handle state — a
  full re-render would replace the very element mid-drag and break pointer capture.
  `move`/`create`/`remove` re-serialize and re-render.
