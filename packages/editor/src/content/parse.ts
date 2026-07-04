/**
 * Parse a node body string into NodeContent. Contract: see parse.md.
 *
 * A recursive-descent scanner applying the precedence of node-content.md at every
 * nesting level, recursing into each container's body (transparent nesting): lists
 * (md line-based, LaTeX itemize/enumerate, HTML ul/ol) -> math (opaque) -> HTML tags
 * -> LaTeX macros / fragments -> markdown emphasis, with everything else literal
 * text. Genuinely out-of-subset input (denylisted macros, unsafe/unknown HTML)
 * raises OutOfSubsetError and the whole body is preserved as `error` (ADR 0015).
 */
import type {
  FragmentName,
  LatexCommand,
  ListItem,
  MarkdownMarker,
  NodeContent,
  TextRun,
} from '../model/content'
import { readGroup, skipWhitespace } from '../text/scanner'

/** Raised when a construct is outside the supported subset; carries a message. */
export class OutOfSubsetError extends Error {}

/** LaTeX inline commands we model. Anything else with a `{}` arg is rejected. */
const LATEX_INLINE: Record<string, LatexCommand> = {
  textbf: 'textbf',
  emph: 'emph',
  textit: 'textit',
  underline: 'underline',
}

/** HTML tags we model: inline styles plus transparent structural wrappers. */
const HTML_TAGS = new Set(['b', 'strong', 'i', 'em', 'u', 's', 'div', 'span'])

const OPEN_TAG = /^<([a-zA-Z][a-zA-Z0-9]*)>/
const ANY_TAG = /^<\/?[a-zA-Z][^>]*>/
const LATEX_MACRO = /^\\([a-zA-Z]+)/
const LIST_ITEM_LINE = /^([ \t]*)([-+*]|\d+\.)[ \t]+/
const LATEX_LIST_BEGIN = /^\\begin\{(itemize|enumerate)\}/
const LATEX_LIST_END = /^\\end\{(itemize|enumerate)\}/
const HTML_LIST_OPEN = /^<(ul|ol)>/i
const HTML_FRAGMENT = /^<appear>/i
const FRAGMENT = /^\\(appear|pause|only)(?:\[=(\d+)\])?/
const COLUMNS_BEGIN = /^\\begin\{columns\}/
const TABULAR_BEGIN = /^\\begin\{tabular\}/
const MATRIX = /^\\matrix\b/
const IMAGE_LATEX = /^\\image\{/
const CAT = /^\\cat\{/
const MD_IMAGE = /^!\[([^\]]*)\]\(([^)]*)\)/

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
  const emit = (run: TextRun, end: number) => {
    flush()
    runs.push(run)
    i = end
  }

  while (i < s.length) {
    const rest = s.slice(i)
    const c = rest[0]!

    if ((i === 0 || s[i - 1] === '\n') && LIST_ITEM_LINE.test(rest)) {
      const list = parseMarkdownList(s, i)
      emit(list.run, list.end)
      continue
    }

    if (c === '$') {
      const math = matchMath(rest)
      if (math) {
        emit({ kind: 'math', display: math.display, source: math.source }, i + math.length)
        continue
      }
    } else if (c === '<') {
      if (HTML_FRAGMENT.test(rest)) {
        emit(
          { kind: 'fragment', name: 'appear', dialect: 'html' },
          i + HTML_FRAGMENT.exec(rest)![0].length,
        )
        continue
      }
      if (HTML_LIST_OPEN.test(rest)) {
        const list = parseHtmlList(s, i)
        emit(list.run, list.end)
        continue
      }
      const open = OPEN_TAG.exec(rest)
      if (open) {
        const tag = open[1]!
        if (!HTML_TAGS.has(tag.toLowerCase())) {
          throw new OutOfSubsetError(`unsupported HTML tag <${tag}>`)
        }
        const el = readElement(s, i + open[0].length, tag)
        emit({ kind: 'html', tag, children: parseRuns(el.inner) }, el.end)
        continue
      }
      if (ANY_TAG.test(rest)) {
        throw new OutOfSubsetError(`unsupported HTML: ${ANY_TAG.exec(rest)![0]}`)
      }
    } else if (c === '\\') {
      if (LATEX_LIST_BEGIN.test(rest)) {
        const list = parseLatexList(s, i)
        emit(list.run, list.end)
        continue
      }
      if (COLUMNS_BEGIN.test(rest)) {
        const cols = parseColumns(s, i)
        emit(cols.run, cols.end)
        continue
      }
      if (MATRIX.test(rest)) {
        const mx = parseMatrix(s, i)
        emit(mx.run, mx.end)
        continue
      }
      if (TABULAR_BEGIN.test(rest)) {
        const env = captureLatexEnv(s, i, 'tabular')
        emit({ kind: 'deferred', feature: 'table', source: env.source }, env.end)
        continue
      }
      if (IMAGE_LATEX.test(rest)) {
        const g = readGroup(s, i + '\\image'.length, '{', '}')
        emit({ kind: 'image', src: g.inner, alt: '', dialect: 'latex' }, g.end)
        continue
      }
      if (CAT.test(rest)) {
        const g = readGroup(s, i + '\\cat'.length, '{', '}')
        emit({ kind: 'include', path: g.inner }, g.end)
        continue
      }
      const fragment = FRAGMENT.exec(rest)
      if (fragment) {
        const at = fragment[2] !== undefined ? Number(fragment[2]) : undefined
        emit(
          {
            kind: 'fragment',
            name: fragment[1] as FragmentName,
            dialect: 'latex',
            ...(at !== undefined ? { at } : {}),
          },
          i + fragment[0].length,
        )
        continue
      }
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
        emit({ kind: 'latex', command, children: parseRuns(group.inner) }, group.end)
        continue
      }
    } else if (c === '*') {
      const marker: MarkdownMarker = rest.startsWith('**') ? '**' : '*'
      const close = findMarkdownClose(s, i + marker.length, marker)
      if (close !== -1) {
        emit(
          { kind: 'markdown', marker, children: parseRuns(s.slice(i + marker.length, close)) },
          close + marker.length,
        )
        continue
      }
    } else if (c === '!') {
      const m = MD_IMAGE.exec(rest)
      if (m) {
        emit({ kind: 'image', src: m[2]!, alt: m[1]!, dialect: 'md' }, i + m[0].length)
        continue
      }
    }

    buf += c
    i += 1
  }

  flush()
  return runs
}

