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
  switch (content.kind) {
    case 'empty':
      return '{}'
    case 'error':
      return `{${content.source}}`
    case 'text':
      return `{${serializeRuns(content.runs)}}`
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
    case 'fragment':
      return `\\${run.name}`
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
      return `\\begin{${env}}${bodies.map((b) => `\\item ${b}`).join('')}\\end{${env}}`
    }
    case 'html': {
      const tag = run.ordered ? 'ol' : 'ul'
      return `<${tag}>${bodies.map((b) => `<li>${b}</li>`).join('')}</${tag}>`
    }
  }
}
