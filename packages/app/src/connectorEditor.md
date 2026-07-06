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
  - **Anchor dots** at every anchor. Drag to move. While dragging, **snap dots**
    (`sb-snap-dot`) mark every node's border anchors — N/S/E/W, the four corners, and the
    centre. When the pointer is over a node (its box plus a small margin) the endpoint
    snaps to that node's **nearest** anchor and the dot highlights; the centre loses ties
    to an edge, so arrows prefer to touch a border rather than bury themselves inside. On
    release it attaches as `(name.north)` (or `(name)` for the centre), else it becomes a
    free `(x,y)`. Interior anchors delete on **double-click**.
  - **Bend handle** at each straight segment's midpoint — drag to curve it. The cubic
    controls are placed so the curve bows through the drag point (`bendControls`).
  - **Control handles** (two per curved segment, with dashed guide lines to their anchors)
    — drag for full independent control; **double-click** one to straighten the segment.
    While dragging, the control arm **soft-snaps to 15° increments** when it comes within
    ~2.5° of one (so most of the drag stays free); **hold Alt** to disable the snap.
  - **Add a waypoint** by double-clicking the arrow line (`sb-conn-add`, a transparent
    thick hit-stroke): it splits the nearest segment at that point.
- **Segment focus (angle editing).** On every paint the editor reports one segment to the
  controller via `actions.focusCurve` — `focusedSegment` if in range, else the first curved
  segment, else segment 0 (so selecting _any_ editable arrow lights up its angles, straight
  ones included). The payload carries the resolved endpoints and the working `ConnectorPath`,
  which the [properties panel](./properties.md) turns into editable angle/pull fields; a
  straight segment (no controls) shows the chord's own direction, and editing an angle bends
  it. Grabbing a control handle or a bend re-reports _its_ segment, so clicking a curve point
  (or bend) focuses it. The focused segment's handles get `is-focused`.
- **Layering.** The editor SVG sits above the node handles (`z-index`), so anchor dots stay
  draggable even over a node; it is otherwise `pointer-events: none` (only its handles and
  the add-line are interactive).
- **Coordinates.** Everything is slide space (0..16 x 0..9, y-up); the SVG viewBox is
  y-down, so drawing flips `y -> 9 - y`. Control points are absolute, matching TikZ.
