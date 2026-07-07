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
empty box lands visible), and `nodeOverlay` (the whole-node
`overlay=<spec>` reveal, ADR 0018 — stored brace-wrapped so a spec's commas survive
option tokenizing; returns the raw `OverlaySpec` for `content/overlay` to interpret).

Shape reads: `nodeShape` (`rectangle` default, or `ellipse` for a bare `ellipse`/`circle`
token — the `NodeShape` switch the renderer maps to an SVG element), `isDrawn` (the bare
`draw` option — a visible outline; a plain text node has none so its box stays invisible),
and `fillColor` (the `fill=<color>` value passed straight to the SVG `fill`).

The layout pass (`../layout/resolve`) consumes width/placement; the render pass
consumes the overlay and the shape reads.

Kept derived so they can never disagree with the serialization truth. Structured
placement/style editing (rewriting these tokens) comes with the edit ops and canvas.
