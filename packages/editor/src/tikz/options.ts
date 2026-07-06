/**
 * Derived, read-only views over a node's raw option tokens. Contract: see
 * options.md. These recompute from `NodeStatement.options` (the serialization
 * truth) so they never desynchronize; nothing here is stored on the model.
 */
import type { NodeStatement } from '../model/tikz'
import type { OverlaySpec } from '../model/content'

/** Bare (non `key=value`) tokens that name a style class, e.g. `title`, `body`. */
export function styleClasses(node: NodeStatement): string[] {
  return node.options.filter((token) => !token.includes('=') && !/^[<|>.-]+$/.test(token))
}

/**
 * The node's whole-node overlay reveal spec, from an `overlay=<spec>` option token (ADR
 * 0018) — the properties-panel half of the two-level model. The value is stored
 * brace-wrapped (`overlay={1,3}`) so a spec's commas survive option tokenizing; `<…>` is
 * also accepted. Returns the raw spec (interpreted by `content/overlay`), or undefined.
 */
export function nodeOverlay(node: NodeStatement): OverlaySpec | undefined {
  const token = node.options.find((t) => /^overlay\s*=/.test(t))
  if (token === undefined) return undefined
  let raw = token.slice(token.indexOf('=') + 1).trim()
  if ((raw.startsWith('{') && raw.endsWith('}')) || (raw.startsWith('<') && raw.endsWith('>'))) {
    raw = raw.slice(1, -1).trim()
  }
  return raw === '' ? undefined : { raw }
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

/**
 * Structured read of the relative-placement token: `below=0.7 of title`. A token that
 * omits the distance (`below= of title`) takes `defaultGap` — the theme's node distance
 * (ADR 0017), which defaults to `DEFAULT_PLACEMENT_GAP`.
 */
export function placement(
  node: NodeStatement,
  defaultGap: number = DEFAULT_PLACEMENT_GAP,
): Placement | undefined {
  const token = placementToken(node)
  if (token === undefined) return undefined
  const m = /^(above|below|left|right)\s*=\s*([\d.]*)\s*of\s+(\S+)/.exec(token)
  if (m === null) return undefined
  const gap = m[2] ? Number(m[2]) : defaultGap
  return {
    side: m[1] as Placement['side'],
    gap: Number.isNaN(gap) ? defaultGap : gap,
    ref: m[3]!,
  }
}

/** The `text width=<n>` value in slide units, if the node fixes its width. */
export function textWidth(node: NodeStatement): number | undefined {
  return numericOption(node, /^text\s+width\s*=/)
}

/**
 * The `minimum height=<n>` value in slide units, if the node sets a height floor. The
 * height counterpart to `text width`: grow-only, so content taller than `<n>` still
 * expands the box (the measurer takes `max(content, minimum height)`).
 */
export function minHeight(node: NodeStatement): number | undefined {
  return numericOption(node, /^minimum\s+height\s*=/)
}

/**
 * The node's content scale on each axis (default 1). TikZ multiplies a bare `scale=<k>`
 * into both axes and `xscale`/`yscale` per axis; resize writes these so the rendered
 * content (text, tables, images) grows with the box. `{ x: 1, y: 1 }` means natural size.
 */
export function nodeScale(node: NodeStatement): { x: number; y: number } {
  const base = numericOption(node, /^scale\s*=/) ?? 1
  const sx = numericOption(node, /^xscale\s*=/) ?? 1
  const sy = numericOption(node, /^yscale\s*=/) ?? 1
  return { x: base * sx, y: base * sy }
}

/** The numeric value of the first `key=<n>` option token matching `re`, else undefined. */
function numericOption(node: NodeStatement, re: RegExp): number | undefined {
  const token = node.options.find((t) => re.test(t))
  if (token === undefined) return undefined
  const n = Number(token.slice(token.indexOf('=') + 1).trim())
  return Number.isNaN(n) ? undefined : n
}
