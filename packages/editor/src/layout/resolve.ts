/**
 * Resolve a picture's nodes to placed geometry. Contract: see resolve.md.
 *
 * Sizes come from the injected `Measurer`; positions from `at (x,y)` (absolute) or a
 * relative placement (`below=<gap> of <ref>`) resolved edge-to-edge against the
 * reference node's box. Relative nodes are resolved in dependency order by iterating
 * to a fixpoint; a missing reference or a cycle falls back to the origin so the pass
 * is total.
 */
import type { NodeStatement, Point, TikzPicture } from '../model/tikz'
import type { Layout, PlacedNode, Size } from '../model/layout'
import {
  DEFAULT_PLACEMENT_GAP,
  minHeight,
  minWidth,
  fontSize,
  nodeScale,
  placement,
  styleClasses,
  textWidth,
} from '../tikz/options'
import type { BatchMeasurer, MeasureInput, Measurer } from './measure'

const ORIGIN: Point = { x: 0, y: 0 }

/** Layout tuning the theme supplies (ADR 0017). */
export interface LayoutOptions {
  /** Default relative-placement gap (the theme's node distance); omitted -> DEFAULT_PLACEMENT_GAP. */
  nodeDistance?: number
}

/** The node statements a picture lays out, in picture order. */
function layoutNodes(picture: TikzPicture): NodeStatement[] {
  return picture.statements.filter((s): s is NodeStatement => s.kind === 'node')
}

/** What a `Measurer` needs to size one node (content + its style/width options). */
function measureInputFor(node: NodeStatement): MeasureInput {
  const tw = textWidth(node)
  const mw = minWidth(node)
  const mh = minHeight(node)
  const fs = fontSize(node)
  return {
    content: node.content,
    styleClasses: styleClasses(node),
    ...(tw !== undefined ? { textWidth: tw } : {}),
    ...(mw !== undefined ? { minWidth: mw } : {}),
    ...(mh !== undefined ? { minHeight: mh } : {}),
    ...(fs !== undefined ? { fontSize: fs } : {}),
  }
}

/** Multiply a natural (measured) content size by the node's content scale. */
function scaleSize(size: Size, scale: { x: number; y: number }): Size {
  return { width: size.width * scale.x, height: size.height * scale.y }
}

/** Sync layout: sizes from a `Measurer` (scaled by each node's content scale), then solve. */
export function resolveLayout(
  picture: TikzPicture,
  measurer: Measurer,
  opts: LayoutOptions = {},
): Layout {
  const nodes = layoutNodes(picture)
  const sizes = nodes.map((n) => scaleSize(measurer.measure(measureInputFor(n)), nodeScale(n)))
  return solveLayout(nodes, sizes, opts.nodeDistance)
}

/**
 * Async layout: sizes from a `BatchMeasurer` (the DOM measurer), then the same
 * geometry solve. Only the sizing differs from `resolveLayout`; placement is shared.
 */
export async function resolveLayoutAsync(
  picture: TikzPicture,
  measurer: BatchMeasurer,
  opts: LayoutOptions = {},
): Promise<Layout> {
  const nodes = layoutNodes(picture)
  const natural = await measurer.measureAll(nodes.map(measureInputFor))
  const sizes = natural.map((size, i) => scaleSize(size, nodeScale(nodes[i]!)))
  return solveLayout(nodes, sizes, opts.nodeDistance)
}

