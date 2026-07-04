/**
 * Node-content model: the tri-dialect body of a `\node { … }`. Contract: see content.md.
 *
 * A3a scope: inline runs only — literal text, opaque math, and provenance-faithful
 * emphasis in each dialect (LaTeX `\textbf`/`\emph`/`\textit`/`\underline`, markdown
 * `**`/`*`, HTML inline/wrap tags). Lists and the port-coupled payloads (tables,
 * `\cat`, image, group, fragments) are A3b/A3c. Out-of-subset input becomes `error`
 * (ADR 0015); ordinary text and not-yet-modeled markdown stay literal `text`.
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

/** LaTeX inline commands modeled in A3a. `\command{ … }`. */
export type LatexCommand = 'textbf' | 'emph' | 'textit' | 'underline'

/** Markdown emphasis delimiters modeled in A3a. */
export type MarkdownMarker = '*' | '**'

/** Provenance tag (ADR 0007), derived from a run's kind in `../content/styles`. */
export type Dialect = 'md' | 'latex' | 'html'
