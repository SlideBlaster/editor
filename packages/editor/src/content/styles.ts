/**
 * Derived semantic reads over surface-faithful runs. Contract: see styles.md.
 *
 * The headline claim of the tri-dialect model (ADR 0007) is that `\textbf{x}`,
 * `**x**`, and `<b>x</b>` MEAN the same thing while KEEPING their provenance. The
 * model stores provenance (the surface form); these functions derive the shared
 * meaning on demand, so meaning never desynchronizes from the serialization truth
 * (the A2 pattern from `../tikz/options`).
 */
import type { Dialect, TextRun } from '../model/content'

export type InlineStyle = 'bold' | 'italic' | 'underline' | 'strike'

const HTML_STYLE: Record<string, InlineStyle> = {
  b: 'bold',
  strong: 'bold',
  i: 'italic',
  em: 'italic',
  u: 'underline',
  s: 'strike',
}

/** The dialect a run was written in, or undefined for dialect-neutral runs (text/math). */
export function dialectOf(run: TextRun): Dialect | undefined {
  switch (run.kind) {
    case 'latex':
      return 'latex'
    case 'markdown':
      return 'md'
    case 'html':
      return 'html'
    case 'list':
      return run.dialect
    case 'image':
    case 'fragment':
      return run.dialect
    case 'overlay':
    case 'columns':
    case 'matrix':
    case 'include':
    case 'deferred':
    case 'cite':
    case 'citefootnote':
    case 'printbibliography':
      return 'latex'
    default:
      return undefined
  }
}

/** The inline style a run expresses, regardless of dialect; undefined if it is not a style. */
export function inlineStyleOf(run: TextRun): InlineStyle | undefined {
  switch (run.kind) {
    case 'latex':
      if (run.command === 'textbf') return 'bold'
      if (run.command === 'underline') return 'underline'
      return 'italic' // emph, textit
    case 'markdown':
      return run.marker === '**' ? 'bold' : 'italic'
    case 'html':
      return HTML_STYLE[run.tag.toLowerCase()]
    default:
      return undefined
  }
}
