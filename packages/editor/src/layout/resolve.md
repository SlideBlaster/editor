# layout resolve

`resolveLayout(picture, measurer) -> Layout`: place every node in slide space.

- **size** from the injected measurer (using `text width` and the node's style
  classes).
- **position** from `at (x,y)` (absolute), else a relative placement
  (`below/above/left/right=<gap> of <ref>`) resolved edge-to-edge against the
  reference node's box, else the origin.
- **order** — relative nodes resolve in dependency order by iterating to a fixpoint.
  A dangling reference or a placement cycle falls back to the origin, so the pass is
  **total**.

`anchor(node, name)` returns a node's compass/center anchor point — the id-anchor of
ADR 0003, consumed by the arrow/path geometry in B3. `findPlaced(layout, name)` looks
a node up by its TikZ id.

Contract: total, deterministic, geometry-only (no pixels, no content rendering). Node
order matches the picture's node statements.
