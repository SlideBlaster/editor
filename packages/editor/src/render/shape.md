# render/shape — a node box as a visible SVG outline

`shapeGeometrySvg(node, rect, extraClasses?)` returns one SVG element string drawing a
node's geometry, sized to `rect` (a box in SVG user units, y-down — already mapped out of
slide space by the caller).

It reads the shape essence from the node's option tokens via the `tikz/options` derived
views: `nodeShape` chooses the element (`rectangle` -> `<rect>`, `ellipse` -> `<ellipse>`),
`isDrawn` adds the `sb-drawn` class (a visible stroke), and `fillColor` emits an inline
`style="fill:…"` (inline style beats the class `fill`, so a filled shape shows its color
while an unfilled box stays transparent).

## Contract

- Pure: same `(node, rect, extraClasses)` -> same string. No slide-space or `SLIDE_H`
  knowledge; the caller does the coordinate mapping.
- Class order is fixed: `sb-box`, then `sb-drawn` (only when `draw` is set), then
  `extraClasses` in order. The slide renderer passes the placed node's `sb-style-*`
  classes; the shapes palette passes none.
- Every node yields an element (even undrawn/unfilled) so selection and hit-test geometry
  match a plain box.

## Why it exists

The one place shape geometry is drawn, shared by two consumers so they can never diverge:
the slide renderer (`render/slide`) draws the canvas/export box, and the app's shapes
palette draws each thumbnail with the exact same function. Adding a shape kind is one new
`NodeShape` case plus the stylesheet; see `../tikz/options` (`nodeShape`, `isDrawn`,
`fillColor`) and [[layered-dom-render-surface]].
