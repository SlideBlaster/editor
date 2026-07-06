import { describe, expect, it } from 'vitest'
import {
  parseTabular,
  setTabularCell,
  resolveTabularCell,
  insertTabularRow,
  removeTabularRow,
  setDeferredSource,
} from './tabular'
import { parseContent } from './parse'
import { serializeBody } from './serialize'

const BOOKTABS = [
  '\\begin{tabular}{lr}',
  '\\toprule',
  'Fruit & Qty \\\\',
  '\\midrule',
  'Apples & 3 \\\\',
  'Pears & 12 \\\\',
  '\\bottomrule',
  '\\end{tabular}',
].join('\n')

const BASIC = [
  '\\begin{tabular}{|l|r|}',
  '\\hline',
  'Item & Qty \\\\',
  '\\hline',
  'Apples & 3 \\\\',
  'Pears & 12 \\\\',
  '\\hline',
  '\\end{tabular}',
].join('\n')

// A merged header cell: row 0 has 2 source cells across 3 physical columns.
const MULTICOL = [
  '\\begin{tabular}{lll}',
  '\\toprule',
  '\\multicolumn{2}{c}{Half} & Rest \\\\',
  '\\midrule',
  'a & b & c \\\\',
  '\\bottomrule',
  '\\end{tabular}',
].join('\n')

// A row-spanning first column: row 1's covered slot is written as an empty leading cell.
const MULTIROW = [
  '\\begin{tabular}{lll}',
  '\\toprule',
  '\\multirow{2}{*}{Group} & a & 1 \\\\',
  ' & b & 2 \\\\',
  '\\midrule',
  'x & y & z \\\\',
  '\\bottomrule',
  '\\end{tabular}',
].join('\n')

describe('parseTabular', () => {
  it('reads data rows and cells, skipping booktabs rules', () => {
    const grid = parseTabular(BOOKTABS)!
    expect(grid).not.toBeNull()
    expect(grid.columns).toBe(2)
    expect(grid.spanned).toBe(false)
    expect(grid.rows.map((r) => r.cells.map((c) => c.text))).toEqual([
      ['Fruit', 'Qty'],
      ['Apples', '3'],
      ['Pears', '12'],
    ])
  })

  it('skips \\hline rules too', () => {
    const grid = parseTabular(BASIC)!
    expect(grid.rows.map((r) => r.cells.map((c) => c.text))).toEqual([
      ['Item', 'Qty'],
      ['Apples', '3'],
      ['Pears', '12'],
    ])
  })

  it('cell spans point at the exact source text', () => {
    const grid = parseTabular(BOOKTABS)!
    for (const row of grid.rows) {
      for (const cell of row.cells) {
        expect(BOOKTABS.slice(cell.start, cell.end)).toBe(cell.text)
      }
    }
  })

  it('flags \\multicolumn / \\multirow tables as spanned', () => {
    const mc =
      '\\begin{tabular}{lcc}\n& \\multicolumn{2}{c}{Half} \\\\\nA & 1 & 2 \\\\\n\\end{tabular}'
    expect(parseTabular(mc)!.spanned).toBe(true)
    const mr = '\\begin{tabular}{ll}\n\\multirow{2}{*}{G} & a \\\\\n& b \\\\\n\\end{tabular}'
    expect(parseTabular(mr)!.spanned).toBe(true)
  })

  it('protects & inside braces and escaped \\&', () => {
    const grid = parseTabular(
      '\\begin{tabular}{ll}\n\\textbf{a & b} & c \\\\\nx \\& y & z \\\\\n\\end{tabular}',
    )!
    expect(grid.rows[0]!.cells.map((c) => c.text)).toEqual(['\\textbf{a & b}', 'c'])
    expect(grid.rows[1]!.cells.map((c) => c.text)).toEqual(['x \\& y', 'z'])
  })

  it('handles an optional position arg and a p-column spec', () => {
    const grid = parseTabular('\\begin{tabular}[t]{l p{3cm}}\na & b \\\\\n\\end{tabular}')!
    expect(grid.colspec).toBe('l p{3cm}')
    expect(grid.rows[0]!.cells.map((c) => c.text)).toEqual(['a', 'b'])
  })

  it('returns null for a non-tabular string', () => {
    expect(parseTabular('just text')).toBeNull()
  })
})

describe('setTabularCell', () => {
  it('replaces one cell without disturbing the rest', () => {
    const next = setTabularCell(BOOKTABS, 1, 0, 'Bananas')
    expect(next).toContain('Bananas & 3 \\\\')
    expect(next).toContain('Fruit & Qty \\\\')
    const grid = parseTabular(next)!
    expect(grid.rows[1]!.cells[0]!.text).toBe('Bananas')
  })

  it('can set an empty cell', () => {
    const next = setTabularCell(BOOKTABS, 2, 1, '')
    expect(parseTabular(next)!.rows[2]!.cells.map((c) => c.text)).toEqual(['Pears', ''])
  })

  it('is a no-op out of range', () => {
    expect(setTabularCell(BOOKTABS, 9, 9, 'x')).toBe(BOOKTABS)
  })
})

