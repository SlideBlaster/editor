# node content model

The body of a `\node { … }`. Governed by ADR 0007 (tri-dialect, provenance), the
spec `design/format/node-content.md`, and ADR 0015 (out-of-subset -> error).

`NodeContent` is one of:

- **empty** — `{}`, a pure shape/box.
- **text** — a list of inline `TextRun`s.
- **error** — source outside the supported subset, preserved verbatim with a
  message; the node renders as an error and blocks commit (ADR 0015). Never
  silently dropped, so round-trip stays safe.

A `TextRun` is one of: literal **text**; opaque **math** (`$…$` / `$$…$$`, source
kept literal for KaTeX); or a dialect wrapper whose `children` recurse —
**latex** (`\textbf`/`\emph`/`\textit`/`\underline`), **markdown** (`**`/`*`),
**html** (an inline or structural tag). Containers are transparent: their children
are themselves runs of any dialect.

## Surface-faithful, provenance-derived

Runs store the **exact written form**, not an abstract style. `\emph` and `\textit`
are distinct runs even though both mean italic; `**x**`, `\textbf{x}`, and `<b>x</b>`
are three different runs that all mean bold. This is deliberate:

- **Provenance is the model** (ADR 0007): the dialect of each construct is implicit
  in its run kind, so serialization reproduces the original and never rewrites one
  dialect into another.
- **Byte-exact round-trip is mechanical** — the serializer just emits each run's
  form (format invariant 2 for content).
- **Meaning is derived, not stored** — `../content/styles` computes the shared style
  (`bold`/`italic`/…) and dialect on demand, exactly as `../tikz/options` derives
  style classes from raw option tokens. Derived reads never desynchronize from the
  serialization truth.

Source spans (which bytes back each run) are a render/edit-time concern — needed for
"edit the construct under the cursor" (ADR 0014) — and are computed by the render
track, not stored here.

## Scope

Inline runs; lists in all three dialects (`- x` / `itemize` / `enumerate` / `<ul>` /
`<ol>`, nestable via containers); reveal fragments (`\appear`/`\pause`/`\only`,
`[=N]` step, `<appear>`); images (`\image`, `![alt](src)`); and `columns`/`matrix`
groups. Any container run (list, columns, matrix, wrap) is a `TextRun`, so it nests
freely. Whitespace in lists/columns/matrix is normalized on save (list markers ->
`-`, ordered lists renumber; cells joined by ` & `, rows by ` \\ `); canonical text
round-trips byte-exact.

Two constructs are parsed but not renderable without a port, so they preserve source
and are **not** errors: `table` (`\begin{tabular}` -> Compile port, kept opaque as
`deferred`) and `include` (`\cat{path}` -> Storage port). Their visual/resolved
rendering is the render track. Parsed by `../content/parse`, serialized by
`../content/serialize`.
