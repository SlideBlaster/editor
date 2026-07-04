# content parse

`parseContent(body) -> NodeContent`: parse a node body string into inline runs.

A recursive-descent scanner that applies the precedence of
`design/format/node-content.md` at every nesting level, recursing into each
container's body (transparent nesting):

1. **math** `$$…$$` then `$…$` — opaque, source kept literal, not re-scanned.
2. **HTML tags** — a supported tag (`b strong i em u s div span`, no attributes)
   opens an element whose inner text recurses.
3. **LaTeX macros** — `\textbf`/`\emph`/`\textit`/`\underline` with a `{ }` argument
   that recurses.
4. **markdown emphasis** — `**…**` / `*…*` when a matching delimiter exists.
5. anything else accumulates as literal **text**.

## Contract

- **Total for supported input**: any string of text plus the constructs above parses
  without throwing; unrecognized *text* (including not-yet-modeled markdown such as
  `-` lists) stays literal, so it round-trips.
- **Out-of-subset -> error, never crash the caller** (ADR 0015): a denylisted or
  unknown LaTeX macro, an unknown/unsafe or attributed HTML tag, or an unclosed
  supported tag raises `OutOfSubsetError` internally; `parseContent` catches it and
  returns `{ kind: 'error', source, message }` with the body preserved verbatim.
- **Round-trips** with `serialize` for canonical input, byte-for-byte, including
  which dialect each construct used.
- Empty body -> `{ kind: 'empty' }`.

## A3a limits (widen in A3b/A3c)

- No lists, tables, images, `\cat`, groups, or fragments yet — their syntax is
  literal text for now (except denylisted forms, which error). Moving a construct
  from "literal/error" to "parsed" is how later increments grow the subset.
- HTML tags must be attribute-less; math delimiters are only `$`/`$$`; an unmatched
  `$` or `*` is treated as a literal character.
