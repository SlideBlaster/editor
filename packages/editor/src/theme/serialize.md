# theme serialize (on-disk JSON)

`serializeTheme(theme) -> string` / `parseTheme(text) -> Theme`: a theme's on-disk form
is a structured **JSON** file (zero-dep — no YAML parser). One file per theme,
`themes/<id>/theme.json` in the project, with asset files (logo, ...) beside it; loading
by path through the Storage port is the loader's job (ADR 0008), not this module's.

- `serializeTheme` emits **canonical** JSON — object keys sorted recursively, 2-space
  indent, trailing newline — so a theme file is deterministic and diffs/merges
  per-property like the document format (ADR 0017, "structured everywhere"). Arrays keep
  their order (region order is significant).
- `parseTheme` validates the JSON back into the typed `Theme`, throwing `ThemeParseError`
  with a **field path** (e.g. `theme.layout.regions[0].rect.x`) on malformed input, so a
  hand-edited or imported file fails loudly rather than rendering wrong.

JSON was chosen over YAML to avoid a parser dependency; the theme-editor UI is the
authoring surface either way, so hand-edit ergonomics were not decisive.
