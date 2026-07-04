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
import type { NodeStatement, Point, TikzPicture } from '../model/tikz'
import type { NodeContent } from '../model/content'
import { isPlacementToken } from '../tikz/options'

/** Find a node by its stable identity. */
export function findNode(picture: TikzPicture, name: string): NodeStatement | undefined {
  return picture.statements.find(
    (statement): statement is NodeStatement =>
      statement.kind === 'node' && statement.name === name,
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
