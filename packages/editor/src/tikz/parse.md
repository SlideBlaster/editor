# tikz parse

`parsePicture(source) -> TikzPicture`: split the picture body into statements
(`splitStatements`) and classify each.

- **node** — reads `[options]`, `(name)`, an `at (x,y)` clause, and a `{body}` in
  any order; the body is handed to `../content/parse` (tri-dialect `NodeContent`).
- **coordinate** — `\coordinate (name) at (x,y)`.
- **path** — `\draw`/`\filldraw`/`\fill`/`\path`; action + `[options]` modeled, the
  rest verbatim.
- **verbatim** — anything else, or anything that fails to parse cleanly (a
  try/catch fallback), preserved exactly.

## Contract

- Total and non-throwing at the statement level: an unrecognized or malformed
  statement is preserved as `verbatim`, never dropped or corrupted.
- Options are kept as raw tokens; coordinates are parsed to numbers. Round-trips
  with `serialize` for canonical input.
- Depth-aware throughout via `../text/scanner`, so bodies containing `;`, `[]`,
  `()` are handled.
