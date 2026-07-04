# tikz picture model

A slide picture is an ordered list of `Statement`s. Four kinds:

- **node** — `\node[options] (name) at (x,y) {content}`. `name` is the stable
  identity; `options` are ordered raw tokens (the serialization truth); `at` is the
  absolute position when present; `content` is the body, parsed into tri-dialect
  `NodeContent` (see `./content`).
- **path** — `\draw`/`\path`/`\fill`/`\filldraw`; action + options modeled, segment
  body verbatim.
- **coordinate** — `\coordinate (name) at (x,y)`.
- **verbatim** — any T2 / unrecognized statement, preserved exactly.

## Why options and bodies are verbatim (A2)

Per tikz-subset.md, v1 round-trips by **span-preserving parse + splice**: model the
editable structure, keep everything else as verbatim spans, and regenerate only
edited spans. Option tokens are kept raw and re-joined canonically so untouched
options survive byte-identical; T2 statements are kept whole. This is what makes the
locality invariant hold and git merges tractable.

Structured reads over options (style classes, role, relative placement) are derived
on demand in `../tikz/options`, not stored, so they never desynchronize from the
serialization truth.

Serialized by `../tikz/serialize`; parsed by `../tikz/parse`.