/** Consecutive `- `/`* `/`N. ` lines from `start`; ends before the last item's newline. */
function parseMarkdownList(s: string, start: number): { run: TextRun; end: number } {
  const items: ListItem[] = []
  let ordered: boolean | null = null
  let pos = start
  let end = start
  while (pos < s.length) {
    const m = LIST_ITEM_LINE.exec(s.slice(pos))
    if (!m) break
    const thisOrdered = /^\d+\./.test(m[2]!)
    if (ordered === null) ordered = thisOrdered
    else if (ordered !== thisOrdered) break
    const contentStart = pos + m[0].length
    const nl = s.indexOf('\n', contentStart)
    const lineEnd = nl === -1 ? s.length : nl
    items.push({ children: parseRuns(s.slice(contentStart, lineEnd)) })
    end = lineEnd
    if (nl === -1) break
    pos = nl + 1
  }
  return { run: { kind: 'list', ordered: ordered ?? false, dialect: 'md', items }, end }
}

/** `\begin{itemize|enumerate}` … `\item` … `\end{…}`; nested list envs recurse. */
function parseLatexList(s: string, start: number): { run: TextRun; end: number } {
  const m = LATEX_LIST_BEGIN.exec(s.slice(start))!
  const ordered = m[1] === 'enumerate'
  const bodyStart = start + m[0].length
  const close = findLatexListEnd(s, bodyStart)
  const items = splitLatexItems(s.slice(bodyStart, close.start)).map((c) => ({
    children: parseRuns(c),
  }))
  return { run: { kind: 'list', ordered, dialect: 'latex', items }, end: close.end }
}

/** Index of the balancing `\end{itemize|enumerate}` for a list opened at `from`. */
function findLatexListEnd(s: string, from: number): { start: number; end: number } {
  let depth = 0
  let i = from
  while (i < s.length) {
    const rest = s.slice(i)
    if (LATEX_LIST_BEGIN.test(rest)) {
      depth += 1
      i += LATEX_LIST_BEGIN.exec(rest)![0].length
      continue
    }
    const endM = LATEX_LIST_END.exec(rest)
    if (endM) {
      if (depth === 0) return { start: i, end: i + endM[0].length }
      depth -= 1
      i += endM[0].length
      continue
    }
    i += 1
  }
  throw new OutOfSubsetError('unclosed \\begin{itemize|enumerate}')
}

/** Split a list-env body into item contents at top-level `\item` (trimmed). */
function splitLatexItems(inner: string): string[] {
  const items: string[] = []
  let brace = 0
  let envDepth = 0
  let start = -1
  let i = 0
  while (i < inner.length) {
    const ch = inner[i]!
    if (ch === '{') {
      brace += 1
      i += 1
      continue
    }
    if (ch === '}') {
      brace = Math.max(0, brace - 1)
      i += 1
      continue
    }
    if (brace === 0) {
      const rest = inner.slice(i)
      const begin = LATEX_LIST_BEGIN.exec(rest)
      if (begin) {
        envDepth += 1
        i += begin[0].length
        continue
      }
      const end = LATEX_LIST_END.exec(rest)
      if (end) {
        envDepth = Math.max(0, envDepth - 1)
        i += end[0].length
        continue
      }
      if (envDepth === 0 && /^\\item\b/.test(rest)) {
        if (start !== -1) items.push(inner.slice(start, i))
        i += '\\item'.length
        start = i
        continue
      }
    }
    i += 1
  }
  if (start !== -1) items.push(inner.slice(start))
  return items.map((c) => c.trim())
}

