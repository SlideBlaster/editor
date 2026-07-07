# properties panel (properties.ts)

A small inspector for the current selection (E5: arrow style, node placement/size/reveal,
and node Style). `paintProperties(host, { selection, picture, curveFocus, actions })` renders
into a floating panel; the controller repaints it on every selection change and after every
render.

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
- **Selected node -> Style (E5).** The shape/paint knobs: Shape (rectangle/ellipse segmented
  control), Fill (toggle + colour swatch), Stroke (draw toggle + colour, with Line width and
  Dash selects that disable while undrawn), Corners (rectangles only, pt), and three alphas
  (Opacity / Fill α / Stroke α). Each control reads a `tikz/options` derived view
  (`nodeShape`, `fillColor`, `isDrawn`, `strokeColor`, `lineWidthName`, `dashPattern`,
  `cornerRadiusPt`, the opacities) and, on change, rewrites just that knob with a
  [`shapes/nodeStyle`](./shapes/nodeStyle.md) helper (`withShape`, `withFillColor`, …) from
  the node's CURRENT `options`, committing the whole array via `setNodeStyle` ->
  `setNodeOptions`. Colour swatches are `#rrggbb`; a named/expression colour shows as black
  until changed but is otherwise left intact. Because it maps to the same tokens TikZ uses, a
  panel edit equals a hand-typed `\node[...]` (ADR 0004).
- **Frame-agnostic.** The controller binds the panel's actions to the selected slide's
  frame and hands it that frame's picture; this module never touches frame indices.
- **Empty selection** hides the panel (`host.hidden`).
