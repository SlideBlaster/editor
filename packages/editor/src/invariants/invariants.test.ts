import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import fc from 'fast-check'
import type { SlideDocument } from '../model/document'
import type { NodeStatement } from '../model/tikz'
import { parseContent } from '../content/parse'
import { fromMarkdown } from '../markdown/fromMarkdown'
import { toMarkdown } from '../markdown/toMarkdown'
import { modelRoundTrips, textIsCanonical, identityPreserved, nodeNames } from './invariants'

const here = dirname(fileURLToPath(import.meta.url))
const fixture = readFileSync(join(here, 'fixtures', 'intro.slideBlaster.md'), 'utf8')

describe('golden fixture (normative worked example)', () => {
  it('is canonical — invariant 2', () => {
    expect(textIsCanonical(fixture)).toBe(true)
  })

  it('parses to the expected structure', () => {
    const doc = fromMarkdown(fixture)
    expect(doc.meta.entries).toEqual([{ key: 'title', value: 'Intro' }])
    expect(doc.frames).toHaveLength(1)
    expect(doc.frames[0]!.id).toBe('s1')
    expect(doc.frames[0]!.title).toBe('Intro')
    expect(nodeNames(doc)).toEqual(['title', 'intro', 'o2'])
  })
})

// A conservative generator of documents whose canonical form round-trips. Every
// arbitrary is drawn from safe pools (balanced braces, no leading/trailing spaces,
// no top-level separators) so generation exercises structure, not lexer edge cases.
const coord = fc.record({
  x: fc.constantFrom(0, 1, 2, 3, 4.5, 8, 9, 10, 12, 16),
  y: fc.constantFrom(0, 1, 2, 3, 4.5, 8, 9),
})

// Canonical node bodies drawn through the real parser, so every generated content
// value is in the parser's image (round-trips by construction).
const NODE_CONTENTS = [
  '',
  'plain text',
  'hello world',
  '$x^2$',
  '\n- one\n- two\n',
  'a b',
  '**bold**',
  '\\emph{y}',
  '<i>z</i>',
  '\\image{fig.png}',
  '\\begin{columns}\\column{0.5}a\\column{0.5}b\\end{columns}',
].map(parseContent)

const nodeStmt = fc.record({
  kind: fc.constant('node' as const),
  name: fc.option(fc.constantFrom('a', 'b', 'c', 'title', 'intro', 'note', 'box'), {
    nil: undefined,
  }),
  options: fc.array(
    fc.constantFrom('title', 'body', 'note', 'draw', 'fill=red', 'text width=12', 'below=1 of a'),
    { maxLength: 3 },
  ),
  at: fc.option(coord, { nil: undefined }),
  content: fc.constantFrom(...NODE_CONTENTS),
})

const pathStmt = fc.record({
  kind: fc.constant('path' as const),
  action: fc.constantFrom('draw' as const, 'path' as const, 'fill' as const, 'filldraw' as const),
  options: fc.array(fc.constantFrom('->', '<->', 'thick', 'red'), { maxLength: 2 }),
  body: fc.constantFrom(' (a) -- (b)', ' (a) -> (b)', ' (x) -| (y)'),
})

const coordStmt = fc.record({
  kind: fc.constant('coordinate' as const),
  name: fc.constantFrom('a', 'b', 'c', 'p', 'q'),
  at: coord,
})

const verbatimStmt = fc.record({
  kind: fc.constant('verbatim' as const),
  source: fc.constantFrom(
    '% a comment',
    '\\tikzset{every node/.style={draw}}',
    '\\useasboundingbox (0,0) rectangle (16,9)',
  ),
})

const statement = fc.oneof(nodeStmt, pathStmt, coordStmt, verbatimStmt)

const picture = fc.record({ statements: fc.array(statement, { maxLength: 5 }) })