/** `<ul>`/`<ol>` containing `<li>` items; nested lists recurse. */
function parseHtmlList(s: string, start: number): { run: TextRun; end: number } {
  const m = HTML_LIST_OPEN.exec(s.slice(start))!
  const tag = m[1]!.toLowerCase()
  const el = readElement(s, start + m[0].length, tag)
  const items = splitHtmlItems(el.inner).map((c) => ({ children: parseRuns(c) }))
  return { run: { kind: 'list', ordered: tag === 'ol', dialect: 'html', items }, end: el.end }
}

/** Collect `<li>…</li>` inners from a `<ul>/<ol>` body (whitespace between ignored). */
function splitHtmlItems(inner: string): string[] {
  const items: string[] = []
  let i = 0
  while (i < inner.length) {
    if (/^<li>/i.test(inner.slice(i))) {
      const el = readElement(inner, i + 4, 'li')
      items.push(el.inner)
      i = el.end
    } else {
      i += 1
    }
  }
  return items
}

/** `\begin{columns}\column{w}…\column{w}…\end{columns}` -> a structured group run. */
function parseColumns(s: string, start: number): { run: TextRun; end: number } {
  const env = captureLatexEnv(s, start, 'columns')
  const inner = env.source.slice(
    '\\begin{columns}'.length,
    env.source.length - '\\end{columns}'.length,
  )
  return { run: { kind: 'columns', columns: splitColumns(inner) }, end: env.end }
}

/** Split a columns body at top-level `\column{width}` markers (content trimmed). */
function splitColumns(inner: string): { width: string; children: TextRun[] }[] {
  const columns: { width: string; children: TextRun[] }[] = []
  let brace = 0
  let i = 0
  let width: string | null = null
  let contentStart = 0
  while (i < inner.length) {
    const ch = inner[i]!
    if (ch === '{') {
      brace += 1
      i += 1
      continue
    }
    if (ch === '}') {
      brace = Math.max(0, brace - 1)
      i += 1
      continue
    }
    if (brace === 0 && /^\\column\{/.test(inner.slice(i))) {
      if (width !== null) {
        columns.push({ width, children: parseRuns(inner.slice(contentStart, i).trim()) })
      }
      const g = readGroup(inner, i + '\\column'.length, '{', '}')
      width = g.inner
      contentStart = g.end
      i = g.end
      continue
    }
    i += 1
  }
  if (width !== null) columns.push({ width, children: parseRuns(inner.slice(contentStart).trim()) })
  return columns
}

/** `\matrix[options]{ a & b \\ c & d }` -> rows of cells (each cell content recurses). */
function parseMatrix(s: string, start: number): { run: TextRun; end: number } {
  let i = skipWhitespace(s, start + '\\matrix'.length)
  let options = ''
  if (s[i] === '[') {
    const g = readGroup(s, i, '[', ']')
    options = g.inner
    i = skipWhitespace(s, g.end)
  }
  if (s[i] !== '{') throw new OutOfSubsetError('\\matrix without a { } body')
  const g = readGroup(s, i, '{', '}')
  const rows = splitTopLevel(g.inner, '\\\\').map((row) =>
    splitTopLevel(row, '&').map((cell) => ({ children: parseRuns(cell.trim()) })),
  )
  return { run: { kind: 'matrix', options, rows }, end: g.end }
}

/** Split `body` on a top-level (brace-depth 0) separator (`&` or `\\`). */
function splitTopLevel(body: string, sep: '&' | '\\\\'): string[] {
  const parts: string[] = []
  let brace = 0
  let start = 0
  let i = 0
  while (i < body.length) {
    const ch = body[i]!
    if (ch === '{') {
      brace += 1
      i += 1
      continue
    }
    if (ch === '}') {
      brace = Math.max(0, brace - 1)
      i += 1
      continue
    }
    if (brace === 0 && body.startsWith(sep, i)) {
      parts.push(body.slice(start, i))
      i += sep.length
      start = i
      continue
    }
    i += 1
  }
  parts.push(body.slice(start))
  return parts
}

/** Capture a whole `\begin{env}…\end{env}` (nesting-aware) as verbatim source. */
function captureLatexEnv(s: string, start: number, env: string): { source: string; end: number } {
  const beginTok = `\\begin{${env}}`
  const endTok = `\\end{${env}}`
  let depth = 0
  let i = start
  while (i < s.length) {
    if (s.startsWith(beginTok, i)) {
      depth += 1
      i += beginTok.length
      continue
    }
    if (s.startsWith(endTok, i)) {
      depth -= 1
      if (depth === 0) return { source: s.slice(start, i + endTok.length), end: i + endTok.length }
      i += endTok.length
      continue
    }
    i += 1
  }
  throw new OutOfSubsetError(`unclosed \\begin{${env}}`)
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
