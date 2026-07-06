/**
 * Render node content to HTML. Contract: see html.md.
 *
 * The content layer of the layered DOM (ADR 0014): each run becomes its semantic
 * element, so `\textbf{x}` / `**x**` / `<b>x</b>` all render as `<strong>x</strong>`
 * (tri-dialect equivalence made visible). Pure string output, so it is headless and
 * snapshot-testable. Math goes through a seam (`renderMath`) that defaults to a
 * marked placeholder carrying the source; a KaTeX adapter drops in behind it at
 * shell-integration time, exactly like the layout Measurer.
 *
 * Port-gated payloads render as labelled placeholders, never dropped: a `deferred`
 * table says "render pending" (Compile port), an `include` shows its path (Storage
 * port).
 *
 * Citations resolve through the same seam pattern: `renderCite`/`renderBibliography`
 * turn keys into `[1]` / a reference list once the app has loaded the `.bib` and
 * numbered the deck. A `\citefootnote` renders only its inline `<sup>` marker here —
 * the number is assigned by the per-slide `footnotes` sink (`slide.ts`), which also
 * emits the footnote band, since numbering and placement are slide-level concerns.
 */
import type { NodeContent, TextRun } from '../model/content'
import { inlineStyleOf, type InlineStyle } from '../content/styles'

/**
 * Per-slide footnote collector. `slide.ts` supplies one, calling `add` as each
 * `\citefootnote` renders (in reading order) to get its 1-based slide-local number,
 * then reads the collected keys back to emit the footnote band. Absent for a bare
 * content render (e.g. measurement) — the marker then renders without a number.
 */
export interface FootnoteSink {
  add(keys: string[]): number
}

export interface RenderOptions {
  /** Render inline/display math to HTML. Defaults to a source-carrying placeholder. */
  renderMath?: (source: string, display: boolean) => string
  /**
   * Render a deferred table's LaTeX to HTML via the Compile port. Returns the
   * compiled fragment, or `undefined` when it is not yet available (not compiled,
   * compiling, or no engine) — the caller then shows the "render pending"
   * placeholder. Synchronous by contract: the async compile happens out of band and
   * populates a cache this reads, exactly like `renderMath` reads KaTeX.
   */
  renderTable?: (source: string) => string | undefined
  /**
   * Render an inline `\cite{keys}` to its marker HTML (e.g. `[1]`), or `undefined`
   * when the bibliography is not yet loaded — the caller shows a `[?]` placeholder.
   * Sync by contract, reading a cache the app fills out of band (like `renderTable`).
   */
  renderCite?: (keys: string[]) => string | undefined
  /**
   * Render `\printbibliography{}` to a reference list, or `undefined` while the
   * bibliography loads — the caller then shows a "render pending" placeholder.
   */
  renderBibliography?: () => string | undefined
  /**
   * Format one footnote's reference text for the slide-bottom band (the app supplies
   * the bibliography). Undefined -> the band falls back to the raw keys. Consumed by
   * `slide.ts`, not `renderContent`.
   */
  renderFootnoteText?: (keys: string[]) => string | undefined
  /** Per-slide footnote sink; `slide.ts` provides it (see `FootnoteSink`). */
  footnotes?: FootnoteSink
}

export function renderContent(content: NodeContent, options: RenderOptions = {}): string {
  switch (content.kind) {
    case 'empty':
      return ''
    case 'error':
      return `<span class="sb-error" title="${escapeAttr(content.message)}">${escape(content.source)}</span>`
    case 'text':
      return renderRuns(content.runs, options)
  }
}

function renderRuns(runs: TextRun[], options: RenderOptions): string {
  return runs.map((run) => renderRun(run, options)).join('')
}

function renderRun(run: TextRun, options: RenderOptions): string {
  switch (run.kind) {
    case 'text':
      return escape(run.value)
    case 'math':
      return (options.renderMath ?? defaultMath)(run.source, run.display)
    case 'latex':
    case 'markdown':
      return styleElement(inlineStyleOf(run), renderRuns(run.children, options))
    case 'html': {
      const style = inlineStyleOf(run)
      const inner = renderRuns(run.children, options)
      return style ? styleElement(style, inner) : `<${run.tag}>${inner}</${run.tag}>`
    }
    case 'list': {
      const tag = run.ordered ? 'ol' : 'ul'
      const items = run.items
        .map((item) => `<li>${renderRuns(item.children, options)}</li>`)
        .join('')
      return `<${tag}>${items}</${tag}>`
    }
    case 'columns': {
      const cols = run.columns
        .map(
          (col) =>
            `<div class="sb-column" style="flex:${Number(col.width) || 1}">${renderRuns(col.children, options)}</div>`,
        )
        .join('')
      return `<div class="sb-columns">${cols}</div>`
    }
    case 'matrix': {
      const rows = run.rows
        .map(
          (row) =>
            `<tr>${row.map((cell) => `<td>${renderRuns(cell.children, options)}</td>`).join('')}</tr>`,
        )
        .join('')
      return `<table class="sb-matrix"><tbody>${rows}</tbody></table>`
    }
    case 'image':
      return `<img src="${escapeAttr(run.src)}" alt="${escapeAttr(run.alt)}">`
    case 'include':
      return `<span class="sb-include" data-path="${escapeAttr(run.path)}">[include: ${escape(run.path)}]</span>`
    case 'deferred': {
      const compiled = run.feature === 'table' ? options.renderTable?.(run.source) : undefined
      if (compiled !== undefined)
        return `<div class="sb-table" data-feature="${escapeAttr(run.feature)}">${compiled}</div>`
      return `<div class="sb-deferred" data-feature="${escapeAttr(run.feature)}">${escape(run.feature)} &mdash; render pending</div>`
    }
    case 'fragment':
      return `<span class="sb-fragment" data-fragment="${escapeAttr(run.name)}"${run.at !== undefined ? ` data-at="${run.at}"` : ''}></span>`
    case 'cite': {
      const resolved = options.renderCite?.(run.keys)
      return `<span class="sb-cite">${resolved ?? '[?]'}</span>`
    }
    case 'citefootnote': {
      const n = options.footnotes?.add(run.keys)
      return `<sup class="sb-fn-marker">${n ?? '?'}</sup>`
    }
    case 'printbibliography': {
      const resolved = options.renderBibliography?.()
      if (resolved !== undefined) return `<div class="sb-bibliography">${resolved}</div>`
      return `<div class="sb-deferred" data-feature="bibliography">bibliography &mdash; render pending</div>`
    }
  }
}

const STYLE_TAG: Record<InlineStyle, string> = {
  bold: 'strong',
  italic: 'em',
  underline: 'u',
  strike: 's',
}

function styleElement(style: InlineStyle | undefined, inner: string): string {
  const tag = style ? STYLE_TAG[style] : 'span'
  return `<${tag}>${inner}</${tag}>`
}

function defaultMath(source: string, display: boolean): string {
  return `<span class="sb-math" data-mode="${display ? 'display' : 'inline'}">${escape(source)}</span>`
}

function escape(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function escapeAttr(s: string): string {
  return escape(s).replace(/"/g, '&quot;')
}
