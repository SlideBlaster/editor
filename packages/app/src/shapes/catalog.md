# shapes/catalog — the shape library (pure data)

The draw.io-style library the shapes panel presents. A `ShapeDef` is a curated preset of
TikZ node options, not a new model concept: dropping a shape is `createNode` with those
options, so a dragged-in shape equals a hand-typed `\node[...]` and the engine renders,
moves, resizes, and serializes it with no special case. (ADR 0004: a slide is one TikZ
picture; every object is a node.)

## Contract

- `ShapeDef` = `{ id, label, category, keywords, options, size, body }`. `options` is the
  shape's essence (e.g. `['draw','ellipse']`); `size` is the default drop size in slide
  units; `body` is the initial raw content (usually empty).
- `SHAPES` is the ordered library: the curated P0 launch set first (General/Basic —
  rectangle, rounded/square, ellipse/circle, diamond, triangle, trapezoid, parallelogram,
  hexagon, cylinder — and Flowchart), then the **imported draw.io stencil library**
  (`...STENCIL_SHAPES`, ~2000+ shapes; GENERATED — see `design/format/stencil-pipeline.md`).
  A stencil `ShapeDef` carries a `stencil=<id>` option; the engine resolves it to a path via
  `render/stencils`. Curated-first order keeps General/Flowchart at the top of the panel.
- `shapeById(id)` resolves the drag payload / click id. `shapeCategories()` groups by exact
  category in first-seen order; `shapeFamily(shape)` is the category before ` / `
  (`Electrical / Resistors` -> `Electrical`) and `shapeFamilies()` groups by it — pinning
  General/Flowchart first, the rest alphabetical — so the ~80 stencil sub-sets collapse to
  ~17 panel headings. `shapeNodeOptions(shape)` returns the options a dropped node carries —
  the essence plus `minimum width/height` size floors (so an empty shape lands visible).
  `shapeMatches(shape, query)` is the panel's search filter.

## How to add a shape

1. Add one `ShapeDef` to `SHAPES` with the TikZ options that describe it.
2. Only if it needs an outline the renderer doesn't draw yet, add one `NodeShape` case to
   the engine's `render/shape` (and its option reader in `tikz/options`).

The palette thumbnail is derived automatically — `shapesPanel` draws it with the engine's
`shapeGeometrySvg`, the same function the canvas uses, so preview matches canvas. See
`../shapesPanel.md` and the engine `render/shape.md`.
