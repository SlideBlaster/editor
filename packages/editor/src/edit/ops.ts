/**
 * Node-granular edit operations. Contract: see ops.md.
 *
 * Pure transforms `(picture, ...args) -> TikzPicture` that return a new picture and
 * share untouched statements. They preserve the format invariants: locality (only
 * the target statement's serialization changes), stable identity (a node's `name`),
 * and round-trip (the result re-serializes and re-parses unchanged). Undo/redo is
 * not modeled here — callers keep history (the shell re-derives from source).
 *
 * E1: the foundation the canvas needs — move (absolute), create, delete. Relative
 * placement (E2), content (E3), arrows (E4), and options (E5) build on these.
 */
import type { NodeStatement, PathStatement, Point, TikzPicture } from '../model/tikz'
import type { NodeContent } from '../model/content'
import { isPlacementToken, placement, type Placement } from '../tikz/options'
import { serializeConnector, type ConnectorPath } from '../tikz/connector'
import { formatNumber } from '../text/scanner'

/** Find a node by its stable identity. */
export function findNode(picture: TikzPicture, name: string): NodeStatement | undefined {
  return picture.statements.find(
    (statement): statement is NodeStatement => statement.kind === 'node' && statement.name === name,
  )
}

/** A node/coordinate name not yet used in the picture: `<base>1`, `<base>2`, ... */
export function uniqueName(picture: TikzPicture, base = 'n'): string {
  const used = new Set(
    picture.statements.flatMap((statement) =>
      (statement.kind === 'node' || statement.kind === 'coordinate') && statement.name
        ? [statement.name]
        : [],
    ),
  )
  let i = 1
  while (used.has(`${base}${i}`)) i++
  return `${base}${i}`
}

/**
 * Position a node absolutely at `at`. This is the two-mode rule for a canvas drag:
 * setting an absolute position removes any relative-placement option, so the two
 * never conflict. A no-op (returns the same picture) if the node is not found.
 */
export function moveNodeTo(picture: TikzPicture, name: string, at: Point): TikzPicture {
  return mapNode(picture, name, (node) => ({
    ...node,
    at,
    options: node.options.filter((token) => !isPlacementToken(token)),
  }))
}

/**
 * Replace a node's body content (E3: inline content editing). A no-op if the node is
 * not found. Content is the parsed result of the edited raw body, so an out-of-subset
 * edit lands as `{ kind: 'error', source, message }` and is preserved verbatim on
 * serialize (ADR 0015); geometry and options are untouched.
 */
export function setNodeContent(
  picture: TikzPicture,
  name: string,
  content: NodeContent,
): TikzPicture {
  return mapNode(picture, name, (node) => ({ ...node, content }))
}

/**
 * Bind a node relatively: `[<side>=<gap> of <ref>]` (E2, the relative half of the
 * two-mode rule). Mirrors `moveNodeTo`'s inverse — it drops any absolute `at` and
 * replaces any existing placement token, so absolute and relative never coexist.
 * A no-op (same picture) if the node or `ref` is missing, if `ref` is the node
 * itself, or if the binding would form a placement cycle (the layout would pin a
 * cycle to the origin — refusing keeps the relative chain acyclic).
 */
export function placeNodeRelative(
  picture: TikzPicture,
  name: string,
  spec: Placement,
): TikzPicture {
  if (spec.ref === name) return picture
  if (findNode(picture, spec.ref) === undefined) return picture
  if (placementChainReaches(picture, spec.ref, name)) return picture
  const token = `${spec.side}=${formatNumber(spec.gap)} of ${spec.ref}`
  return mapNode(picture, name, (node) => ({
    ...node,
    at: undefined, // relative wins: strip the absolute position (serializer omits it)
    options: withPlacementToken(node.options, token),
  }))
}

/**
 * Adjust an existing relative placement's gap and/or side, keeping its `ref` (E2:
 * dragging a bound node along its axis changes the gap; across the axis flips the
 * side). A no-op if the node is not found or is not relatively placed.
 */
export function adjustPlacement(
  picture: TikzPicture,
  name: string,
  changes: { side?: Placement['side']; gap?: number },
): TikzPicture {
  const node = findNode(picture, name)
  if (node === undefined) return picture
  const current = placement(node)
  if (current === undefined) return picture
  return placeNodeRelative(picture, name, {
    side: changes.side ?? current.side,
    gap: changes.gap ?? current.gap,
    ref: current.ref,
  })
}

