# connector editor (connectorEditor.ts)

Reshape a selected arrow directly on the canvas (E4+). Given the selected connector's
`ConnectorPath` (from the engine's `connectorsOf(...).editable`), it draws editing handles
and commits a reshaped path via `updateConnector`.

- **In-place drag, commit-on-release.** During a drag the arrow's own `<path>` (queried by
  `data-arrow`) and the dragged handle are updated by attribute — never rebuilt — so
  pointer capture holds. `pointerup` commits, and the resulting re-render rebuilds the
  handles fresh. Structural changes (add/delete waypoint, straighten) just mutate + commit;
  the re-render redraws them.
- **Handles.**
  - **Anchor dots** at every anchor. Drag to move. While dragging, a **snap dot** marks
    every node's centre (`sb-snap-dot`); when the pointer nears a node (its box plus a
    small margin) the endpoint snaps to that node's centre and the dot highlights. On
    release it attaches there as `(name)`, else it becomes a free `(x,y)`. Interior anchors
    delete on **double-click**.
  - **Bend handle** at each straight segment's midpoint — drag to curve it. The cubic
    controls are placed so the curve bows through the drag point (`bendControls`).
  - **Control handles** (two per curved segment, with dashed guide lines to their anchors)
    — drag for full independent control; **double-click** one to straighten the segment.
  - **Add a waypoint** by double-clicking the arrow line (`sb-conn-add`, a transparent
    thick hit-stroke): it splits the nearest segment at that point.
- **Layering.** The editor SVG sits above the node handles (`z-index`), so anchor dots stay
  draggable even over a node; it is otherwise `pointer-events: none` (only its handles and
  the add-line are interactive).
- **Coordinates.** Everything is slide space (0..16 x 0..9, y-up); the SVG viewBox is
  y-down, so drawing flips `y -> 9 - y`. Control points are absolute, matching TikZ.
