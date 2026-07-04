/**
 * Serialize a TikzPicture to canonical source. Contract: see serialize.md.
 *
 * Canonical form: one statement per line, joined by '\n', every statement
 * terminated by ';'. Modeled statements regenerate canonically; verbatim spans are
 * emitted untouched (span-preserving splice). Deterministic — one model, one text.
 */
import type { NodeContent, NodeStatement, Statement, TikzPicture } from '../model/tikz'
import { formatNumber } from '../text/scanner'

export function serializePicture(picture: TikzPicture): string {
  return picture.statements.map((statement) => `${statementText(statement)};`).join('\n')
}

function statementText(statement: Statement): string {
  switch (statement.kind) {
    case 'node':
      return serializeNode(statement)
    case 'path':
      return `\\${statement.action}${options(statement.options)}${statement.body}`
    case 'coordinate':
      return `\\coordinate (${statement.name}) at (${point(statement.at)})`
    case 'verbatim':
      return statement.source
  }
}

function serializeNode(node: NodeStatement): string {
  let out = '\\node'
  out += options(node.options)
  if (node.name !== undefined) out += ` (${node.name})`
  if (node.at !== undefined) out += ` at (${point(node.at)})`
  out += ` ${body(node.content)}`
  return out
}

function body(content: NodeContent): string {
  return content.kind === 'empty' ? '{}' : `{${content.source}}`
}

function options(tokens: string[]): string {
  return tokens.length ? `[${tokens.join(', ')}]` : ''
}

function point(p: { x: number; y: number }): string {
  return `${formatNumber(p.x)},${formatNumber(p.y)}`
}
