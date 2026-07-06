# citeRenderer

The pure, framework-free core of citations — bibliography parsing plus citation
formatting. Ported from the slide-editor prototype (`src/rendering/citeRenderer.ts`).
Owns no document order and no async I/O; `citeCompiler` drives it.

- `parseBibFile(bibContent) -> BibDatabase` — parse a `.bib` string into a keyed map
  of `BibEntry` (authors, title, year, journal/booktitle, publisher, volume, pages)
  via `biblatex-csl-converter`.
- `parseCitationStyle(raw) -> CitationStyle` — the `citationStyle:` frontmatter value
  (`numeric` | `author-year` | `author-year-short`), defaulting to `numeric`.
- `formatCite(keys, db, style, counter) -> string` — an inline marker: `[1, 2]`
  (numeric) or `(Surname, year)` (author-year). Numeric assigns each key a 1-based
  number on first use by MUTATING `counter`, so the caller controls numbering order.
- `formatFootnoteText(keys, db) -> string` — the reference text for a footnote (the
  slide renderer supplies the number).
- `formatFullReference(entry) -> string` — a full bibliographic reference (authors,
  year, italic title, venue, volume/pages, publisher).
- `formatBibliography(db, style, counter) -> string` — the `\printbibliography` list:
  every key in `counter` (i.e. actually cited), in citation-number order.

## Contract

- **Pure** — no DOM, no fetch, no globals; the only state is the `counter` the caller
  passes in and this function fills. Deterministic given `(keys, db, style, counter)`.
- **Missing key never drops** — an unknown key renders as a visible `key?` marker.
- **HTML-safe** — bibliographic field text is escaped; callers embed the result
  directly.

## Types

`BibEntry`, `BibDatabase` (`{ entries: Map<key, BibEntry> }`), `CitationStyle`,
`CitationCounter` (`Map<key, number>`).