// A frame optionally carries a notes sidecar picture (ADR 0019). Generating it here
// puts round-trip law 6 (notes round-trip, absent notes emit no block) under the same
// property checks as the slide picture.
const frame = fc.record({
  id: fc.constantFrom('s1', 's2', 'a', 'b', 'intro'),
  title: fc.constantFrom('Intro', 'My Slide', 'Section 1', 'Overview'),
  picture,
  notes: fc.option(fc.record({ statements: fc.array(statement, { maxLength: 3 }) }), {
    nil: undefined,
  }),
})

const document = fc.record({
  meta: fc.record({
    entries: fc.array(
      fc.record({
        key: fc.constantFrom('title', 'theme', 'author', 'date'),
        value: fc.constantFrom('Intro', 'dark', 'Ada', '2024'),
      }),
      { maxLength: 3 },
    ),
  }),
  frames: fc.array(frame, { minLength: 1, maxLength: 3 }),
}) as fc.Arbitrary<SlideDocument>

describe('property: invariants over generated documents', () => {
  it('every model round-trips — invariant 1', () => {
    fc.assert(fc.property(document, (doc) => modelRoundTrips(doc)))
  })

  it('every model preserves node identity — invariant 4', () => {
    fc.assert(fc.property(document, (doc) => identityPreserved(doc)))
  })

  it('re-canonicalizing is idempotent — invariant 2', () => {
    fc.assert(
      fc.property(document, (doc) => {
        const text = toMarkdown(doc)
        return textIsCanonical(text)
      }),
    )
  })
})

describe('presenter-notes sidecar (ADR 0019, round-trip law 6)', () => {
  const withNotes = [
    '---',
    'title: Intro',
    '---',
    '',
    '## Intro {#s1}',
    '',
    '```slide',
    '\\node[body] (b) {audience \\pause reveal};',
    '```',
    '',
    '```notes',
    '\\node[body] (n) {open \\pause caveat};',
    '```',
    '',
  ].join('\n')

  it('is canonical — a notes block round-trips (invariant 2)', () => {
    expect(textIsCanonical(withNotes)).toBe(true)
  })

  it('parses the ```notes block into Frame.notes', () => {
    const doc = fromMarkdown(withNotes)
    const frame = doc.frames[0]!
    expect(nodeNames({ ...doc, frames: [{ ...frame, picture: frame.picture }] })).toEqual(['b'])
    expect(frame.notes).toBeDefined()
    expect(frame.notes!.statements.filter((s) => s.kind === 'node')).toHaveLength(1)
  })

  it('a slide with no notes emits no ```notes block', () => {
    const doc = fromMarkdown(fixture)
    expect(doc.frames[0]!.notes).toBeUndefined()
    expect(toMarkdown(doc)).not.toContain('```notes')
  })

  it('round-trips a model that has notes (invariant 1)', () => {
    const doc = fromMarkdown(withNotes)
    expect(modelRoundTrips(doc)).toBe(true)
  })
})

describe('locality and order independence (invariants 3 and 5)', () => {
  it('moving one node rewrites only its statement — invariant 3', () => {
    const doc = fromMarkdown(fixture)
    const before = toMarkdown(doc)
    const o2 = doc.frames[0]!.picture.statements[2] as NodeStatement
    o2.at = { x: 12, y: 3 }
    const after = toMarkdown(doc)

    const changed = before.split('\n').filter((line, i) => line !== after.split('\n')[i])
    expect(changed).toEqual(['\\node[note] (o2) at (10,3) {$\\int_0^1 f$};'])
  })

  it('two edits to different nodes commute — invariant 5', () => {
    const editTitle = (doc: SlideDocument) => {
      ;(doc.frames[0]!.picture.statements[0] as NodeStatement).options = ['title', 'draw']
    }
    const editNote = (doc: SlideDocument) => {
      ;(doc.frames[0]!.picture.statements[2] as NodeStatement).at = { x: 11, y: 2 }
    }

    const a = fromMarkdown(fixture)
    editTitle(a)
    editNote(a)

    const b = fromMarkdown(fixture)
    editNote(b)
    editTitle(b)

    expect(toMarkdown(a)).toBe(toMarkdown(b))
  })
})
