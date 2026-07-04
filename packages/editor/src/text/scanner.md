# text scanner

Depth-aware scanning primitives shared by the TikZ parser. All of them enforce one
rule: **braces `{}` are primary**. Node bodies are brace-delimited and hold
arbitrary markdown/LaTeX/HTML, so brackets `[]` and parens `()` only nest at
brace-depth 0 (in option lists and coordinates); inside a body they are literal.

## Exports

- `formatNumber(n)` — canonical number text (integers as-is, decimals trimmed).
- `splitStatements(source)` — split a picture body into trimmed, `;`-terminated
  statement chunks at top level; inter-statement whitespace is discarded.
- `splitOptions(inner)` — split option-list inner text on top-level commas,
  respecting `{}`/`[]`/`()`.
- `readGroup(source, start, open, close)` — read one delimited group; braces nest
  everywhere, other delimiters count only at brace-depth 0. Throws if unterminated.
- `parsePoint(inner)` — parse an `x,y` pair.
- `skipWhitespace(source, i)` — advance past whitespace.

## Assumptions

Braces within a node body are assumed balanced (LaTeX/TikZ convention). Unbalanced
braces inside a body are out of scope for v1 and would misalign scanning — the
parser's verbatim fallback preserves such statements rather than corrupting them.
