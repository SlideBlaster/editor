import { describe, it, expect } from 'vitest'
import type { Frame, TikzPicture } from '@slideblaster/editor'
import { buildBeats, buildAudienceDocument, type Beat } from './presenter'

// Tag pictures so the fake renderer can name what it drew, without a real engine.
const names = new WeakMap<TikzPicture, string>()
const stepCounts = new WeakMap<TikzPicture, number>()
function pic(name: string, steps: number): TikzPicture {
  const p = { statements: [] } as unknown as TikzPicture
  names.set(p, name)
  stepCounts.set(p, steps)
  return p
}
const renderAt = (p: TikzPicture, step: number): string => `${names.get(p)}@${step}`
const stepsOf = (p: TikzPicture): number => stepCounts.get(p) ?? 1
const frame = (id: string, picture: TikzPicture, notes?: TikzPicture): Frame => ({
  id,
  title: id,
  picture,
  ...(notes ? { notes } : {}),
})

describe('buildBeats — the shared beat timeline (ADR 0019)', () => {
  it('renders the slide and its notes at the SAME step (keyed to one counter)', async () => {
    const beats = await buildBeats(
      [frame('s1', pic('slide', 2), pic('notes', 2))],
      renderAt,
      stepsOf,
    )
    expect(beats.map((b) => [b.step, b.slideHtml, b.notesHtml])).toEqual([
      [1, 'slide@1', 'notes@1'],
      [2, 'slide@2', 'notes@2'],
    ])
  })

  it('caps the step count to the slide — notes never add steps', async () => {
    // Notes reference 3 steps, but the audience slide only plays 2: only 2 beats, and
    // the notes are rendered at steps 1 and 2 (never 3).
    const beats = await buildBeats(
      [frame('s1', pic('slide', 2), pic('notes', 3))],
      renderAt,
      stepsOf,
    )
    expect(beats).toHaveLength(2)
    expect(beats.every((b) => b.steps === 2)).toBe(true)
    expect(beats.map((b) => b.notesHtml)).toEqual(['notes@1', 'notes@2'])
  })

  it('emits empty notes HTML for a slide with no sidecar', async () => {
    const beats = await buildBeats([frame('s1', pic('slide', 2))], renderAt, stepsOf)
    expect(beats.map((b) => b.notesHtml)).toEqual(['', ''])
  })

  it('flattens frames in reading order, one beat per step', async () => {
    const beats = await buildBeats(
      [frame('s1', pic('a', 2)), frame('s2', pic('b', 1))],
      renderAt,
      stepsOf,
    )
    expect(beats.map((b) => [b.frame, b.step])).toEqual([
      [0, 1],
      [0, 2],
      [1, 1],
    ])
  })

  it('always yields at least one beat per frame', async () => {
    const beats = await buildBeats([frame('s1', pic('a', 0))], renderAt, stepsOf)
    expect(beats).toHaveLength(1)
    expect(beats[0]!.step).toBe(1)
  })
})

describe('buildAudienceDocument — self-contained + safe', () => {
  const beats: Beat[] = [
    { frame: 0, step: 1, steps: 1, slideHtml: '<div class="sb-slide">hi</div>', notesHtml: '' },
  ]

  it('inlines the css and bakes the slide HTML', () => {
    const doc = buildAudienceDocument(beats, { title: 'Talk', css: '.sb-slide{color:red}' })
    expect(doc).toContain('.sb-slide{color:red}')
    expect(doc).toContain('BroadcastChannel')
    expect(doc).toContain('sb-slide')
  })

  it('neutralises a closing script tag baked into slide HTML (no breakout)', () => {
    const evil: Beat[] = [
      {
        frame: 0,
        step: 1,
        steps: 1,
        slideHtml: '</script><script>alert(1)</script>',
        notesHtml: '',
      },
    ]
    const doc = buildAudienceDocument(evil, { title: 'x', css: '' })
    // The raw closing tag must not appear verbatim inside the embedded data.
    expect(doc).not.toContain('</script><script>alert(1)')
    expect(doc).toContain('\\u003c/script>')
  })
})
