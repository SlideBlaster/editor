/**
 * Parse a node body string into NodeContent. Contract: see parse.md.
 *
 * A recursive-descent inline scanner applying the precedence of node-content.md at
 * every nesting level: math fences (opaque) -> HTML tags -> LaTeX macros -> markdown
 * emphasis, with everything else accumulated as literal text. Supported containers
 * recurse into their bodies (transparent nesting). Genuinely out-of-subset input
 * (denylisted macros, unsafe/unknown HTML) raises OutOfSubsetError and the whole
 * body is preserved as `error` (ADR 0015).
 */
import type { LatexCommand, MarkdownMarker, NodeContent, TextRun } from '../model/content'
import { readGroup } from '../text/scanner'

/** Raised when a construct is outside the supported subset; carries a message. */
export class OutOfSubsetError extends Error {}

/** LaTeX inline commands we model (A3a). Anything else with a `{}` arg is rejected. */
const LATEX_INLINE: Record<string, LatexCommand> = {
  textbf: 'textbf',
  emph: 'emph',
  textit: 'textit',
  underline: 'underline',
}

/** HTML tags we model (A3a): inline styles plus transparent structural wrappers. */
const HTML_TAGS = new Set(['b', 'strong', 'i', 'em', 'u', 's', 'div', 'span'])

const OPEN_TAG = /^<([a-zA-Z][a-zA-Z0-9]*)>/
const ANY_TAG = /^<\/?[a-zA-Z][^>]*>/
const LATEX_MACRO = /^\\([a-zA-Z]+)/

export function parseContent(body: string): NodeContent {
  if (body === '') return { kind: 'empty' }
  try {
    return { kind: 'text', runs: parseRuns(body) }
  } catch (error) {
    if (error instanceof OutOfSubsetError) {
      return { kind: 'error', source: body, message: error.message }
    }
    throw error
  }
}

function parseRuns(s: string): TextRun[] {
  const runs: TextRun[] = []
  let buf = ''
  let i = 0
  const flush = () => {
    if (buf) {
      runs.push({ kind: 'text', value: buf })
      buf = ''
    }
  }

  while (i < s.length) {
    const rest = s.slice(i)
    const c = rest[0]!

    if (c === '$') {
      const math = matchMath(rest)
      if (math) {
        flush()
        runs.push({ kind: 'math', display: math.display, source: math.source })
        i += math.length
        continue
      }
    } else if (c === '<') {
      const open = OPEN_TAG.exec(rest)
      if (open) {
        const tag = open[1]!
        if (!HTML_TAGS.has(tag.toLowerCase())) {
          throw new OutOfSubsetError(`unsupported HTML tag <${tag}>`)
        }
        const el = readElement(s, i + open[0].length, tag)
        flush()
        runs.push({ kind: 'html', tag, children: parseRuns(el.inner) })
        i = el.end
        continue
      }
      if (ANY_TAG.test(rest)) {
        throw new OutOfSubsetError(`unsupported HTML: ${ANY_TAG.exec(rest)![0]}`)
      }
    } else if (c === '\\') {
      const macro = LATEX_MACRO.exec(rest)
      if (macro) {
        const name = macro[1]!
        const command = LATEX_INLINE[name]
        if (command === undefined) {
          throw new OutOfSubsetError(`unsupported LaTeX macro \\${name}`)
        }
        if (s[i + macro[0].length] !== '{') {
          throw new OutOfSubsetError(`\\${name} without a { } argument`)
        }
        const group = readGroup(s, i + macro[0].length, '{', '}')
        flush()
        runs.push({ kind: 'latex', command, children: parseRuns(group.inner) })
        i = group.end
        continue
      }
    } else if (c === '*') {
      const marker: MarkdownMarker = rest.startsWith('**') ? '**' : '*'
      const close = findMarkdownClose(s, i + marker.length, marker)
      if (close !== -1) {
        flush()
        runs.push({
          kind: 'markdown',
          marker,
          children: parseRuns(s.slice(i + marker.length, close)),
        })
        i = close + marker.length
        continue
      }
    }

    buf += c
    i += 1
  }

  flush()
  return runs
}

/** Match a math fence at the START of `rest`; null if unterminated (treat `$` literal). */
function matchMath(rest: string): { source: string; display: boolean; length: number } | null {
  if (rest.startsWith('$$')) {
    const close = rest.indexOf('$$', 2)
    if (close === -1) return null
    return { source: rest.slice(2, close), display: true, length: close + 2 }
  }
  const close = indexOfUnescaped(rest, '$', 1)
  if (close === -1) return null
  return { source: rest.slice(1, close), display: false, length: close + 1 }
}

/** Index of the next `ch` at or after `from` not preceded by a backslash; -1 if none. */
function indexOfUnescaped(s: string, ch: string, from: number): number {
  for (let k = from; k < s.length; k++) {
    if (s[k] === ch && s[k - 1] !== '\\') return k
  }
  return -1
}

/** Read the body of `<tag>` opened just before `from`; returns inner text and end index. */
function readElement(s: string, from: number, tag: string): { inner: string; end: number } {
  const open = `<${tag}>`.toLowerCase()
  const close = `</${tag}>`.toLowerCase()
  let depth = 1
  let k = from
  while (k < s.length) {
    if (s[k] === '<') {
      const ahead = s.slice(k).toLowerCase()
      if (ahead.startsWith(close)) {
        depth -= 1
        if (depth === 0) return { inner: s.slice(from, k), end: k + close.length }
        k += close.length
        continue
      }
      if (ahead.startsWith(open)) {
        depth += 1
        k += open.length
        continue
      }
    }
    k += 1
  }
  throw new OutOfSubsetError(`unclosed <${tag}>`)
}

/** Index of the matching markdown `marker` at or after `from`; -1 if none. */
function findMarkdownClose(s: string, from: number, marker: MarkdownMarker): number {
  for (let k = from; k < s.length; k++) {
    if (marker === '**') {
      if (s[k] === '*' && s[k + 1] === '*') return k
    } else if (s[k] === '*' && s[k + 1] !== '*' && s[k - 1] !== '*') {
      return k
    }
  }
  return -1
}
