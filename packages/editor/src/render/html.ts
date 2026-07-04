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
 */
import type { NodeContent, TextRun } from '../model/content'
import { inlineStyleOf, type InlineStyle } from '../content/styles'

export interface RenderOptions {
  /** Render inline/display math to HTML. Defaults to a source-carrying placeholder. */
  renderMath?: (source: string, display: boolean) => string
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
    case 'deferred':
      return `<div class="sb-deferred" data-feature="${escapeAttr(run.feature)}">${escape(run.feature)} &mdash; render pending</div>`
    case 'fragment':
      return `<span class="sb-fragment" data-fragment="${escapeAttr(run.name)}"${run.at !== undefined ? ` data-at="${run.at}"` : ''}></span>`
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
