# content parse

`parseContent(body) -> NodeContent`: parse a node body string into inline runs.

A recursive-descent scanner that applies the precedence of
`design/format/node-content.md` at every nesting level, recursing into each
container's body (transparent nesting):

1. **lists** — a line beginning `- `/`* `/`N. ` starts a markdown list;
   `\begin{itemize|enumerate}` a LaTeX list; `<ul>`/`<ol>` an HTML list. A list is a
   `TextRun`, so it nests inside a wrap or an item. Item content recurses.
2. **math** `$$…$$` then `$…$` — opaque, source kept literal, not re-scanned.
3. **HTML tags** — a supported tag (`b strong i em u s div span`, no attributes)
   opens an element whose inner text recurses.
4. **LaTeX** — `\textbf`/`\emph`/`\textit`/`\underline` with a `{ }` argument that
   recurses; bare `\appear`/`\pause` become reveal fragments.
5. **markdown emphasis** — `**…**` / `*…*` when a matching delimiter exists.
6. anything else accumulates as literal **text**.

## Contract

- **Total for supported input**: any string of text plus the constructs above parses
  without throwing; unrecognized text stays literal, so it round-trips.
- **Out-of-subset -> error, never crash the caller** (ADR 0015): a denylisted or
  unknown LaTeX macro, an unknown/unsafe or attributed HTML tag, or an unclosed
  supported tag raises `OutOfSubsetError` internally; `parseContent` catches it and
  returns `{ kind: 'error', source, message }` with the body preserved verbatim.
- **Round-trips** with `serialize` for canonical input, byte-for-byte, including
  which dialect each construct used.
- Empty body -> `{ kind: 'empty' }`.

## Limits (widen in A3c)

- No tables, images, `\cat`, or groups yet, and only bare `\appear`/`\pause`
  fragments — the rest is A3c. Moving a construct from "literal/error" to "parsed"
  is how later increments grow the subset.
- Lists are flat except where a container nests them (a LaTeX item or HTML wrap
  holding a sublist); markdown indentation-nesting is not modeled yet. List
  whitespace and markers normalize on save (`-`, renumbered), so only canonical list
  text round-trips byte-exact.
- HTML tags must be attribute-less; math delimiters are only `$`/`$$`; an unmatched
  `$` or `*` is treated as a literal character.
