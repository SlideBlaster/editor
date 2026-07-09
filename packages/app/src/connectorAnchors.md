# shared connector anchor snapping (connectorAnchors.ts)

The single anchor-port view both connector gestures share, so an arrow is _created_ and
_reshaped_ against the same set of snap targets. Used by the connect-mode create gesture
([canvas.ts](./canvas.md)) and the reshape editor ([connectorEditor.ts](./connectorEditor.md)).

A connector endpoint attaches either to one of a node's border **ports** — N/S/E/W, the four
corners, or the centre (TikZ `(name.north)` / `(name)`) — or lands in free space as a bare
coordinate `(x,y)`. This module resolves a slide-space point to a port and paints the dots.

- **`nearestAnchor(p, nodes)`** — the port to snap a dragged endpoint to: the node whose box
  (plus a small margin) contains `p` (nearest centre wins ties), then that node's port nearest
  `p`. `null` when the pointer is over no node — the endpoint stays a free point.
- **`nearestAnchorOn(p, node)`** — the nearest port of a _given_ node; never null (the source
  you pressed on always resolves to one of its ports).
- **`snapToAnchor(snap)`** — the engine `Anchor` for a `Snap`; the centre drops its suffix (a
  node's default anchor is its centre). Feeds `createConnector` / `updateConnector`
  ([ops.md](../../editor/src/edit/ops.md)).
- **`PORTS`** — the candidate ports in preference order, centre last so it loses ties to an
  edge (an arrow reads better touching a border than buried inside).
- **`snapKey(name, port)`** / **`Snap`** — the stable `name|port` dot id and the resolved
  `{ name, port, point }` triple a drag carries.
- **`paintSnapDots(layer, nodes)`** / **`setActiveSnaps(layer, keys)`** — paint a dot at every
  port of every named node into an SVG `layer` (slide coords, y flipped to the viewBox), and
  solid-highlight the ports a drag is currently snapping to.

Invariants: dots are indicators only (`.sb-snap-dot` is `pointer-events: none`); geometry is
slide space (y-up) and only `paintSnapDots` flips y for the SVG viewBox. The module is pure DOM

- geometry — it holds no gesture state; the caller owns the drag.
