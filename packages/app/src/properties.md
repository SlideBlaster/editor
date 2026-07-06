# properties panel (properties.ts)

A small inspector for the current selection (E5, scoped to arrow style + node placement;
style classes and colours are deferred). `paintProperties(host, { selection, picture,
curveFocus, actions })` renders into a floating panel; the controller repaints it on every
selection change and after every render.

- **Selected connector -> Arrow.** Reads the connector's option tokens
  (`connectorOptions`), shows a head-direction segmented control (none / → / ← / ↔) and a
  dashed toggle, and writes changes with `setConnectorOptions`. `withDirection` swaps the
  `->`/`<-`/`<->` token (keeping every other token); `withDashed` toggles `dashed`.
- **Curve angles.** When a `curveFocus` accompanies the selected arrow (the controller sets
  it from the [connector editor](./connectorEditor.md) — selecting an arrow focuses a segment;
  clicking a curve point or bend focuses that one), a **Curve** block appears: each cubic
  control point in polar form as an **angle** (0° right, 90° up — slide space is y-up) and a
  **pull** (control-arm reach). A **straight** segment shows the chord's own direction with a
  default pull, so editing an angle bends it. Editing a field rebuilds only that segment's
  controls (the other point + segments stay byte-identical, symbolic node anchors preserved)
  and commits via `updateConnectorPath` -> `updateConnector`.
- **Selected node -> Placement.** Reads `node.at` / `placement(node)`. Absolute nodes show
  editable X/Y (commit via `moveNode` -> `moveNodeTo`); relative nodes show an editable
  side, gap, and a read-only ref (commit via `bindNode` -> `placeNodeRelative`). A badge
  marks which mode. Switching modes is done by dragging on the canvas, not here.
- **Selected node -> Reveal (overlays, ADR 0018).** A text field for the node's Beamer
  overlay spec (`nodeOverlay(node)?.raw`; blank = always visible). On commit it validates
  with `isValidSpec` — a valid spec writes via `setNodeOverlay`, blank clears it, a
  malformed spec is left uncommitted with a red outline. The whole-node half of the
  two-level model; inline `\pause`/`\only` live in the node body.
- **Frame-agnostic.** The controller binds the panel's actions to the selected slide's
  frame and hands it that frame's picture; this module never touches frame indices.
- **Empty selection** hides the panel (`host.hidden`).
