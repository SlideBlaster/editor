# tikz options (derived views)

Read-only helpers that interpret a node's raw `options` tokens without storing
anything: `styleClasses` (bare tokens), `role` (`title` class -> title node),
`isPlacementToken` (whether a token is a relative placement) and `placementToken`
(the first such token, like `below=0.7 of title`), `placement`
(that token parsed to `{ side, gap, ref }`; a gapless token takes `placement`'s
`defaultGap` argument — the theme's node distance, ADR 0017 — defaulting to
`DEFAULT_PLACEMENT_GAP`),
`textWidth` (the `text width=<n>` value), `minWidth`/`minHeight` (the `minimum
width|height=<n>` grow-only size floors — the size levers a dropped shape uses so an
empty box lands visible), `fontSize` (the per-node `font size=<n>` text size in cqw — a
_class < node_ override of the theme role's size, read by the renderer and both measurers),
and `nodeOverlay` (the whole-node
`overlay=<spec>` reveal, ADR 0018 — stored brace-wrapped so a spec's commas survive
option tokenizing; returns the raw `OverlaySpec` for `content/overlay` to interpret).

Shape reads: `nodeShape` — the `NodeShape` outline the renderer maps to an SVG element:
`rectangle` (default), `ellipse` (also `circle`), the straight-edged `diamond` / `triangle`
/ `trapezoid` / `parallelogram` / `regularPolygon` (one `<polygon>` each), `cylinder`
(a `<path>`), `stadium` (a fully-rounded rect, from a `rounded rectangle` token), and
`stencil` (an imported draw.io stencil — wins over the bare tokens). The token->shape table
is `SHAPE_TOKENS`. `polygonSides` reads `regular polygon sides=<n>` (default 5). `stencilId`
reads the `stencil=<id>` token (the id the renderer resolves via `../render/stencils`; the
token round-trips verbatim); see `design/format/stencil-pipeline.md`. `isDrawn` (a bare `draw` OR a `draw=<color>` option — a visible outline; a
plain text node has neither so its box stays invisible), and `fillColor` (the `fill=<color>`
value passed straight to the SVG `fill`).

Style-knob reads (the style panel's vocabulary, all honoured by `../render/shape`):

- `strokeColor` — the `draw=<color>` stroke colour (bare `draw` keeps the default stroke).
- `lineWidthName` / `lineWidthPt` / `strokeWidthUnits` — the stroke weight as a TikZ name
  (`LINE_WIDTHS`: `ultra thin`…`ultra thick`), an explicit `line width=<pt>`, or the
  resolved slide-unit stroke width the renderer emits (anchored so `thin` == the default
  0.03; undefined means the stylesheet default applies).
- `dashPattern` / `dashArray` — the dash as a TikZ token (`DASH_PATTERNS`) and its SVG
  `stroke-dasharray` + round-cap flag (dotted draws round dots).
- `opacity` / `fillOpacity` / `drawOpacity` — whole-node, fill-only, and stroke-only alpha.
- `cornerRadiusPt` / `cornerRadiusUnits` — the `rounded corners[=<pt>]` radius (bare token
  == `DEFAULT_ROUNDED_PT` = 4pt) in pt / slide units (rectangles only).

`isStyleKnobToken` marks the bare knob tokens (`draw`, `rectangle`, `rounded corners`, every
shape token in `SHAPE_TOKENS` — `ellipse`, `circle`, `diamond`, `trapezium`, … — the widths,
the dashes) so callers can tell a knob apart from a theme
role — the style dropdown (`currentClass`) and `setNodeStyleClass` both keep knobs and only
treat the _other_ bare tokens as roles. Colour/width/opacity keys carry `=`, so
`styleClasses` never sees them as roles at all.

The layout pass (`../layout/resolve`) consumes width/placement; the render pass
consumes the overlay and the shape/style reads.

Kept derived so they can never disagree with the serialization truth. Structured
placement/style editing (rewriting these tokens) comes with the edit ops and canvas.
