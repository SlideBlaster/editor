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
import type { ListItem, NodeContent, OverlaySpec, TextRun } from '../model/content'
import { inlineStyleOf, type InlineStyle } from '../content/styles'
import { activeAt, specMinStep } from '../content/overlay'

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
  /**
   * The overlay step to render (1-based, ADR 0018). When set, overlay content inactive
   * at this step is hidden with its space reserved (`visibility:hidden`), and
   * `\pause`/`\appear` hide the content that follows them until their step. Omit to
   * render the maximal, all-visible authoring state — nothing is hidden.
   */
  step?: number
  /**
   * Slide-box width in slide units (ADR 0017 aspect ratio); height is fixed at 9, so this
   * sets the shape: 16 = 16:9 (default), 12 = 4:3, 14.4 = 16:10. Drives the SVG viewBox, the
   * `.sb-slide` aspect-ratio, and the x-axis percentages. Omit for the 16:9 default.
   */
  slideWidth?: number
}

export function renderContent(content: NodeContent, options: RenderOptions = {}): string {
  switch (content.kind) {
    case 'empty':
      return ''
    case 'error':
      return `<span class="sb-error" title="${escapeAttr(content.message)}">${escape(content.source)}</span>`
    case 'text':
      return renderRuns(content.runs, options, 1)
  }
}

/**
 * Render a run sequence. `floor` is the step from which this sequence's content is
 * visible (raised by a preceding `\pause`/`\appear`, ADR 0018). A fragment emits its
 * marker, raises the floor, and wraps the remaining tail so it is hidden until that
 * step; everything else renders in order at the current floor.
 */
function renderRuns(runs: TextRun[], options: RenderOptions, floor: number): string {
  let out = ''
  for (let k = 0; k < runs.length; k++) {
    const run = runs[k]!
    if (run.kind === 'fragment') {
      out += `<span class="sb-fragment" data-fragment="${escapeAttr(run.name)}"></span>`
      const tail = runs.slice(k + 1)
      const nextFloor = run.spec ? specMinStep(run.spec) : floor + 1
      out += gate(renderRuns(tail, options, nextFloor), tail, options.step, nextFloor)
      return out
    }
    out += renderRun(run, options, floor)
  }
  return out
}

/**
 * Wrap `html` (the content after a `\pause`) so it is hidden until step `floor`. Reserves
 * its space (`visibility:hidden`) — reveal never reflows. A block-containing tail wraps in
 * a `<div>` (a `<span>` cannot hold block elements); otherwise a `<span>`. When no step is
 * being rendered (authoring show-all) or it is already reached, the html passes through.
 */
function gate(html: string, tail: TextRun[], step: number | undefined, floor: number): string {
  if (step === undefined || step >= floor) return html
  const el = tail.some(isBlockRun) ? 'div' : 'span'
  return `<${el} class="sb-overlay sb-ov-hidden" data-appear="${floor}">${html}</${el}>`
}

/** Runs that render as block-level elements (so a gating wrapper must be a `<div>`). */
function isBlockRun(run: TextRun): boolean {
  return (
    run.kind === 'list' ||
    run.kind === 'columns' ||
    run.kind === 'matrix' ||
    run.kind === 'deferred' ||
    run.kind === 'printbibliography'
  )
}

function renderRun(run: TextRun, options: RenderOptions, floor: number): string {
  switch (run.kind) {
    case 'text':
      return escape(run.value)
    case 'math':
      return (options.renderMath ?? defaultMath)(run.source, run.display)
    case 'latex':
    case 'markdown':
      return styleElement(inlineStyleOf(run), renderRuns(run.children, options, floor))
    case 'html': {
      const style = inlineStyleOf(run)
      const inner = renderRuns(run.children, options, floor)
      return style ? styleElement(style, inner) : `<${run.tag}>${inner}</${run.tag}>`
    }
    case 'overlay':
      return renderOverlay(run, options, floor)
    case 'list': {
      const tag = run.ordered ? 'ol' : 'ul'
      const items = run.items
        .map(
          (item) =>
            `<li${itemAttrs(item, options.step)}>${renderRuns(item.children, options, floor)}</li>`,
        )
        .join('')
      return `<${tag}>${items}</${tag}>`
    }
    case 'columns': {
      const cols = run.columns
        .map(
          (col) =>
            `<div class="sb-column" style="flex:${Number(col.width) || 1}">${renderRuns(col.children, options, floor)}</div>`,
        )
        .join('')
      return `<div class="sb-columns">${cols}</div>`
    }
    case 'matrix': {
      const rows = run.rows
        .map(
          (row) =>
            `<tr>${row.map((cell) => `<td>${renderRuns(cell.children, options, floor)}</td>`).join('')}</tr>`,
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
    case 'fragment':
      // Normally intercepted by `renderRuns` (which also gates the tail); this is the
      // fallback for a stray fragment reached directly.
      return `<span class="sb-fragment" data-fragment="${escapeAttr(run.name)}"></span>`
  }
}

/**
 * Render an overlay-wrapping command (`\only<spec>{…}` etc.) at the current step. Space is
 * always reserved (ADR 0018 fixed geometry), so hiding is `visibility:hidden`, never a
 * removal — `only`/`uncover`/`visible` show when the spec is active, `invisible` hides when
 * active, `alert` always shows and highlights when active. With no step (authoring show-all)
 * nothing is hidden; a spec-less `\alert{…}` highlights always.
 */
function renderOverlay(
  run: Extract<TextRun, { kind: 'overlay' }>,
  options: RenderOptions,
  floor: number,
): string {
  const inner = renderRuns(run.children, options, floor)
  const on = run.spec && options.step !== undefined ? activeAt(run.spec, options.step) : undefined
  const classes = ['sb-overlay']
  if (run.command === 'alert') {
    if (run.spec === undefined || on) classes.push('sb-ov-alert')
  } else if (on !== undefined) {
    const hidden = run.command === 'invisible' ? on : !on
    if (hidden) classes.push('sb-ov-hidden')
  }
  const data = run.spec ? ` data-overlay="${escapeAttr(run.spec.raw)}"` : ''
  return `<span class="${classes.join(' ')}" data-ov="${run.command}"${data}>${inner}</span>`
}

/** A list item's overlay attributes: hidden (space reserved) when its `\item<spec>` is
 *  inactive at `step`. Empty when it has no spec or no step is being rendered. */
function itemAttrs(item: ListItem, step: number | undefined): string {
  if (item.spec === undefined || step === undefined) return ''
  return activeAt(item.spec, step) ? '' : ' class="sb-ov-hidden"'
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
