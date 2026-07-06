/**
 * Bibliography parsing + citation formatting. Contract: see citeRenderer.md.
 *
 * The pure, framework-free core of citations, ported from the slide-editor prototype
 * (`src/rendering/citeRenderer.ts`): parse a `.bib` into a keyed database
 * (`biblatex-csl-converter`), then format a set of keys into an inline marker, a full
 * reference, or a bibliography list, in one of three styles. Numbering is supplied by
 * the caller (`citeCompiler`), which walks the whole deck in order so numbers are
 * deck-stable — this module never owns document order.
 */
import { BibLatexParser } from 'biblatex-csl-converter'

export interface BibEntry {
  key: string
  type: string
  authors: string[]
  title: string
  year: string
  journal?: string
  booktitle?: string
  publisher?: string
  volume?: string
  pages?: string
}

export interface BibDatabase {
  entries: Map<string, BibEntry>
}

export type CitationStyle = 'numeric' | 'author-year' | 'author-year-short'

/** Deck-wide `\cite` numbering: key -> assigned number (1-based, by first citation). */
export type CitationCounter = Map<string, number>

const STYLES: ReadonlySet<string> = new Set<CitationStyle>([
  'numeric',
  'author-year',
  'author-year-short',
])

/** The `citationStyle:` frontmatter value, defaulting to `numeric`. */
export function parseCitationStyle(raw: string | undefined): CitationStyle {
  const v = raw?.trim()
  return v && STYLES.has(v) ? (v as CitationStyle) : 'numeric'
}

// ── Bib parsing ──────────────────────────────────────────────

/** Parse a `.bib` file string into a keyed BibDatabase. */
export function parseBibFile(bibContent: string): BibDatabase {
  const parser = new BibLatexParser(bibContent)
  const result = parser.parse()
  const entries = new Map<string, BibEntry>()

  for (const entryObj of Object.values(result.entries)) {
    const key = entryObj.entry_key
    const fields = entryObj.fields as Record<string, unknown>
    entries.set(key, {
      key,
      type: entryObj.bib_type,
      authors: extractAuthors(fields.author),
      title: extractTextField(fields.title),
      year: extractDate(fields.date) || extractTextField(fields.year),
      journal: extractTextField(fields.journaltitle),
      booktitle: extractTextField(fields.booktitle),
      publisher: extractTextField(fields.publisher),
      volume: extractTextField(fields.volume),
      pages: extractTextField(fields.pages),
    })
  }
  return { entries }
}

function extractTextField(value: unknown): string {
  if (!value) return ''
  if (typeof value === 'string') return value
  if (Array.isArray(value)) return nodeArrayToText(value)
  return ''
}

function nodeArrayToText(nodes: unknown[]): string {
  return nodes
    .map((n) => {
      const node = n as { type?: string; text?: string }
      return node.text ?? ''
    })
    .join('')
}

function extractAuthors(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.map((name) => {
    const n = name as { family?: unknown[]; given?: unknown[]; literal?: unknown[] }
    if (n.literal) return nodeArrayToText(n.literal)
    const family = n.family ? nodeArrayToText(n.family) : ''
    const given = n.given ? nodeArrayToText(n.given) : ''
    if (family && given) return `${family}, ${given}`
    return family || given || ''
  })
}

function extractDate(value: unknown): string {
  if (!value) return ''
  const text =
    typeof value === 'string' ? value : Array.isArray(value) ? nodeArrayToText(value) : ''
  const m = text.match(/(\d{4})/)
  return m ? m[1]! : text
}

// ── Citation formatting ──────────────────────────────────────

function authorSurname(entry: BibEntry): string {
  if (entry.authors.length === 0) return entry.key
  const first = entry.authors[0]!
  const comma = first.indexOf(',') // "Family, Given" -> "Family"
  return comma > 0 ? first.slice(0, comma) : first
}

/** A single key's marker text, assigning a numeric index on first use. */
function formatSingleCite(entry: BibEntry, style: CitationStyle, counter: CitationCounter): string {
  switch (style) {
    case 'numeric': {
      if (!counter.has(entry.key)) counter.set(entry.key, counter.size + 1)
      return String(counter.get(entry.key))
    }
    case 'author-year':
      return `${authorSurname(entry)}, ${entry.year || '?'}`
    case 'author-year-short':
      return `${authorSurname(entry)} ${entry.year || '?'}`
  }
}

/** Format an inline `\cite{k1, k2}` to marker HTML (`[1, 2]` or `(Surname, year)`). */
export function formatCite(
  keys: string[],
  db: BibDatabase,
  style: CitationStyle,
  counter: CitationCounter,
): string {
  const parts = keys.map((k) => {
    const entry = db.entries.get(k)
    if (!entry) return `<span class="sb-cite-missing">${escapeHtml(k)}?</span>`
    return formatSingleCite(entry, style, counter)
  })
  return style === 'numeric' ? `[${parts.join(', ')}]` : `(${parts.join('; ')})`
}

/** A full bibliographic reference (footnotes + bibliography). */
export function formatFullReference(entry: BibEntry): string {
  const parts: string[] = []
  if (entry.authors.length > 0) {
    parts.push(entry.authors.length <= 3 ? entry.authors.join(', ') : `${entry.authors[0]} et al.`)
  }
  if (entry.year) parts.push(`(${entry.year})`)
  if (entry.title) parts.push(`<em>${escapeHtml(entry.title)}</em>`)
  if (entry.journal) parts.push(escapeHtml(entry.journal))
  else if (entry.booktitle) parts.push(escapeHtml(entry.booktitle))
  const volPages: string[] = []
  if (entry.volume) volPages.push(escapeHtml(entry.volume))
  if (entry.pages) volPages.push(`pp. ${escapeHtml(entry.pages)}`)
  if (volPages.length > 0) parts.push(volPages.join(', '))
  if (entry.publisher) parts.push(escapeHtml(entry.publisher))
  return joinSentences(parts)
}

/** Join reference parts with `. `, but never double a period a part already ends with
 *  (e.g. an author "Knuth, Donald E." must not become "E.. (1984)"). */
function joinSentences(parts: string[]): string {
  let out = ''
  for (const part of parts) {
    if (!part) continue
    if (out === '') out = part
    else out += /[.!?]$/.test(out) ? ` ${part}` : `. ${part}`
  }
  return out === '' || /[.!?]$/.test(out) ? out : `${out}.`
}

/** The footnote reference text for a set of keys (the slide supplies the number). */
export function formatFootnoteText(keys: string[], db: BibDatabase): string {
  return keys
    .map((k) => {
      const entry = db.entries.get(k)
      return entry
        ? formatFullReference(entry)
        : `<span class="sb-cite-missing">[${escapeHtml(k)}?]</span>`
    })
    .join('; ')
}

/** `\printbibliography{}` — the references that were `\cite`d, in citation order. */
export function formatBibliography(
  db: BibDatabase,
  style: CitationStyle,
  counter: CitationCounter,
): string {
  if (counter.size === 0) return `<div class="sb-bib-empty">No citations.</div>`
  const sorted = [...counter.entries()].sort((a, b) => a[1] - b[1])
  const items = sorted.map(([key, num]) => {
    const entry = db.entries.get(key)
    const label = style === 'numeric' ? `[${num}]` : `${entry ? authorSurname(entry) : key}`
    const body = entry
      ? formatFullReference(entry)
      : `<span class="sb-cite-missing">${escapeHtml(key)}?</span>`
    return `<div class="sb-bib-entry">${label} ${body}</div>`
  })
  return items.join('')
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
