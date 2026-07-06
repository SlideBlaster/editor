import { describe, it, expect } from 'vitest'
import { minimalDiff, applyRange } from './sourceDelta'

describe('minimalDiff / applyRange', () => {
  const cases: [string, string, string][] = [
    ['no-op', 'abc', 'abc'],
    ['replace middle', 'a<b>c', 'a<Z>c'],
    ['insert middle', 'abcd', 'abXYcd'],
    ['delete middle', 'abXYcd', 'abcd'],
    ['prepend', 'world', 'hello world'],
    ['append', 'hello', 'hello world'],
    ['empty -> full', '', 'brand new'],
    ['full -> empty', 'all gone', ''],
    ['repeated chars (suffix must not cross prefix)', 'aaaa', 'aaaaaa'],
    ['column width bump', '\\column{0.6}left', '\\column{0.5}left'],
  ]

  it.each(cases)('invariant holds: %s', (_name, oldStr, newStr) => {
    expect(applyRange(oldStr, minimalDiff(oldStr, newStr))).toBe(newStr)
  })

  it('yields a tight range for a localized edit', () => {
    const edit = minimalDiff(
      '\\column{0.6}left\\column{0.4}right',
      '\\column{0.7}left\\column{0.4}right',
    )
    expect(edit).toEqual({ start: 10, end: 11, text: '7' }) // just the changed digit
  })

  it('an identical edit is an empty no-op at the end', () => {
    expect(minimalDiff('same', 'same')).toEqual({ start: 4, end: 4, text: '' })
  })

  it('fuzz: a random single-splice round-trips through the diff', () => {
    // Deterministic LCG so the corpus is stable across runs (no Math.random).
    let seed = 0x2f6e2b1
    const rand = (n: number): number => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) % n
    const alpha = 'ab{}0.\\c '
    const str = (len: number): string =>
      Array.from({ length: len }, () => alpha[rand(alpha.length)]).join('')
    for (let i = 0; i < 500; i++) {
      const base = str(rand(30))
      const at = rand(base.length + 1)
      const removed = rand(base.length - at + 1)
      const inserted = str(rand(6))
      const next = base.slice(0, at) + inserted + base.slice(at + removed)
      expect(applyRange(base, minimalDiff(base, next))).toBe(next)
    }
  })
})
