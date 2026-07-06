import { describe, it, expect } from 'vitest'
import { parseContent } from './parse'
import { serializeBody } from './serialize'
import { setColumnWidths, insertColumn, removeColumn } from './columns'

/** Parse a body, apply a transform, serialize back — the round-trip these edits live in. */
const body = (src: string): string => serializeBody(parseContent(src))

const COLS = '\\begin{columns}\\column{0.6}left\\column{0.4}**right**\\end{columns}'

describe('setColumnWidths', () => {
  it('rewrites only the patched widths, keeping content and untouched columns', () => {
    const out = serializeBody(setColumnWidths(parseContent(COLS), 0, { 0: '0.5', 1: '0.5' }))
    expect(out).toBe('\\begin{columns}\\column{0.5}left\\column{0.5}**right**\\end{columns}')
  })

  it('patches one column and leaves the neighbour verbatim', () => {
    const out = serializeBody(setColumnWidths(parseContent(COLS), 0, { 0: '0.7' }))
    expect(out).toBe('\\begin{columns}\\column{0.7}left\\column{0.4}**right**\\end{columns}')
  })

  it('is a no-op on a non-existent group index', () => {
    expect(serializeBody(setColumnWidths(parseContent(COLS), 3, { 0: '0.9' }))).toBe(body(COLS))
  })
})

describe('insertColumn', () => {
  it('appends an empty column at the end', () => {
    const out = serializeBody(insertColumn(parseContent(COLS), 0, 2, '0.5'))
    expect(out).toBe(
      '\\begin{columns}\\column{0.6}left\\column{0.4}**right**\\column{0.5}\\end{columns}',
    )
  })

  it('inserts in the middle and clamps an out-of-range index', () => {
    expect(serializeBody(insertColumn(parseContent(COLS), 0, 1, '0.3'))).toBe(
      '\\begin{columns}\\column{0.6}left\\column{0.3}\\column{0.4}**right**\\end{columns}',
    )
    expect(serializeBody(insertColumn(parseContent(COLS), 0, 99, '0.2'))).toBe(
      '\\begin{columns}\\column{0.6}left\\column{0.4}**right**\\column{0.2}\\end{columns}',
    )
  })
})

describe('removeColumn', () => {
  it('drops the column at the index', () => {
    expect(serializeBody(removeColumn(parseContent(COLS), 0, 0))).toBe(
      '\\begin{columns}\\column{0.4}**right**\\end{columns}',
    )
  })

  it('refuses to remove the only remaining column', () => {
    const one = '\\begin{columns}\\column{1}solo\\end{columns}'
    expect(serializeBody(removeColumn(parseContent(one), 0, 0))).toBe(one)
  })
})

describe('pre-order addressing across multiple groups', () => {
  // two sibling columns groups; groupIndex 1 must hit the second, leaving the first alone.
  const two =
    '\\begin{columns}\\column{0.5}a\\column{0.5}b\\end{columns}' +
    ' \\begin{columns}\\column{0.5}c\\column{0.5}d\\end{columns}'

  it('edits the second group by index, not the first', () => {
    const out = serializeBody(setColumnWidths(parseContent(two), 1, { 0: '0.7', 1: '0.3' }))
    expect(out).toBe(
      '\\begin{columns}\\column{0.5}a\\column{0.5}b\\end{columns}' +
        ' \\begin{columns}\\column{0.7}c\\column{0.3}d\\end{columns}',
    )
  })
})
