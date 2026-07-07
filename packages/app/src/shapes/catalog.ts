/**
 * The shapes catalogue: the draw.io-style library the shapes panel presents. Contract:
 * see catalog.md.
 *
 * A shape is NOT a model concept — it is a curated PRESET of TikZ node options (ADR 0004:
 * a slide is one TikZ picture; every object is a `\node`). Dropping a shape on the canvas
 * is exactly `createNode` with these options, so a dragged-in shape and a hand-typed
 * `\node[...]` are byte-identical, and the engine already renders, moves, resizes, and
 * serializes it. This file is therefore pure data — the thing agents grow to fill the
 * library. Adding a shape is one entry here (plus, only if it needs a NEW outline, one
 * `NodeShape` case in the engine's `render/shape`).
 */

export interface ShapeDef {
  /** Stable id — the drag payload and the catalogue key. */
  id: string
  /** Human label shown under the thumbnail; also its accessible name. */
  label: string
  /** Category heading the shape groups under in the panel. */
  category: string
  /** Extra search terms beyond the label (draw.io-style fuzzy find). */
  keywords: string[]
  /**
   * The TikZ node options this shape stamps — its whole essence; they become the new
   * node's `options`, so the shape IS whatever `\node[...]` these describe. Keep size out
   * of here: the drop appends `minimum width/height` from `size`.
   */
  options: string[]
  /** Default drop size in slide units, applied as grow-only `minimum width/height` floors. */
  size: { width: number; height: number }
  /** Initial raw body, parsed on insert. Empty means an empty box to type a label into. */
  body: string
}

/**
 * The library. One archetype for now — an ellipse, which exercises the whole path: a
 * catalogue preset, an SVG element chosen from a shape token, a visible stroke, and a
 * default size. Agents extend THIS list (and, per new outline, `render/shape`).
 */
export const SHAPES: ShapeDef[] = [
  {
    id: 'ellipse',
    label: 'Ellipse',
    category: 'General',
    keywords: ['oval', 'circle', 'round'],
    options: ['draw', 'ellipse'],
    size: { width: 3.2, height: 2 },
    body: '',
  },
]

/** Look a shape up by id (the drag payload / a panel click carries the id). */
export function shapeById(id: string): ShapeDef | undefined {
  return SHAPES.find((shape) => shape.id === id)
}

/** Categories in first-seen order, each with its shapes — the panel's section list. */
export function shapeCategories(): { name: string; shapes: ShapeDef[] }[] {
  const order: string[] = []
  const byCategory = new Map<string, ShapeDef[]>()
  for (const shape of SHAPES) {
    let group = byCategory.get(shape.category)
    if (group === undefined) {
      group = []
      byCategory.set(shape.category, group)
      order.push(shape.category)
    }
    group.push(shape)
  }
  return order.map((name) => ({ name, shapes: byCategory.get(name)! }))
}

/** The node options a dropped shape carries: its essence plus its size floors. */
export function shapeNodeOptions(shape: ShapeDef): string[] {
  return [
    ...shape.options,
    `minimum width=${shape.size.width}`,
    `minimum height=${shape.size.height}`,
  ]
}

/** Whether a shape matches a search query (label or keywords, case-insensitive). */
export function shapeMatches(shape: ShapeDef, query: string): boolean {
  const q = query.trim().toLowerCase()
  if (q === '') return true
  return (
    shape.label.toLowerCase().includes(q) ||
    shape.keywords.some((keyword) => keyword.toLowerCase().includes(q))
  )
}
