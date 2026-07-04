# markdown (barrel)

The container round-trip: `fromMarkdown` (text -> `SlideDocument`) and `toMarkdown`
(`SlideDocument` -> canonical text). Delegates the slide-picture body to `../tikz`.
This is the durable-format boundary: the only representation stored in git.
