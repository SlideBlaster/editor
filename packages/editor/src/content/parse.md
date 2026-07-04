# content parse

`parseContent(body) -> NodeContent`: parse a node body string into inline runs.

A recursive-descent scanner that applies the precedence of
`design/format/node-content.md` at every nesting level, recursing into each
container's body (transparent nesting):

1. **block containers** — a line beginning `- `/`* `/`N. ` starts a markdown list;
   `\begin{itemize|enumerate}` a LaTeX list; `<ul>`/`<ol>` an HTML list;
   `\begin{columns}` a columns group; `\matrix[..]{..}` a matrix group;
   `\begin{tabular}` an opaque `deferred` table. All are `TextRun`s, so they nest
   inside a wrap or an item; item/column/cell content recurses.
2. **math** `$$…$$` then `$…$` — opaque, source kept literal, not re-scanned.
3. **HTML** — `<appear>` (fragment); a supported tag (`b strong i em u s div span`,
   no attributes) opens an element whose inner text recurses.
4. **LaTeX** — `\textbf`/`\emph`/`\textit`/`\underline` (`{ }` arg, recurses);
   `\image{src}`, `\cat{path}` (include); `\appear`/`\pause`/`\only` (with optional
   `[=N]`) become reveal fragments.
5. **markdown** — emphasis `**…**` / `*…*` (matching delimiter); `![alt](src)` image.
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

## Limits

- `table` (`tabular`) is kept opaque `deferred` — rendering needs the Compile port
  (latexml, ADR 0007); `include` (`\cat`) keeps only its path, resolution needs the
  Storage port. Both round-trip; neither renders yet.
- `columns`/`matrix` are structured, but their visual layout (multi-column, grid) is
  the render track. Markdown list nesting is by container only (a LaTeX item / HTML
  wrap holding a sublist), not markdown indentation.
- Whitespace/markers in lists, columns, and matrices normalize on save (list markers
  -> `-` and renumbered; matrix cells joined ` & `, rows ` \\ `), so only canonical
  text round-trips byte-exact. Matrix `&`/`\\` splitting respects braces but not math
  `$…$`.
- HTML tags must be attribute-less; math delimiters are only `$`/`$$`; an unmatched
  `$` or `*` is a literal character.
