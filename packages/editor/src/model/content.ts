/**
 * Node-content model: the tri-dialect body of a `\node { … }`. Contract: see content.md.
 *
 * Scope so far: inline runs (text, opaque math, provenance-faithful emphasis in
 * every dialect); lists (md / LaTeX itemize+enumerate / HTML ul+ol, nestable);
 * reveal fragments (`\appear`/`\pause`/`\only`, optional `[=N]` step, `<appear>`);
 * images (`\image`, `![alt](src)`); and `columns`/`matrix` groups (fully structured
 * — only their visual layout is the render track). Two constructs parse but need a
 * port to render: `table` (`tabular` -> Compile, kept opaque as `deferred`) and
 * `include` (`\cat` -> Storage). Out-of-subset input becomes `error` (ADR 0015).
 *
 * Runs are SURFACE-FAITHFUL: each stores the exact form it was written in, so the
 * dialect (ADR 0007 provenance) is implicit in the run kind and byte-exact
 * round-trip is mechanical. Semantic reads ("is this bold?", "which dialect?") are
 * DERIVED in `../content/styles`, never stored — the A2 pattern (tikz.md) applied to
 * node content.
 */

/** A node body: nothing, parsed inline runs, or preserved-but-rejected source. */
export type NodeContent =
  | { kind: 'empty' }
  | { kind: 'text'; runs: TextRun[] }
  | { kind: 'error'; source: string; message: string }

/** An inline run. The kind encodes the dialect; children recurse (transparent nesting). */
export type TextRun =
  | { kind: 'text'; value: string }
  | { kind: 'math'; display: boolean; source: string }
  | { kind: 'latex'; command: LatexCommand; children: TextRun[] }
  | { kind: 'markdown'; marker: MarkdownMarker; children: TextRun[] }
  | { kind: 'html'; tag: string; children: TextRun[] }
  | { kind: 'list'; ordered: boolean; dialect: Dialect; items: ListItem[] }
  | { kind: 'columns'; columns: Column[] }
  | { kind: 'matrix'; options: string; rows: MatrixCell[][] }
  | { kind: 'fragment'; name: FragmentName; dialect: 'latex' | 'html'; at?: number }
  | { kind: 'image'; src: string; alt: string; dialect: 'latex' | 'md' }
  | { kind: 'include'; path: string }
  | { kind: 'deferred'; feature: DeferredFeature; source: string }

/** A list item: its inline content, which may itself contain a nested `list` run. */
export interface ListItem {
  children: TextRun[]
}

/** A column in a `columns` group; `width` is the raw `\column{…}` argument. */
export interface Column {
  width: string
  children: TextRun[]
}

/** One cell of a `matrix` group (rows are `MatrixCell[]`, split by `\\` and `&`). */
export interface MatrixCell {
  children: TextRun[]
}

/** LaTeX inline commands modeled in A3a. `\command{ … }`. */
export type LatexCommand = 'textbf' | 'emph' | 'textit' | 'underline'

/** Markdown emphasis delimiters modeled in A3a. */
export type MarkdownMarker = '*' | '**'

/** Reveal markers; `\appear`/`\only` take an optional `[=N]` step, `<appear>` is html. */
export type FragmentName = 'appear' | 'pause' | 'only'

/**
 * A supported construct parsed but not renderable without an external port, so its
 * source is preserved verbatim (round-trips; ADR 0015 does NOT apply — it is
 * in-subset). Only `table` (`tabular`) needs one: the Compile port (latexml, ADR
 * 0007). `\cat` is modeled as `include` (its path feeds the Storage port);
 * `columns`/`matrix` are fully structured above (only their visual layout is B).
 */
export type DeferredFeature = 'table'

/** Provenance tag (ADR 0007), derived from a run's kind in `../content/styles`. */
export type Dialect = 'md' | 'latex' | 'html'
