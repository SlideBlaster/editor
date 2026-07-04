# tikz options (derived views)

Read-only helpers that interpret a node's raw `options` tokens without storing
anything: `styleClasses` (bare tokens), `role` (`title` class -> title node),
`placementToken` (a relative-placement token like `below=0.7 of title`).

Kept derived so they can never disagree with the serialization truth. Structured
placement/style editing (rewriting these tokens) comes with the edit ops and canvas.