describe('insertTabularRow', () => {
  it('adds a blank data row after the given row', () => {
    const next = insertTabularRow(BOOKTABS, 2)
    const grid = parseTabular(next)!
    expect(grid.rows).toHaveLength(4)
    expect(grid.rows[3]!.cells.map((c) => c.text)).toEqual(['', ''])
    // The new row lands before \bottomrule, not after \end.
    expect(next.indexOf(' & \\\\')).toBeLessThan(next.indexOf('\\bottomrule'))
  })

  it('produces a row you can then fill in', () => {
    const withRow = insertTabularRow(BOOKTABS, 2)
    const filled = setTabularCell(setTabularCell(withRow, 3, 0, 'Cherries'), 3, 1, '40')
    expect(parseTabular(filled)!.rows[3]!.cells.map((c) => c.text)).toEqual(['Cherries', '40'])
  })
})

describe('removeTabularRow', () => {
  it('drops a data row and leaves the others', () => {
    const next = removeTabularRow(BOOKTABS, 1)
    expect(parseTabular(next)!.rows.map((r) => r.cells[0]!.text)).toEqual(['Fruit', 'Pears'])
  })

  it('refuses to remove the only data row', () => {
    const one = '\\begin{tabular}{l}\na \\\\\n\\end{tabular}'
    expect(removeTabularRow(one, 0)).toBe(one)
  })
})

describe('physical grid coordinates', () => {
  it('numbers plain cells left to right on each row', () => {
    const grid = parseTabular(BOOKTABS)!
    expect(grid.rows.map((r) => r.cells.map((c) => c.x))).toEqual([
      [0, 1],
      [0, 1],
      [0, 1],
    ])
    expect(grid.rows.every((r) => r.cells.every((c) => c.colspan === 1))).toBe(true)
  })

  it('advances x by the colspan of a \\multicolumn', () => {
    const grid = parseTabular(MULTICOL)!
    expect(grid.columns).toBe(3)
    // Half spans columns 0-1 (x=0, colspan=2); Rest sits at physical column 2.
    expect(grid.rows[0]!.cells.map((c) => ({ x: c.x, colspan: c.colspan }))).toEqual([
      { x: 0, colspan: 2 },
      { x: 2, colspan: 1 },
    ])
    expect(grid.rows[1]!.cells.map((c) => c.x)).toEqual([0, 1, 2])
  })

  it('keeps a source cell for the slot a \\multirow overhang covers', () => {
    const grid = parseTabular(MULTIROW)!
    // Row 1 keeps three source cells (empty, b, 2) at physical columns 0,1,2.
    expect(grid.rows[1]!.cells.map((c) => ({ x: c.x, text: c.text }))).toEqual([
      { x: 0, text: '' },
      { x: 1, text: 'b' },
      { x: 2, text: '2' },
    ])
  })
})

describe('resolveTabularCell', () => {
  it('maps a compiled cell position back to source (row, col)', () => {
    const grid = parseTabular(MULTICOL)!
    expect(resolveTabularCell(grid, 0, 0)).toEqual({ row: 0, col: 0 }) // Half
    expect(resolveTabularCell(grid, 2, 0)).toEqual({ row: 0, col: 1 }) // Rest
    // Physical column 1 of row 0 is inside Half's span — no cell begins there.
    expect(resolveTabularCell(grid, 1, 0)).toBeNull()
  })

  it('resolves the rendered cells of a \\multirow row past the covered slot', () => {
    const grid = parseTabular(MULTIROW)!
    // The compiled row 1 renders only b@(1,1) and 2@(2,1); both resolve.
    expect(resolveTabularCell(grid, 1, 1)).toEqual({ row: 1, col: 1 }) // b
    expect(resolveTabularCell(grid, 2, 1)).toEqual({ row: 1, col: 2 }) // 2
  })

  it('is null for an out-of-range position', () => {
    const grid = parseTabular(BOOKTABS)!
    expect(resolveTabularCell(grid, 5, 0)).toBeNull()
    expect(resolveTabularCell(grid, 0, 9)).toBeNull()
  })
})

describe('editing a spanned cell', () => {
  it('rewrites only the wrapped content of a \\multicolumn', () => {
    const next = setTabularCell(MULTICOL, 0, 0, 'HALF')
    expect(next).toContain('\\multicolumn{2}{c}{HALF} & Rest')
  })

  it('rewrites only the wrapped content of a \\multirow', () => {
    const next = setTabularCell(MULTIROW, 0, 0, 'Grp')
    expect(next).toContain('\\multirow{2}{*}{Grp} & a & 1')
  })
})

describe('setDeferredSource', () => {
  it('replaces the addressed table run, round-tripping the rest', () => {
    const content = parseContent(`before ${BOOKTABS} after`)
    const nextSource = insertTabularRow(BOOKTABS, 2)
    const updated = setDeferredSource(content, 0, nextSource)
    const body = serializeBody(updated)
    expect(body).toBe(`before ${nextSource} after`)
  })

  it('addresses the Nth deferred table in pre-order', () => {
    const t2 = '\\begin{tabular}{c}z \\\\\n\\end{tabular}'
    const content = parseContent(`${BOOKTABS}\n${t2}`)
    const updated = setDeferredSource(content, 1, '\\begin{tabular}{c}Q \\\\\n\\end{tabular}')
    const body = serializeBody(updated)
    expect(body).toContain(BOOKTABS)
    expect(body).toContain('Q \\\\')
    expect(body).not.toContain('z \\\\')
  })
})
