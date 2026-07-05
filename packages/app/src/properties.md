# properties panel (properties.ts)

A small inspector for the current selection (E5, scoped to arrow style + node placement;
style classes and colours are deferred). `paintProperties(host, { selection, picture,
actions })` renders into a floating panel; the controller repaints it on every selection
change and after every render.

- **Selected connector -> Arrow.** Reads the connector's option tokens
  (`connectorOptions`), shows a head-direction segmented control (none / → / ← / ↔) and a
  dashed toggle, and writes changes with `setConnectorOptions`. `withDirection` swaps the
  `->`/`<-`/`<->` token (keeping every other token); `withDashed` toggles `dashed`.
- **Selected node -> Placement.** Reads `node.at` / `placement(node)`. Absolute nodes show
  editable X/Y (commit via `moveNode` -> `moveNodeTo`); relative nodes show an editable
  side, gap, and a read-only ref (commit via `bindNode` -> `placeNodeRelative`). A badge
  marks which mode. Switching modes is done by dragging on the canvas, not here.
- **Frame-agnostic.** The controller binds the panel's actions to the selected slide's
  frame and hands it that frame's picture; this module never touches frame indices.
- **Empty selection** hides the panel (`host.hidden`).
