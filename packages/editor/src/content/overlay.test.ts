import { describe, it, expect } from 'vitest'
import { parseContent } from './parse'
import { activeAt, isValidSpec, specMaxStep, specMinStep, contentMaxStep } from './overlay'

const spec = (raw: string) => ({ raw })

describe('overlay spec: validity', () => {
  it('accepts single steps, open and closed ranges, and unions', () => {
    for (const raw of ['2', '2-', '-3', '2-4', '1,3', '1,3-5', ' 2 , 4- ']) {
      expect(isValidSpec(raw)).toBe(true)
    }
  })

  it('rejects malformed specs (letters, empty terms, backwards ranges)', () => {
    for (const raw of ['', 'x', '2-1', '1,', '-', 'a-b', '2..4']) {
      expect(isValidSpec(raw)).toBe(false)
    }
  })
})

describe('overlay spec: activeAt', () => {
  it('single step is active only on that step', () => {
    expect(activeAt(spec('2'), 1)).toBe(false)
    expect(activeAt(spec('2'), 2)).toBe(true)
    expect(activeAt(spec('2'), 3)).toBe(false)
  })

  it('open-from range is active from its lower bound onward', () => {
    expect(activeAt(spec('2-'), 1)).toBe(false)
    expect(activeAt(spec('2-'), 2)).toBe(true)
    expect(activeAt(spec('2-'), 9)).toBe(true)
  })

  it('closed range and unions', () => {
    expect(activeAt(spec('2-4'), 3)).toBe(true)
    expect(activeAt(spec('2-4'), 5)).toBe(false)
    expect(activeAt(spec('1,3'), 1)).toBe(true)
    expect(activeAt(spec('1,3'), 2)).toBe(false)
    expect(activeAt(spec('1,3'), 3)).toBe(true)
  })

  it('a malformed spec is inactive everywhere (never reaches the model in practice)', () => {
    expect(activeAt(spec('nope'), 1)).toBe(false)
  })
})

describe('overlay spec: bounds', () => {
  it('specMaxStep is the largest finite step named; open ranges contribute their start', () => {
    expect(specMaxStep(spec('2'))).toBe(2)
    expect(specMaxStep(spec('2-'))).toBe(2)
    expect(specMaxStep(spec('-3'))).toBe(3)
    expect(specMaxStep(spec('2-4'))).toBe(4)
    expect(specMaxStep(spec('1,3'))).toBe(3)
  })

  it('specMinStep is the smallest step named (1 when open at the start)', () => {
    expect(specMinStep(spec('3'))).toBe(3)
    expect(specMinStep(spec('2-4'))).toBe(2)
    expect(specMinStep(spec('-3'))).toBe(1)
  })
})

describe('contentMaxStep: a node body reading-order step count', () => {
  const steps = (body: string) => contentMaxStep(parseContent(body))

  it('plain content is a single step', () => {
    expect(steps('just text')).toBe(1)
  })

  it('each \\pause adds a step', () => {
    expect(steps('a \\pause b')).toBe(2)
    expect(steps('a \\pause b \\pause c')).toBe(3)
  })

  it('a \\pause<n> jumps the floor to n', () => {
    expect(steps('a \\pause<4> b')).toBe(4)
  })

  it('overlay wrappers and \\item<spec> contribute their spec max', () => {
    expect(steps('\\only<3>{x}')).toBe(3)
    expect(steps('\\uncover<2->{x}')).toBe(2)
    expect(steps('\\begin{itemize}\\item<5-> late\\item early\\end{itemize}')).toBe(5)
  })
})
