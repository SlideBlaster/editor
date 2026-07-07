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
import { isPlacementToken, isStyleKnobToken, placement, type Placement } from '../tikz/options'
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

const TEXT_WIDTH_RE = /^text\s+width\s*=/
const MIN_HEIGHT_RE = /^minimum\s+height\s*=/
const OVERLAY_RE = /^overlay\s*=/
const SCALE_RE = /^scale\s*=/
const XSCALE_RE = /^xscale\s*=/
const YSCALE_RE = /^yscale\s*=/

/**
 * Resize a node by setting (or clearing) its size option tokens. Two independent levers:
 *  - `scaleX` / `scaleY`: the content scale (drag-resize) — the rendered content (text,
 *    tables, images) grows with the box. Written as a single `scale=<k>` when the axes are
 *    equal, else `xscale`/`yscale`; `1` on both axes clears them (natural size).
 *  - `textWidth` / `minHeight`: the natural box before scaling — `text width=<n>` wraps the
 *    text; `minimum height=<n>` floors the height. A number sets, `null` clears.
 * Any key left `undefined` is untouched. A no-op if the node is not found. Position (`at` /
 * placement) is untouched — the caller updates `at` when a resize should keep the opposite
 * edge anchored (only meaningful for absolutely-positioned nodes).
 */
export function resizeNode(
  picture: TikzPicture,
  name: string,
  patch: {
    textWidth?: number | null
    minHeight?: number | null
    scaleX?: number | null
    scaleY?: number | null
  },
): TikzPicture {
  return mapNode(picture, name, (node) => {
    let options = node.options
    if (patch.textWidth !== undefined) {
      options = withSizeToken(
        options,
        TEXT_WIDTH_RE,
        patch.textWidth === null ? null : `text width=${formatNumber(patch.textWidth)}`,
      )
    }
    if (patch.minHeight !== undefined) {
      options = withSizeToken(
        options,
        MIN_HEIGHT_RE,
        patch.minHeight === null ? null : `minimum height=${formatNumber(patch.minHeight)}`,
      )
    }
    if (patch.scaleX !== undefined || patch.scaleY !== undefined) {
      options = withScaleTokens(options, patch.scaleX ?? 1, patch.scaleY ?? 1)
    }
    return { ...node, options }
  })
}

/** Rewrite a node's scale tokens: drop `scale`/`xscale`/`yscale`, then re-add the minimal
 *  form — nothing at 1×1, `scale=<k>` when the axes match, else `xscale`/`yscale`. */
function withScaleTokens(options: string[], sx: number, sy: number): string[] {
  const without = options.filter(
    (t) => !SCALE_RE.test(t) && !XSCALE_RE.test(t) && !YSCALE_RE.test(t),
  )
  const eq = (a: number, b: number): boolean => Math.abs(a - b) < 1e-6
  if (eq(sx, 1) && eq(sy, 1)) return without
  if (eq(sx, sy)) return [...without, `scale=${formatNumber(sx)}`]
  return [...without, `xscale=${formatNumber(sx)}`, `yscale=${formatNumber(sy)}`]
}

/**
 * Set (or clear, when `spec` is null/blank) a node's `overlay=<spec>` reveal option — the
 * whole-node half of the two-level overlay model (ADR 0018). The raw spec is stored
 * brace-wrapped (`overlay={1,3}`) so its commas survive tikz option tokenizing. Placement,
 * size, and content are untouched. A no-op if the node is not found.
 */
export function setNodeOverlay(
  picture: TikzPicture,
  name: string,
  spec: string | null,
): TikzPicture {
  const raw = spec?.trim() ?? ''
  return mapNode(picture, name, (node) => ({
    ...node,
    options: withSizeToken(node.options, OVERLAY_RE, raw === '' ? null : `overlay={${raw}}`),
  }))
}

/**
 * Set (or clear, when `styleClass` is null) a node's style class — the bare option
 * token that binds it to a theme role (`title`, `body`, `note`, …). Drops every
 * existing bare ROLE token and prepends the new one, so a node carries at most the
 * class the user picked; key=value options, placements, arrow shorthands, and bare
 * style KNOBS (`draw`, `ellipse`, `thick`, `dashed`, … — `isStyleKnobToken`) are
 * untouched, so restyling a shape keeps its outline/fill. A no-op if the node is not found.
 */
export function setNodeStyleClass(
  picture: TikzPicture,
  name: string,
  styleClass: string | null,
): TikzPicture {
  return mapNode(picture, name, (node) => {
    const kept = node.options.filter((token) => !isRoleClassToken(token))
    return { ...node, options: styleClass === null ? kept : [styleClass, ...kept] }
  })
}

/** A bare token that names a theme ROLE: a style-class token that is not a style knob. */
function isRoleClassToken(token: string): boolean {
  return isStyleClassToken(token) && !isStyleKnobToken(token)
}

/** Bare (non `key=value`, non arrow-shorthand) tokens name style classes — the same
 *  predicate `styleClasses` (tikz/options) reads with. */
function isStyleClassToken(token: string): boolean {
  return !token.includes('=') && !/^[<|>.-]+$/.test(token)
}

/**
 * Replace a node's whole `options` array (E5: style editing) — the node counterpart to
 * `setConnectorOptions`. The style panel reads the node's current tokens, rewrites the one
 * knob it changed with the pure `nodeStyle` helpers (preserving role classes, placement,
 * and size), and commits the result here. A no-op if the node is not found; geometry,
 * content, and identity (`name`) are untouched.
 */
export function setNodeOptions(picture: TikzPicture, name: string, options: string[]): TikzPicture {
  return mapNode(picture, name, (node) => ({ ...node, options }))
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

/** The option tokens of the connector at `index` (position among path statements), or
 *  `undefined` if out of range — the properties panel reads arrowheads/dashing from here. */
export function connectorOptions(picture: TikzPicture, index: number): string[] | undefined {
  let seen = -1
  for (const statement of picture.statements) {
    if (statement.kind !== 'path') continue
    seen++
    if (seen === index) return statement.options
  }
  return undefined
}

/** Replace the option tokens of the connector at `index` (arrowheads, dashing, …), keeping
 *  its path body. No-op if out of range or not a path. */
export function setConnectorOptions(
  picture: TikzPicture,
  index: number,
  options: string[],
): TikzPicture {
  let seen = -1
  return {
    statements: picture.statements.map((statement) => {
      if (statement.kind !== 'path') return statement
      seen++
      return seen === index ? { ...statement, options } : statement
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

/** Replace the first option token matching `re` in place (or append when none matched),
 *  or drop it entirely when `token` is null. Mirrors `withPlacementToken`. */
function withSizeToken(options: string[], re: RegExp, token: string | null): string[] {
  const idx = options.findIndex((t) => re.test(t))
  const without = options.filter((t) => !re.test(t))
  if (token === null) return without
  if (idx === -1) return [...without, token]
  without.splice(Math.min(idx, without.length), 0, token)
  return without
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
