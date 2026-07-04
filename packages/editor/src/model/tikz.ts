/**
 * The slide picture model: an ordered list of TikZ statements.
 * Contract: see tikz.md.
 *
 * A2 scope: statement STRUCTURE is modeled (node identity, options, absolute
 * position, paths, coordinates); node bodies and T2 constructs are kept verbatim.
 * Option tokens and verbatim spans are the serialization truth (span-preserving
 * round-trip, tikz-subset.md). Node bodies parse into tri-dialect content (A3);
 * see `./content`.
 */
import type { NodeContent } from './content'

export interface Point {
  x: number
  y: number
}

export interface TikzPicture {
  /** Ordered statements; this list is the serialization truth. */
  statements: Statement[]
}

export type Statement = NodeStatement | PathStatement | CoordinateStatement | VerbatimStatement

/**
 * `\node[options] (name) at (x,y) {content}`. `name` is the stable identity.
 * `options` are ordered raw tokens from `[...]` (the serialization truth for
 * options; structured views like style classes / placement are derived, not
 * stored — see `../tikz/options`).
 */
export interface NodeStatement {
  kind: 'node'
  name?: string
  options: string[]
  at?: Point
  content: NodeContent
}

/**
 * `\draw`/`\path`/`\fill`/`\filldraw`. A2 models the action and options; the
 * segment text between the options and the terminating `;` is verbatim (paths
 * become structurally editable later).
 */
export interface PathStatement {
  kind: 'path'
  action: 'draw' | 'fill' | 'filldraw' | 'path'
  options: string[]
  /** Verbatim segment text, including its leading separator whitespace. */
  body: string
}

/** `\coordinate (name) at (x,y)` — a named point. */
export interface CoordinateStatement {
  kind: 'coordinate'
  name: string
  at: Point
}

/**
 * Any statement not modeled in A2 (T2: `\foreach`, `\tikzset`, scopes, calc-heavy
 * paths, comments). Preserved exactly and never rewritten — the span-preserving
 * mechanism from tikz-subset.md.
 */
export interface VerbatimStatement {
  kind: 'verbatim'
  source: string
}