/** Place already-sized nodes: absolute `at`, relative placement, or origin (total). */
function solveLayout(
  nodes: NodeStatement[],
  sizes: Size[],
  nodeDistance: number = DEFAULT_PLACEMENT_GAP,
): Layout {
  const indexByName = new Map<string, number>()
  nodes.forEach((n, i) => {
    if (n.name !== undefined) indexByName.set(n.name, i)
  })

  const placed: (PlacedNode | undefined)[] = new Array(nodes.length)
  const place = (i: number, center: Point): PlacedNode => {
    const node = nodes[i]!
    return {
      center,
      size: sizes[i]!,
      styleClasses: styleClasses(node),
      ...(node.name !== undefined ? { name: node.name } : {}),
    }
  }

  // Absolute and default-positioned nodes resolve immediately; relative nodes wait
  // for their reference. `undefined` means "reference not yet placed — retry".
  const tryResolve = (i: number): PlacedNode | undefined => {
    const node = nodes[i]!
    if (node.at !== undefined) return place(i, node.at)
    const rel = placement(node, nodeDistance)
    if (rel === undefined) return place(i, ORIGIN)
    const refIndex = indexByName.get(rel.ref)
    if (refIndex === undefined) return place(i, ORIGIN) // dangling reference
    const ref = placed[refIndex]
    if (ref === undefined) return undefined // reference pending
    return place(i, relativeCenter(ref, sizes[i]!, rel.side, rel.gap))
  }

  let progressed = true
  while (progressed) {
    progressed = false
    for (let i = 0; i < nodes.length; i++) {
      if (placed[i] !== undefined) continue
      const result = tryResolve(i)
      if (result !== undefined) {
        placed[i] = result
        progressed = true
      }
    }
  }
  // Anything still unplaced is in a cycle or points at a pending cycle: pin to origin.
  for (let i = 0; i < nodes.length; i++) {
    if (placed[i] === undefined) placed[i] = place(i, ORIGIN)
  }

  return { nodes: placed as PlacedNode[] }
}

/** Center of a node placed `side` of `ref` with an edge-to-edge `gap` (y-up). */
function relativeCenter(
  ref: PlacedNode,
  size: Size,
  side: 'above' | 'below' | 'left' | 'right',
  gap: number,
): Point {
  const rhw = ref.size.width / 2
  const rhh = ref.size.height / 2
  const hw = size.width / 2
  const hh = size.height / 2
  switch (side) {
    case 'below':
      return { x: ref.center.x, y: ref.center.y - rhh - gap - hh }
    case 'above':
      return { x: ref.center.x, y: ref.center.y + rhh + gap + hh }
    case 'left':
      return { x: ref.center.x - rhw - gap - hw, y: ref.center.y }
    case 'right':
      return { x: ref.center.x + rhw + gap + hw, y: ref.center.y }
  }
}

export type AnchorName =
  | 'center'
  | 'north'
  | 'south'
  | 'east'
  | 'west'
  | 'north east'
  | 'north west'
  | 'south east'
  | 'south west'

const ANCHOR_NAMES: readonly AnchorName[] = [
  'center',
  'north',
  'south',
  'east',
  'west',
  'north east',
  'north west',
  'south east',
  'south west',
]

/** Whether `s` names a node anchor (so a connector's `(name.anchor)` port is resolvable). */
export function isAnchorName(s: string): s is AnchorName {
  return (ANCHOR_NAMES as readonly string[]).includes(s)
}

/** A named anchor point of a placed node, in slide space (the id-anchor of ADR 0003). */
export function anchor(node: PlacedNode, name: AnchorName = 'center'): Point {
  const { x, y } = node.center
  const hw = node.size.width / 2
  const hh = node.size.height / 2
  switch (name) {
    case 'center':
      return { x, y }
    case 'north':
      return { x, y: y + hh }
    case 'south':
      return { x, y: y - hh }
    case 'east':
      return { x: x + hw, y }
    case 'west':
      return { x: x - hw, y }
    case 'north east':
      return { x: x + hw, y: y + hh }
    case 'north west':
      return { x: x - hw, y: y + hh }
    case 'south east':
      return { x: x + hw, y: y - hh }
    case 'south west':
      return { x: x - hw, y: y - hh }
  }
}

/** Look up a placed node by its name (the TikZ id). */
export function findPlaced(layout: Layout, name: string): PlacedNode | undefined {
  return layout.nodes.find((n) => n.name === name)
}
