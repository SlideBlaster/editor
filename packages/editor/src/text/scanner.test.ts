import { describe, it, expect } from 'vitest'
import { readGroup, splitOptions, splitStatements, parsePoint } from './scanner'

describe('splitStatements', () => {
  it('splits on top-level semicolons and trims', () => {
    expect(splitStatements('\\a; \\b;')).toEqual(['\\a', '\\b'])
  })

  it('ignores semicolons and brackets inside a brace body', () => {
    const src = '\\node (a) {x; y [z] (w)}; \\node (b) {};'
    expect(splitStatements(src)).toEqual(['\\node (a) {x; y [z] (w)}', '\\node (b) {}'])
  })

  it('keeps a multi-line body as one statement', () => {
    const src = '\\node (a) {\n- one\n- two\n};\n\\draw (a) -- (b);'
    expect(splitStatements(src)).toEqual(['\\node (a) {\n- one\n- two\n}', '\\draw (a) -- (b)'])
  })

  it('does not split on a semicolon inside a coordinate/option run', () => {
    expect(splitStatements('\\draw (a) -- (b) [x];')).toEqual(['\\draw (a) -- (b) [x]'])
  })
})

describe('splitOptions', () => {
  it('splits top-level commas and trims', () => {
    expect(splitOptions('body, below=0.7 of title, text width=12')).toEqual([
      'body',
      'below=0.7 of title',
      'text width=12',
    ])
  })

  it('is empty for empty input', () => {
    expect(splitOptions('')).toEqual([])
  })

  it('respects nested braces in a value', () => {
    expect(splitOptions('label={a, b}, draw')).toEqual(['label={a, b}', 'draw'])
  })
})

describe('readGroup', () => {
  it('reads a brace body with nested braces', () => {
    const src = '{a {b} c} rest'
    expect(readGroup(src, 0, '{', '}')).toEqual({ inner: 'a {b} c', end: 9 })
  })

  it('reads a bracket group, ignoring brackets inside an embedded brace', () => {
    const src = '[a, label={x]y}] rest'
    const group = readGroup(src, 0, '[', ']')
    expect(group.inner).toBe('a, label={x]y}')
  })

  it('throws on an unterminated group', () => {
    expect(() => readGroup('{a b', 0, '{', '}')).toThrow()
  })
})

describe('parsePoint', () => {
  it('parses integer and decimal coordinates', () => {
    expect(parsePoint('10,3')).toEqual({ x: 10, y: 3 })
    expect(parsePoint('8, 4.5')).toEqual({ x: 8, y: 4.5 })
  })

  it('throws on a non-pair or non-numeric', () => {
    expect(() => parsePoint('1,2,3')).toThrow()
    expect(() => parsePoint('a,b')).toThrow()
  })
})
