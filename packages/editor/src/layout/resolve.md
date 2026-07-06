# layout resolve

`resolveLayout(picture, measurer, opts?) -> Layout`: place every node in slide space.
`resolveLayoutAsync(picture, batchMeasurer, opts?) -> Promise<Layout>`: the same, sized
by an async `BatchMeasurer` (the DOM measurer). `opts.nodeDistance` (a `LayoutOptions`
field) is the theme's default relative-placement gap (ADR 0017); omitted, gapless
placements fall back to `DEFAULT_PLACEMENT_GAP`.

- **size** from the injected measurer (using `text width` and the node's style
  classes). Sizing is the _only_ difference between the sync and async entry points —
  both feed one shared geometry solve (`solveLayout`), so placement can never drift
  between them.
- **position** from `at (x,y)` (absolute), else a relative placement
  (`below/above/left/right=<gap> of <ref>`) resolved edge-to-edge against the
  reference node's box, else the origin.
- **order** — relative nodes resolve in dependency order by iterating to a fixpoint.
  A dangling reference or a placement cycle falls back to the origin, so the pass is
  **total**.

`anchor(node, name)` returns a node's compass/center anchor point — the id-anchor of
ADR 0003, consumed by the arrow/path geometry in B3 (a connector's `(name.north)` port
resolves through here). `isAnchorName(s)` guards a raw port string before that lookup.
`findPlaced(layout, name)` looks a node up by its TikZ id.

Contract: total, deterministic, geometry-only (no pixels, no content rendering). Node
order matches the picture's node statements.
