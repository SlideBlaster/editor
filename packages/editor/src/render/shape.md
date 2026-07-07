# render/shape — a node box as a visible SVG outline

`shapeGeometrySvg(node, rect, extraClasses?)` returns one SVG element string drawing a
node's geometry, sized to `rect` (a box in SVG user units, y-down — already mapped out of
slide space by the caller).

It reads the shape essence from the node's option tokens via the `tikz/options` derived
views: `nodeShape` chooses the element (`rectangle` -> `<rect>`, `ellipse` -> `<ellipse>`,
the straight-edged shapes -> one `<polygon>`, `cylinder` -> `<path>`, `stadium` -> a fully
rounded `<rect>`) and `isDrawn` adds the `sb-drawn` class (a visible stroke). Every paint knob is emitted as
an inline `style` declaration, because inline CSS is what beats the `.sb-drawn` stylesheet
rule — SVG presentation attributes lose to it:

- `fillColor` -> `fill`, `fillOpacity` -> `fill-opacity` (an unfilled box stays transparent).
- Only when drawn: `strokeColor` -> `stroke`, `strokeWidthUnits` -> `stroke-width`,
  `dashPattern`/`dashArray` -> `stroke-dasharray` (+ `stroke-linecap:round` for dotted),
  `drawOpacity` -> `stroke-opacity`. Absent knobs fall back to the stylesheet's default
  stroke (`#333`, `0.03`).
- `opacity` -> element `opacity` (the slide renderer dims the content `<div>` to match).
- A rectangle's `cornerRadiusUnits` becomes geometric `rx`/`ry`; a `stadium` forces
  `rx=ry=min(w,h)/2` (a pill). The straight-edged outlines emit a `<polygon>` point list
  inscribed in the rect (a regular polygon walks `polygonSides` points, first vertex at top),
  and `cylinder` a `<path>` with elliptical caps.

## Contract

- Pure: same `(node, rect, extraClasses)` -> same string. No slide-space or `SLIDE_H`
  knowledge; the caller does the coordinate mapping.
- Class order is fixed: `sb-box`, then `sb-drawn` (only when the node is drawn), then
  `extraClasses` in order. The slide renderer passes the placed node's `sb-style-*`
  classes; the shapes palette passes none.
- Stroke knobs are only emitted when the node is drawn; the fill and whole-node opacity
  apply either way.
- Every node yields an element (even undrawn/unfilled) so selection and hit-test geometry
  match a plain box.

## Why it exists

The one place shape geometry is drawn, shared by two consumers so they can never diverge:
the slide renderer (`render/slide`) draws the canvas/export box, and the app's shapes
palette draws each thumbnail with the exact same function. Adding a shape kind is one new
`NodeShape` case here — usually just a point/path formula, since the `<polygon>` and
`<path>` branches already exist — plus its token in `../tikz/options`
(`nodeShape`/`SHAPE_TOKENS`); see [[shapes-as-option-presets]] and
[[layered-dom-render-surface]].
