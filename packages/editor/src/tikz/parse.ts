/**
 * Parse a slide-picture source string into a TikzPicture. Contract: see parse.md.
 *
 * Models T1 structure (nodes, coordinates, paths) and preserves everything else as
 * verbatim spans. Any statement that does not cleanly match a modeled shape falls
 * back to verbatim, so parsing never corrupts or drops source.
 */
import type {
  CoordinateStatement,
  NodeStatement,
  PathStatement,
  Statement,
  TikzPicture,
} from '../model/tikz'
import type { NodeContent } from '../model/content'
import { parseContent } from '../content/parse'
import {
  parsePoint,
  readGroup,
  skipWhitespace,
  splitOptions,
  splitStatements,
} from '../text/scanner'

export function parsePicture(source: string): TikzPicture {
  return { statements: splitStatements(source).map(parseStatement) }
}

const PATH_ACTION = /^\\(filldraw|draw|fill|path)\b/

function parseStatement(chunk: string): Statement {
  try {
    if (chunk.startsWith('\\node')) return parseNode(chunk)
    if (chunk.startsWith('\\coordinate')) return parseCoordinate(chunk)
    const path = PATH_ACTION.exec(chunk)
    if (path) return parsePath(chunk, path[1] as PathStatement['action'], path[0].length)
  } catch {
    // fall through to verbatim preservation
  }
  return { kind: 'verbatim', source: chunk }
}

function parseNode(chunk: string): NodeStatement {
  let i = '\\node'.length
  let options: string[] = []
  let name: string | undefined
  let at: NodeStatement['at']
  let content: NodeContent = { kind: 'empty' }
  let sawBody = false

  while (i < chunk.length) {
    i = skipWhitespace(chunk, i)
    if (i >= chunk.length) break
    const c = chunk[i]
    if (c === '[') {
      const group = readGroup(chunk, i, '[', ']')
      options = splitOptions(group.inner)
      i = group.end
    } else if (c === '(') {
      const group = readGroup(chunk, i, '(', ')')
      name = group.inner.trim()
      i = group.end
    } else if (isAtClause(chunk, i)) {
      i = skipWhitespace(chunk, i + 2)
      const group = readGroup(chunk, i, '(', ')')
      at = parsePoint(group.inner)
      i = group.end
    } else if (c === '{') {
      const group = readGroup(chunk, i, '{', '}')
      content = parseContent(group.inner)
      i = group.end
      sawBody = true
      break
    } else {
      throw new Error(`unparseable node token at ${i}: ${chunk}`)
    }
  }

  const rest = chunk.slice(i).trim()
  if (rest) throw new Error(`trailing content after node body: ${rest}`)
  void sawBody

  const node: NodeStatement = { kind: 'node', options, content }
  if (name !== undefined) node.name = name
  if (at !== undefined) node.at = at
  return node
}

function parsePath(
  chunk: string,
  action: PathStatement['action'],
  actionLength: number,
): PathStatement {
  let i = actionLength
  let options: string[] = []
  if (chunk[i] === '[') {
    const group = readGroup(chunk, i, '[', ']')
    options = splitOptions(group.inner)
    i = group.end
  }
  return { kind: 'path', action, options, body: chunk.slice(i) }
}

function parseCoordinate(chunk: string): CoordinateStatement {
  let i = skipWhitespace(chunk, '\\coordinate'.length)
  if (chunk[i] !== '(') throw new Error(`coordinate missing name: ${chunk}`)
  const nameGroup = readGroup(chunk, i, '(', ')')
  const name = nameGroup.inner.trim()
  i = skipWhitespace(chunk, nameGroup.end)
  if (!isAtClause(chunk, i)) throw new Error(`coordinate missing 'at': ${chunk}`)
  i = skipWhitespace(chunk, i + 2)
  const pointGroup = readGroup(chunk, i, '(', ')')
  const at = parsePoint(pointGroup.inner)
  if (chunk.slice(pointGroup.end).trim())
    throw new Error(`trailing content in coordinate: ${chunk}`)
  return { kind: 'coordinate', name, at }
}

/** True when `at` at index `i` is the standalone positioning keyword. */
function isAtClause(chunk: string, i: number): boolean {
  if (chunk[i] !== 'a' || chunk[i + 1] !== 't') return false
  const after = chunk[i + 2]
  return after === undefined ? false : /\s/.test(after) || after === '('
}
