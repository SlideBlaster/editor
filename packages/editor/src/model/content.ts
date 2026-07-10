/**
 * Node-content model: the tri-dialect body of a `\node { … }`. Contract: see content.md.
 *
 * Scope so far: inline runs (text, opaque math, provenance-faithful emphasis in
 * every dialect); lists (md / LaTeX itemize+enumerate / HTML ul+ol, nestable);
 * overlays — point fragments (`\pause`/`\appear`, `<appear>`) and wrapping commands
 * (`\only`/`\uncover`/`\visible`/`\invisible`/`\alert`), each carrying an optional
 * Beamer `<spec>`, step-gated at render (ADR 0018, `../content/overlay`);
 * images (`\image`, `![alt](src)`); and `columns`/`matrix` groups (fully structured
 * — only their visual layout is the render track). Two constructs parse but need a
 * port to render: `table` (`tabular` -> Compile, kept opaque as `deferred`) and
 * `include` (`\cat` -> Storage). Citations (`\cite`, `\citefootnote`,
 * `\printbibliography`) parse to structured runs that carry only their keys; the
 * bibliography (`.bib` via the Storage port) and numbering are resolved by the render
 * track, exactly like math/tables. Out-of-subset input becomes `error` (ADR 0015).
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
  | { kind: 'fragment'; name: FragmentName; dialect: 'latex' | 'html'; spec?: OverlaySpec }
  | { kind: 'overlay'; command: OverlayCommand; children: TextRun[]; spec?: OverlaySpec }
  | { kind: 'image'; src: string; alt: string; dialect: 'latex' | 'md' }
  | { kind: 'include'; path: string }
  | { kind: 'deferred'; feature: DeferredFeature; source: string }
  | { kind: 'cite'; keys: string[] }
  | { kind: 'citefootnote'; keys: string[] }
  | { kind: 'printbibliography' }

/** A list item: its inline content, which may itself contain a nested `list` run.
 *  `spec` is a LaTeX `\item<spec>` overlay (the item appears on those steps). */
export interface ListItem {
  children: TextRun[]
  spec?: OverlaySpec
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

/** LaTeX inline commands modeled in A3a. `\command{ … }`. `\hl` is soul's highlight. */
export type LatexCommand = 'textbf' | 'emph' | 'textit' | 'underline' | 'hl'

/** Markdown emphasis delimiters modeled in A3a. `==` is the highlight marker. */
export type MarkdownMarker = '*' | '**' | '=='

/** Point reveal markers: `\pause`/`\appear` (opt. `<spec>`) and the html `<appear>`.
 *  They raise the reading-order step floor — content after them appears later. */
export type FragmentName = 'appear' | 'pause'

/**
 * A Beamer overlay specification — the raw text inside `<…>` (e.g. `2-`, `2-4`, `1,3`).
 * Stored verbatim so it round-trips byte-for-byte; `../content/overlay` interprets it
 * (`activeAt(spec, step)`, `specMaxStep`, `specMinStep`). A malformed spec never reaches
 * the model — the parser rejects it as out-of-subset (ADR 0015/0018).
 */
export interface OverlaySpec {
  raw: string
}

/**
 * Overlay-aware wrapping commands: `\command<spec>{ … }`. Visibility at a step:
 * `only`/`uncover`/`visible` show when the spec is active (hide otherwise);
 * `invisible` hides when active; `alert` always shows but highlights when active.
 * Under fixed geometry (ADR 0018) `only` and `uncover` reserve the same space.
 */
export type OverlayCommand = 'only' | 'uncover' | 'visible' | 'invisible' | 'alert'

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
