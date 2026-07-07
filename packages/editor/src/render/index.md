# render

The render layer (ADR 0014, engine track B). `renderContent` produces the HTML
content layer of the layered DOM. B3 adds the SVG geometry layer (node borders, `\draw`
paths/arrows) and the slide -> pixel transform, then stacks content over geometry.

`shapeGeometrySvg` (see `shape.md`) draws one node box as a visible SVG outline
(rect/ellipse, stroked when the node has `draw`, filled when it has `fill=…`). The slide
renderer uses it for every node box, and the app's shapes palette reuses it for thumbnails
so a dropped shape and its preview are drawn by the same code.
