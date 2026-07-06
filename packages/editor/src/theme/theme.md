# theme (model)

The structured theme model (ADR 0017): typed data in three layers, not opaque
CSS/HTML. Exports the `Theme` type and the built-in `defaultTheme`; `css.ts` renders
layer 1.

- **Layer 1 — style.** `palette` (named colours; bg/ink/accent well-known, extras by
  name, all exposed as CSS vars and available to `\draw`), `type` (families + base cqw
  size + line-height + modular `scale`), `classes` (role -> `StyleDecls`, the structured
  look — family, size cqw, weight, italic, tracking, colour, background, border; never
  raw CSS), and
  `nodeDistance` (the default relative-placement gap; ADR 0006). Precedence is
  **class < node**: per-node inline options win (emitted after the class rules).
- **Layer 2 — master layout.** `regions`: named `RelRect`s **relative to the slide
  box** (fractions in [0,1], origin top-left, y-down — aspect-ratio-agnostic). A
  region is a soft guide + creation default (`defaultClass`/`defaultAnchor`): it seeds
  a node _created_ inside it, never repositions or reclassifies a moved node, and is
  editor-only. Rendered by the overlay increment, not here.
- **Layer 3 — furniture.** Deck-wide chrome: `pageNumber`, `logo` (asset by
  project-relative path), `header`/`footer` bands (left/center/right slots), placed by
  a 9-slot `Anchor9` against a `safeArea` inset. Rendered into the layered DOM by the
  furniture increment.
- **Aspect.** Geometry is relative, so one theme fits any ratio; `aspect.overrides`
  pins a specific ratio when the relative default is not enough.

Colours in `StyleDecls`/borders are either a palette key (resolved to `var(--sb-<key>)`)
or a literal CSS colour. Storage/loading (per-project YAML behind the Storage port, ADR 0008) and the theme-editor UI are separate concerns; this module is the in-memory model
the engine consumes.
