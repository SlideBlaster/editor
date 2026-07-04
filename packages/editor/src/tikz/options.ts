/**
 * Derived, read-only views over a node's raw option tokens. Contract: see
 * options.md. These recompute from `NodeStatement.options` (the serialization
 * truth) so they never desynchronize; nothing here is stored on the model.
 */
import type { NodeStatement } from '../model/tikz'

/** Bare (non `key=value`) tokens that name a style class, e.g. `title`, `body`. */
export function styleClasses(node: NodeStatement): string[] {
  return node.options.filter((token) => !token.includes('=') && !/^[<|>.-]+$/.test(token))
}

/** The `title` style class marks the slide's title node. */
export function role(node: NodeStatement): 'title' | undefined {
  return styleClasses(node).includes('title') ? 'title' : undefined
}

/** Whether a raw option token is a relative placement (`below=0.7 of title`). */
export function isPlacementToken(token: string): boolean {
  return /^(above|below|left|right)\b.*=.*\bof\b/.test(token)
}

/** The first relative-placement token (`below=0.7 of title`), if any. */
export function placementToken(node: NodeStatement): string | undefined {
  return node.options.find(isPlacementToken)
}

/** Default gap (slide units) for a relative placement written without a distance. */
export const DEFAULT_PLACEMENT_GAP = 0.5

export interface Placement {
  side: 'above' | 'below' | 'left' | 'right'
  gap: number
  ref: string
}

/** Structured read of the relative-placement token: `below=0.7 of title`. */
export function placement(node: NodeStatement): Placement | undefined {
  const token = placementToken(node)
  if (token === undefined) return undefined
  const m = /^(above|below|left|right)\s*=\s*([\d.]*)\s*of\s+(\S+)/.exec(token)
  if (m === null) return undefined
  const gap = m[2] ? Number(m[2]) : DEFAULT_PLACEMENT_GAP
  return {
    side: m[1] as Placement['side'],
    gap: Number.isNaN(gap) ? DEFAULT_PLACEMENT_GAP : gap,
    ref: m[3]!,
  }
}

/** The `text width=<n>` value in slide units, if the node fixes its width. */
export function textWidth(node: NodeStatement): number | undefined {
  const token = node.options.find((t) => /^text\s+width\s*=/.test(t))
  if (token === undefined) return undefined
  const n = Number(token.slice(token.indexOf('=') + 1).trim())
  return Number.isNaN(n) ? undefined : n
}
