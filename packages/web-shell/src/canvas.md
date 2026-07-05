# interactive canvas (canvas.ts)

W4: direct manipulation of the rendered slide, driving the engine's E1 edit ops.

- **Overlay, not re-render.** `paintCanvas(stage, {picture, layout, selected, actions})`
  paints `renderSlide` output, then lays a transparent `.sb-overlay` of `.sb-handle`
  boxes over it, one per named node, positioned from the same `Layout` via the
  ADR-0014 slide(0..16 x 0..9, y-up) -> percentage map. No render logic is duplicated;
  only that coordinate mapping.
- **Gestures -> intent.** A handle reports `select` on pointer-down, and `move` on
  pointer-up if it actually dragged past a small threshold (a bare click is just
  selection). Empty overlay: click to deselect, double-click to `requestCreate` (open
  the creation menu, [createMenu.ts](./createMenu.md)) at that slide point, passing the
  cursor's client coordinates so the popover anchors there. Delete is a keyboard action
  wired in the controller.
- **Auto-edit (W5).** `props.autoEdit` names a just-created node; after painting, its
  inline editor is opened immediately so a freshly-inserted element lands in edit mode
  with an empty caret. The controller supplies (and then clears) it.
- **Inline content editing (W6, whole-node).** Double-click a handle opens a raw-body
  `textarea` (`.sb-inline-editor`) over the node, seeded from the engine's
  `serializeBody(content)` and positioned by the same slide-space box (scales with
  zoom). It **commits on blur or Ctrl/Cmd+Enter** by firing `editContent(name, body)`;
  plain Enter stays a newline (lists, `\\`); **Escape cancels**. A no-op edit does not
  commit. The controller re-parses the body (`parseContent`) — out-of-subset input
  becomes preserved error content (ADR 0015), never a crash. `keydown` is stopped so
  Delete / Space / zoom shortcuts stay inert while typing. Per-construct (sub-node)
  editing is a later refinement; this replaces the whole node body.
- **Live drag: bind, snap, or detach.** Each move computes a `DragOutcome`. First it
  asks the [binding resolver](./binding.md) whether the node should bind relative to a
  peer (E2); if so the outcome is `bind` and the preview lands at the binding's resolved
  center. Otherwise it runs the [snap resolver](./snap.md) for an absolute center
  (`move`). A relative node dragged out of every binding's range therefore falls through
  to an absolute `move` — that IS the **detach**. On pointer-up a `bind` commits via
  `placeNodeRelative` and a `move` via `moveNodeTo` (which strips any placement).
  **Hold Alt** to bypass both for free placement. The re-render after commit clears the
  preview transforms.
- **Cycle exclusion.** Binding targets exclude any node that already depends on the
  dragged one (`dependentsOf` walks the picture's placement chains), so the preview
  never offers a binding the engine op would refuse.
- **Guides + badge.** While a drag engages, `drawGuides` paints an SVG layer
  (`svg.sb-guides`, viewBox `0 0 16 9`, stretched, non-scaling strokes): solid accent
  lines for alignment, dashed segments for the two equal spacing gaps, and a dashed
  purple `bind` connector across the gap to the ref. A binding also shows a
  `.sb-bind-badge` (`"below 0.6"`) at the node. Rebuilt each move, removed on
  pointer-up / cancel. Slide space is y-up, the viewBox y-down, so guide y flips to
  `9 - y`.
- **Zoom-aware.** The whole canvas magnifies by scaling the slide width via
  `--zoom` ([zoom.ts](./zoom.md)). Rect-based conversions (`pointToUnits`, and the
  drag's own px->unit math) stay correct because `getBoundingClientRect` returns the
  scaled slide rect; the snap threshold is derived from a fixed pixel radius per drag,
  so snapping feels the same at every zoom. The live-drag preview translates in plain
  pixels (no transform/zoom context), so it already tracks the pointer 1:1.
- **Selection must not re-render.** `actions.select` only toggles handle state — a
  full re-render would replace the very element mid-drag and break pointer capture.
  `move`/`create`/`remove` re-serialize and re-render.
- **Connectors (E4).** `paintConnectors` lays a clickable hit-line (`svg.sb-connectors`,
  a thick transparent `.sb-hit` stroke) along each arrow from `connectorsOf(picture,
  layout)`; clicking one fires `selectConnector(index)` and a selected line shows a
  translucent band. The visible arrow itself is the engine's render. Delete of a
  selected connector is a controller keybinding (`deleteConnector`).
- **Reshaping the selected arrow (E4+).** When the selected connector is editable, its
  `ConnectorPath` is handed to [connectorEditor.ts](./connectorEditor.md), which draws
  endpoint/waypoint/curve handles and commits reshaped paths via `updateConnector`.
- **Connect mode (E4).** When `props.connectMode`, node handles are wired by
  `wireConnect` instead of `wireHandle`: dragging from a node draws a rubber band
  (`svg.sb-rubber`) to the pointer and, on release over another node
  (`document.elementFromPoint` -> `.sb-handle[data-node]`), fires `connect(from, to)`.
  A release off any node cancels.
