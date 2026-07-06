# theme css (style-layer emitter)

`themeStylesheet(theme) -> string`: the theme's **style layer** as a stylesheet,
scoped under `.sb-slide`, meant to be injected AFTER `slideStylesheet()` (ADR 0014,
one seam — editor canvas and export share it).

- `.sb-slide { --sb-<key>: <colour>; … ; background: var(--sb-bg); font-family }` — the
  palette as CSS custom properties plus the base font family.
- `.sb-content { font-size: <base>cqw; line-height; color: var(--sb-ink) }` — the base
  type every node inherits (sizes are cqw, slide-relative — slideType.md).
- One `.sb-slide .sb-style-<role> { … }` rule per class, built from the structured
  `StyleDecls` in a deterministic declaration order. Class rules carry no per-node
  options, so an explicit node `[...]` still wins (**class < node**).
- Colours resolve a palette key to `var(--sb-<key>)`, else emit the literal string;
  a `body`/`heading` family resolves to the theme's families.

Only layer 1 is stylesheet output — regions (overlay) and furniture (chrome layers)
render elsewhere. Pure, deterministic string: headless and snapshot-testable.
