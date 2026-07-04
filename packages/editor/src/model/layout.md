# layout model

The output of the measure -> resolve pass (ADR 0014). A `Layout` is `PlacedNode[]`
in the picture's node order. Each `PlacedNode` carries a `center` (slide space,
y-up, `0..16` x `0..9`), a `size`, and the node's `styleClasses` (for the renderer).

Slide space is unitless here; the pixel transform is applied at render (B3). This is
geometry only — a renderer zips it with the picture's node content by order/name.
Produced by `../layout/resolve`.
