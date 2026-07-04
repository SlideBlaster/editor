# tikz options (derived views)

Read-only helpers that interpret a node's raw `options` tokens without storing
anything: `styleClasses` (bare tokens), `role` (`title` class -> title node),
`isPlacementToken` (whether a token is a relative placement) and `placementToken`
(the first such token, like `below=0.7 of title`), `placement`
(that token parsed to `{ side, gap, ref }`, gap defaulting to `DEFAULT_PLACEMENT_GAP`),
and `textWidth` (the `text width=<n>` value). The layout pass (`../layout/resolve`)
consumes the last two.

Kept derived so they can never disagree with the serialization truth. Structured
placement/style editing (rewriting these tokens) comes with the edit ops and canvas.
