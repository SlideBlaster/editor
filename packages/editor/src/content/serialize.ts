/**
 * Serialize NodeContent back to its `{ … }` body token. Contract: see serialize.md.
 *
 * The inverse of `parseContent`: because runs are surface-faithful, each emits the
 * exact form it was parsed from, so canonical input round-trips byte-for-byte
 * (format invariant 2, extended to node content with dialect provenance). Returns
 * the full braced token so it drops straight into a node's body slot.
 */
import type { ListItem, NodeContent, TextRun } from '../model/content'

export function serializeContent(content: NodeContent): string {
  return `{${serializeBody(content)}}`
}

/**
 * The node body WITHOUT the surrounding braces — the exact inverse of `parseContent`
 * (which takes an un-braced body). This is the string a raw inline editor seeds from
 * and re-parses on commit, so `parseContent(serializeBody(c))` round-trips `c`. An
 * out-of-subset node returns its preserved source verbatim (ADR 0015).
 */
export function serializeBody(content: NodeContent): string {
  switch (content.kind) {
    case 'empty':
      return ''
    case 'error':
      return content.source
    case 'text':
      return serializeRuns(content.runs)
  }
}

/** Serialize a run list (no surrounding braces) — exposed for content-level tests. */
export function serializeRuns(runs: TextRun[]): string {
  return runs.map(serializeRun).join('')
}

function serializeRun(run: TextRun): string {
  switch (run.kind) {
    case 'text':
      return run.value
    case 'math':
      return run.display ? `$$${run.source}$$` : `$${run.source}$`
    case 'latex':
      return `\\${run.command}{${serializeRuns(run.children)}}`
    case 'markdown':
      return `${run.marker}${serializeRuns(run.children)}${run.marker}`
    case 'html':
      return `<${run.tag}>${serializeRuns(run.children)}</${run.tag}>`
    case 'list':
      return serializeList(run)
    case 'columns':
      return `\\begin{columns}${run.columns
        .map((col) => `\\column{${col.width}}${serializeRuns(col.children)}`)
        .join('')}\\end{columns}`
    case 'matrix':
      return `\\matrix${run.options ? `[${run.options}]` : ''}{${run.rows
        .map((row) => row.map((cell) => serializeRuns(cell.children)).join(' & '))
        .join(' \\\\ ')}}`
    case 'fragment':
      return run.dialect === 'html'
        ? `<${run.name}>`
        : `\\${run.name}${run.spec ? `<${run.spec.raw}>` : ''}`
    case 'overlay':
      return `\\${run.command}${run.spec ? `<${run.spec.raw}>` : ''}{${serializeRuns(run.children)}}`
    case 'image':
      return run.dialect === 'md' ? `![${run.alt}](${run.src})` : `\\image{${run.src}}`
    case 'include':
      return `\\cat{${run.path}}`
    case 'deferred':
      return run.source
    case 'cite':
      return `\\cite{${run.keys.join(', ')}}`
    case 'citefootnote':
      return `\\citefootnote{${run.keys.join(', ')}}`
    case 'printbibliography':
      return `\\printbibliography{}`
  }
}

/** Canonical, normalizing list output — markers become `-`, ordered lists renumber. */
function serializeList(run: {
  ordered: boolean
  dialect: 'md' | 'latex' | 'html'
  items: ListItem[]
}): string {
  const bodies = run.items.map((item) => serializeRuns(item.children))
  switch (run.dialect) {
    case 'md':
      return bodies.map((b, i) => (run.ordered ? `${i + 1}. ${b}` : `- ${b}`)).join('\n')
    case 'latex': {
      const env = run.ordered ? 'enumerate' : 'itemize'
      return `\\begin{${env}}${run.items
        .map(
          (item) =>
            `\\item${item.spec ? `<${item.spec.raw}>` : ''} ${serializeRuns(item.children)}`,
        )
        .join('')}\\end{${env}}`
    }
    case 'html': {
      const tag = run.ordered ? 'ol' : 'ul'
      return `<${tag}>${bodies.map((b) => `<li>${b}</li>`).join('')}</${tag}>`
    }
  }
}
