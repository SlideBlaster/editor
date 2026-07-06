/**
 * Text measurement behind a seam. Contract: see measure.md.
 *
 * The layout pass never re-implements text metrics — it asks a `Measurer`. This
 * increment ships a NAIVE metric estimate (deterministic, DOM-free) so the resolve
 * pass and its tests are headless. The real DOM-measurement adapter (render each
 * node's HTML, read its box) is the flagged Track-0 spike and drops in behind this
 * same interface without touching `resolve`.
 */
import type { NodeContent, TextRun } from '../model/content'
import type { Size } from '../model/layout'

export interface MeasureInput {
  content: NodeContent
  /** `text width=<n>` when the node fixes its width (content wraps to it). */
  textWidth?: number
  /** `minimum height=<n>` when the node sets a height floor (grow-only: content may exceed it). */
  minHeight?: number
  styleClasses: string[]
}

export interface Measurer {
  measure(input: MeasureInput): Size
}

/**
 * The async, batched twin of `Measurer`. A real DOM measurer needs to await
 * (`document.fonts.ready`, math typesetting) and wants ALL of a slide's nodes at
 * once so it inserts them, forces one reflow, and reads every box together. The
 * geometry solve (`resolveLayoutAsync`) depends only on this interface.
 */
export interface BatchMeasurer {
  measureAll(inputs: readonly MeasureInput[]): Promise<Size[]>
}

/** Lift a synchronous `Measurer` to a `BatchMeasurer` (the headless default / fallback). */
export function asBatch(measurer: Measurer): BatchMeasurer {
  return { measureAll: (inputs) => Promise.resolve(inputs.map((i) => measurer.measure(i))) }
}

// Placeholder metrics in slide units — replaced wholesale by the DOM measurer.
const CHAR_WIDTH = 0.14
const LINE_HEIGHT = 0.55
const PADDING = 0.2
const MIN_WIDTH = 1
const MIN_HEIGHT = 0.6
const TITLE_SCALE = 1.4

/** Deterministic estimate from character/line counts; good enough to lay out, not to render. */
export const naiveMeasurer: Measurer = {
  measure({ content, textWidth, minHeight, styleClasses }): Size {
    const scale = styleClasses.includes('title') ? TITLE_SCALE : 1
    const charW = CHAR_WIDTH * scale
    const lineH = LINE_HEIGHT * scale
    const lines = plainText(content).split('\n')
    // `minimum height` is grow-only: it raises the height floor but never clips content.
    const floor = Math.max(MIN_HEIGHT, minHeight ?? 0)

    if (content.kind === 'empty') return { width: MIN_WIDTH, height: floor }

    if (textWidth !== undefined) {
      const perLine = Math.max(1, Math.floor((textWidth - 2 * PADDING) / charW))
      const rows = lines.reduce((n, line) => n + Math.max(1, Math.ceil(line.length / perLine)), 0)
      return { width: textWidth, height: Math.max(floor, rows * lineH + 2 * PADDING) }
    }

    const longest = lines.reduce((m, line) => Math.max(m, line.length), 0)
    return {
      width: Math.max(MIN_WIDTH, longest * charW + 2 * PADDING),
      height: Math.max(floor, lines.length * lineH + 2 * PADDING),
    }
  },
}

/** Flatten content to a plain string for metric estimation only (not for rendering). */
function plainText(content: NodeContent): string {
  switch (content.kind) {
    case 'empty':
      return ''
    case 'error':
      return content.source
    case 'text':
      return content.runs.map(runText).join('')
  }
}

function runText(run: TextRun): string {
  switch (run.kind) {
    case 'text':
      return run.value
    case 'math':
      return run.source
    case 'latex':
    case 'markdown':
    case 'html':
      return run.children.map(runText).join('')
    case 'overlay':
      // Measured as present (union geometry, ADR 0018) — its box is reserved on every step.
      return run.children.map(runText).join('')
    case 'list':
      return run.items.map((item) => item.children.map(runText).join('')).join('\n')
    case 'columns':
      return run.columns.map((col) => col.children.map(runText).join('')).join('  ')
    case 'matrix':
      return run.rows
        .map((row) => row.map((cell) => cell.children.map(runText).join('')).join('  '))
        .join('\n')
    case 'image':
      return run.alt || 'image'
    case 'include':
      return run.path
    case 'fragment':
      return ''
    case 'deferred':
      return run.source
    case 'cite':
      // A resolved numeric cite is ~"[1]"; the DOM measurer re-measures once the
      // bibliography loads. This naive proxy just needs a small, non-empty width.
      return '[?]'
    case 'citefootnote':
      // A superscript marker — negligible in the naive fallback (like `fragment`).
      return ''
    case 'printbibliography':
      // A block resolved from the deck's cited keys; a minimal proxy pre-resolution.
      return 'bibliography'
  }
}
