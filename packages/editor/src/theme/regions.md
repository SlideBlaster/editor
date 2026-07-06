# theme regions (master-layout geometry)

Pure geometry over a theme's **master-layout regions** (ADR 0017). A region is a
`RelRect` — fractions of the slide box, origin top-left, y-down — so one theme fits any
aspect ratio. These helpers resolve regions against a concrete `SlideBox` (default 16x9,
y-up) for the editor overlay/snap/creation code to consume.

- `regionRects(theme, box?) -> RegionRect[]` — each region as a slide-space rect (y-up,
  so `top >= bottom`), carrying its `defaultClass`/`defaultAnchor`.
- `regionAt(theme, point, box?) -> RegionRect | undefined` — the region containing a
  slide-space point (first match). Feeds **creation-only** seeding: a node _created_ in a
  region takes its `defaultClass`/`defaultAnchor`; a moved node is never reclassified.
- `regionGuides(theme, box?) -> { xs, ys }` — each region's edges + centre as snap-target
  coordinates, merged into the drag guide set (alongside the slide edges/centre/thirds of
  positioning-snapping.md).

Regions are **editor-only**: they guide and seed, they never position or render. Output
never contains a region (ADR 0002 holds). The `SlideBox` default is 16x9; aspect-ratio
configuration (ADR 0017) will supply the box from frontmatter later.
