/**
 * Depth-aware scanning primitives for TikZ source. Contract: see scanner.md.
 *
 * The governing rule: braces `{}` are primary (they delimit node bodies, which
 * contain arbitrary markdown/LaTeX/HTML). Brackets `[]` and parens `()` only nest
 * at brace-depth 0 (option lists, coordinates) — inside a `{}` body they are
 * literal text and never affect depth.
 */

/** Canonical number formatting: integers as-is, decimals without trailing zeros. */
export function formatNumber(n: number): string {
  return String(n)
}

/**
 * Split a picture body into statement chunks at top-level `;`. Returns trimmed
 * chunks with the terminating `;` removed; empty chunks are dropped. Inter-statement
 * whitespace is discarded (the serializer re-imposes canonical single-newline
 * separation).
 */
export function splitStatements(source: string): string[] {
  const chunks: string[] = []
  let brace = 0
  let bracket = 0
  let paren = 0
  let start = 0

  for (let i = 0; i < source.length; i++) {
    const c = source[i]
    if (brace > 0) {
      if (c === '{') brace++
      else if (c === '}') brace--
      continue
    }
    // brace === 0
    if (c === '{') brace++
    else if (c === '[') bracket++
    else if (c === ']') bracket = Math.max(0, bracket - 1)
    else if (c === '(') paren++
    else if (c === ')') paren = Math.max(0, paren - 1)
    else if (c === ';' && bracket === 0 && paren === 0) {
      const chunk = source.slice(start, i).trim()
      if (chunk) chunks.push(chunk)
      start = i + 1
    }
  }
  const tail = source.slice(start).trim()
  if (tail) chunks.push(tail)
  return chunks
}

/**
 * Split option-list inner text on top-level commas, respecting `{}`, `[]`, `()`
 * nesting. Trims tokens and drops empties.
 */
export function splitOptions(inner: string): string[] {
  const tokens: string[] = []
  let brace = 0
  let bracket = 0
  let paren = 0
  let buf = ''

  for (const c of inner) {
    if (c === '{') brace++
    else if (c === '}') brace = Math.max(0, brace - 1)
    else if (c === '[') bracket++
    else if (c === ']') bracket = Math.max(0, bracket - 1)
    else if (c === '(') paren++
    else if (c === ')') paren = Math.max(0, paren - 1)

    if (c === ',' && brace === 0 && bracket === 0 && paren === 0) {
      const token = buf.trim()
      if (token) tokens.push(token)
      buf = ''
      continue
    }
    buf += c
  }
  const last = buf.trim()
  if (last) tokens.push(last)
  return tokens
}

export interface Group {
  /** Text between the delimiters, exclusive. */
  inner: string
  /** Index just past the closing delimiter. */
  end: number
}

/**
 * Read a delimited group starting at `source[start]` (which must equal `open`).
 * For `{}` groups, only braces nest. For `[]`/`()` groups, the matching delimiter is
 * counted only at brace-depth 0, so a `]` or `)` inside an embedded `{}` label is
 * treated as literal. Throws on an unterminated group.
 */
export function readGroup(source: string, start: number, open: string, close: string): Group {
  if (source[start] !== open) {
    throw new Error(`expected '${open}' at ${start} in: ${source}`)
  }
  let depth = 0
  let brace = 0
  for (let i = start; i < source.length; i++) {
    const c = source[i]
    if (open === '{') {
      if (c === '{') depth++
      else if (c === '}') {
        depth--
        if (depth === 0) return { inner: source.slice(start + 1, i), end: i + 1 }
      }
      continue
    }
    if (c === '{') brace++
    else if (c === '}') brace = Math.max(0, brace - 1)
    else if (brace === 0) {
      if (c === open) depth++
      else if (c === close) {
        depth--
        if (depth === 0) return { inner: source.slice(start + 1, i), end: i + 1 }
      }
    }
  }
  throw new Error(`unterminated '${open}${close}' group in: ${source}`)
}

/** Parse a coordinate pair `x,y` (already stripped of its parentheses). */
export function parsePoint(inner: string): { x: number; y: number } {
  const parts = splitOptions(inner)
  if (parts.length !== 2) throw new Error(`expected 'x,y', got: ${inner}`)
  const x = Number(parts[0])
  const y = Number(parts[1])
  if (Number.isNaN(x) || Number.isNaN(y)) throw new Error(`non-numeric coordinate: ${inner}`)
  return { x, y }
}

/** Skip ASCII whitespace from `i`; return the first non-whitespace index. */
export function skipWhitespace(source: string, i: number): number {
  while (i < source.length && /\s/.test(source[i]!)) i++
  return i
}
