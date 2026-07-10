# shapes/nodeStyle — pure node style-option writers

The write half of the style panel: pure `withX(options, value) -> options'` functions that
rewrite ONE style knob on a node's raw TikZ option-token array, preserving every unrelated
token (theme role class, placement, size floors, other knobs). The engine's `tikz/options`
derived views are the READ half; these are the WRITE half. The panel reads a value, calls
the matching writer, and commits the new array through `setNodeOptions` — the node
counterpart to how the connector panel uses `setConnectorOptions` + `withDirection`.

Because a knob maps to the exact TikZ token TikZ itself uses, a panel edit and a hand-typed
`\node[...]` are byte-identical (ADR 0004, [[shapes-as-option-presets]]).

## Writers

- `withShape(options, 'rectangle' | 'ellipse')` — bare shape token (`rectangle` is the
  default, no token).
- `withFillColor(options, color | null)` — `fill=<color>` (keeps fill opacity).
- `withStroke(options, on)` — ensure/remove the outline (bare `draw`; leaves `draw=<color>`
  as still-drawn; off strips both). Stroke-only knobs are left in place.
- `withStrokeColor(options, color | null)` — `draw=<color>`, or a bare `draw` on `null`
  (both keep the node drawn).
- `withLineWidth(options, name | null)` — a TikZ named width (`LINE_WIDTHS`); drops any
  prior name and any explicit `line width=<pt>`.
- `withDash(options, pattern | null)` — a dash token (`DASH_PATTERNS`); `null` is solid.
- `withOpacity` / `withFillOpacity` / `withDrawOpacity(options, n | null)` — the three
  alphas (`opacity=`, `fill opacity=`, `draw opacity=`).
- `withCorners(options, pt | null)` — `rounded corners=<pt>` (rectangles only).
- `withFontSize(options, cqw | null)` — `font size=<cqw>`, a per-node text-size override of
  the theme role's size (class < node); `null` clears the token back to inheritance.

## Contract

- Pure and total: never mutates the input, always returns a fresh array; unknown/unrelated
  tokens pass through untouched and keep their relative order.
- `key=value` knobs are position-stable (replace in place, append if new); bare knobs are
  appended after removing any prior member of their vocabulary.
- Vocabulary (`LINE_WIDTHS`, `DASH_PATTERNS`) is imported from the engine, the single source
  of truth shared with the reader and the renderer — so the three can never disagree.
- `draw`-family matching excludes `draw opacity=` (a distinct knob), mirroring the engine's
  `isDrawn`.
