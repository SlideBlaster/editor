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
 * The library — the P0 launch set (shapes-inventory.md): the shapes a presentation/diagram
 * user reaches for daily. Every entry is a preset of TikZ node options the engine already
 * renders (rect / ellipse / polygon / cylinder / stadium outlines). Agents extend THIS list
 * for P1+ (and, only for a NEW outline, add a `NodeShape` case in `render/shape`).
 */
export const SHAPES: ShapeDef[] = [
  // General / Basic
  {
    id: 'rectangle',
    label: 'Rectangle',
    category: 'General',
    keywords: ['box', 'rect', 'square'],
    options: ['draw'],
    size: { width: 3.2, height: 2 },
    body: '',
  },
  {
    id: 'rounded-rectangle',
    label: 'Rounded Rectangle',
    category: 'General',
    keywords: ['box', 'rounded', 'rect'],
    options: ['draw', 'rounded corners'],
    size: { width: 3.2, height: 2 },
    body: '',
  },
  {
    id: 'square',
    label: 'Square',
    category: 'General',
    keywords: ['box', 'rect'],
    options: ['draw'],
    size: { width: 2.2, height: 2.2 },
    body: '',
  },
  {
    id: 'ellipse',
    label: 'Ellipse',
    category: 'General',
    keywords: ['oval', 'round'],
    options: ['draw', 'ellipse'],
    size: { width: 3.2, height: 2 },
    body: '',
  },
  {
    id: 'circle',
    label: 'Circle',
    category: 'General',
    keywords: ['round', 'dot', 'oval'],
    options: ['draw', 'circle'],
    size: { width: 2.2, height: 2.2 },
    body: '',
  },
  {
    id: 'diamond',
    label: 'Diamond',
    category: 'General',
    keywords: ['rhombus', 'decision'],
    options: ['draw', 'diamond'],
    size: { width: 2.8, height: 2.2 },
    body: '',
  },
  {
    id: 'triangle',
    label: 'Triangle',
    category: 'General',
    keywords: ['delta', 'arrow'],
    options: ['draw', 'isosceles triangle'],
    size: { width: 2.6, height: 2.4 },
    body: '',
  },
  {
    id: 'trapezoid',
    label: 'Trapezoid',
    category: 'General',
    keywords: ['trapezium'],
    options: ['draw', 'trapezium'],
    size: { width: 3, height: 2 },
    body: '',
  },
  {
    id: 'parallelogram',
    label: 'Parallelogram',
    category: 'General',
    keywords: ['data', 'skew', 'rhomboid'],
    options: ['draw', 'parallelogram'],
    size: { width: 3.2, height: 2 },
    body: '',
  },
  {
    id: 'hexagon',
    label: 'Hexagon',
    category: 'General',
    keywords: ['polygon', 'preparation', 'six'],
    options: ['draw', 'regular polygon', 'regular polygon sides=6'],
    size: { width: 2.8, height: 2.4 },
    body: '',
  },
  {
    id: 'cylinder',
    label: 'Cylinder',
    category: 'General',
    keywords: ['database', 'db', 'disk', 'storage'],
    options: ['draw', 'cylinder'],
    size: { width: 2.4, height: 2.8 },
    body: '',
  },
  // Flowchart (reuses the General outlines with flowchart-conventional defaults)
  {
    id: 'flow-process',
    label: 'Process',
    category: 'Flowchart',
    keywords: ['action', 'step', 'rectangle'],
    options: ['draw'],
    size: { width: 3.2, height: 1.8 },
    body: '',
  },
  {
    id: 'flow-decision',
    label: 'Decision',
    category: 'Flowchart',
    keywords: ['branch', 'if', 'diamond'],
    options: ['draw', 'diamond'],
    size: { width: 3, height: 2.2 },
    body: '',
  },
  {
    id: 'flow-terminator',
    label: 'Terminator',
    category: 'Flowchart',
    keywords: ['start', 'end', 'stadium', 'pill'],
    options: ['draw', 'rounded rectangle'],
    size: { width: 3, height: 1.6 },
    body: '',
  },
  {
    id: 'flow-data',
    label: 'Data',
    category: 'Flowchart',
    keywords: ['io', 'input', 'output', 'parallelogram'],
    options: ['draw', 'parallelogram'],
    size: { width: 3.2, height: 1.8 },
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