export interface NodeSpec {
  name?: string
  at?: Point
  options?: string[]
  content?: NodeContent
}

/**
 * Append a new node. Its name defaults to a fresh `uniqueName`; options default to
 * none and content to empty. Returns the new picture and the name assigned, so the
 * caller can select the freshly created node.
 */
export function createNode(
  picture: TikzPicture,
  spec: NodeSpec = {},
): { picture: TikzPicture; name: string } {
  const name = spec.name ?? uniqueName(picture)
  const node: NodeStatement = {
    kind: 'node',
    name,
    options: spec.options ?? [],
    ...(spec.at ? { at: spec.at } : {}),
    content: spec.content ?? { kind: 'empty' },
  }
  return { picture: { statements: [...picture.statements, node] }, name }
}

/**
 * Remove a node and prune any `\draw`/path whose verbatim body references it as an
 * endpoint `(name)`, so a deletion never leaves a dangling connector in the source.
 */
export function deleteNode(picture: TikzPicture, name: string): TikzPicture {
  const reference = new RegExp(`\\(\\s*${escapeRegExp(name)}\\s*[.)]`)
  return {
    statements: picture.statements.filter((statement) => {
      if (statement.kind === 'node' && statement.name === name) return false
      if (statement.kind === 'path' && reference.test(statement.body)) return false
      return true
    }),
  }
}

/**
 * Add a connector `\draw[opts] (from) -- (to);` between two nodes (E4). Endpoints are
 * node names, so the connector re-routes automatically as the nodes move (the renderer
 * resolves `(name)` to the current center each paint). No-op if either node is absent.
 * `options` default to a single forward arrowhead (`->`).
 */
export function createConnector(
  picture: TikzPicture,
  from: string,
  to: string,
  options: string[] = ['->'],
): TikzPicture {
  if (findNode(picture, from) === undefined || findNode(picture, to) === undefined) return picture
  const path: PathStatement = {
    kind: 'path',
    action: 'draw',
    options,
    body: ` (${from}) -- (${to})`,
  }
  return { statements: [...picture.statements, path] }
}

/**
 * Replace the path body of the connector at `index` (position among path statements)
 * with a reshaped `ConnectorPath` — endpoints, waypoints, and per-segment curves (E4+).
 * Options (arrowheads, dashing) are untouched. No-op if out of range or the statement
 * at that index is not a path.
 */
export function updateConnector(
  picture: TikzPicture,
  index: number,
  path: ConnectorPath,
): TikzPicture {
  let seen = -1
  return {
    statements: picture.statements.map((statement) => {
      if (statement.kind !== 'path') return statement
      seen++
      return seen === index ? { ...statement, body: serializeConnector(path) } : statement
    }),
  }
}

/**
 * Remove the connector at `index` — the position among the picture's **path**
 * statements (the identity the renderer stamps as `data-arrow`). No-op if out of range.
 */
export function deleteConnector(picture: TikzPicture, index: number): TikzPicture {
  let seen = -1
  return {
    statements: picture.statements.filter((statement) => {
      if (statement.kind !== 'path') return true
      seen++
      return seen !== index
    }),
  }
}

/** Replace the first placement token in place (or append), dropping any others. */
function withPlacementToken(options: string[], token: string): string[] {
  const idx = options.findIndex(isPlacementToken)
  const without = options.filter((t) => !isPlacementToken(t))
  if (idx === -1) return [...without, token]
  without.splice(Math.min(idx, without.length), 0, token)
  return without
}

/** Whether following placement refs from `from` reaches `target` (a would-be cycle). */
function placementChainReaches(picture: TikzPicture, from: string, target: string): boolean {
  const seen = new Set<string>()
  let current: string | undefined = from
  while (current !== undefined && !seen.has(current)) {
    if (current === target) return true
    seen.add(current)
    const node = findNode(picture, current)
    current = node ? placement(node)?.ref : undefined
  }
  return false
}

/** Rebuild the picture, replacing the named node via `fn`; other statements shared. */
function mapNode(
  picture: TikzPicture,
  name: string,
  fn: (node: NodeStatement) => NodeStatement,
): TikzPicture {
  return {
    statements: picture.statements.map((statement) =>
      statement.kind === 'node' && statement.name === name ? fn(statement) : statement,
    ),
  }
}

function escapeRegExp(source: string): string {
  return source.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
