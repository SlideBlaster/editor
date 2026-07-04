# tikz serialize

`serializePicture(picture) -> string`: the canonical inverse of `parse`.

## Canonical form

- One statement per line, joined by `\n`; every statement terminated by `;`.
- Node: `\node[opt, opt] (name) at (x,y) {body}` — options as `, `-joined tokens,
  `at` omitted when absent, body `{}` when empty.
- Path: `\<action>[opts]<verbatim body>`. Coordinate: `\coordinate (name) at (x,y)`.
- Verbatim: emitted exactly, with the `;` terminator restored.
- Numbers via `formatNumber` (integers as-is, decimals trimmed).

Deterministic: one model prints one text (format invariant 2). Because option
tokens and verbatim spans are preserved, untouched parts of a picture serialize
byte-identically (locality, invariant 3).
