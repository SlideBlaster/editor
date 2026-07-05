import { describe, it, expect } from 'vitest'
import { parsePicture } from '../tikz/parse'
import { serializePicture } from '../tikz/serialize'
import { parseContent } from '../content/parse'
import { serializeBody } from '../content/serialize'
import { findNode, uniqueName, moveNodeTo, createNode, deleteNode, setNodeContent } from './ops'

const SOURCE = [
  '\\node[title] (title) at (8,8) {T};',
  '\\node[body, below=0.7 of title, text width=12] (intro) {hi};',
  '\\node[note] (o2) at (10,3) {x};',
  '\\draw[->] (intro) -- (o2);',
].join('\n')

const picture = () => parsePicture(SOURCE)

/** The invariant that matters for every op: the result is canonical, parseable source. */
const roundTrips = (p: ReturnType<typeof picture>): boolean =>
  serializePicture(parsePicture(serializePicture(p))) === serializePicture(p)

describe('findNode / uniqueName', () => {
  it('finds a node by its name and misses cleanly', () => {
    expect(findNode(picture(), 'intro')?.name).toBe('intro')
    expect(findNode(picture(), 'nope')).toBeUndefined()
  })

  it('mints a name that avoids existing ones', () => {
    expect(uniqueName(picture())).toBe('n1')
    expect(uniqueName(parsePicture('\\node (n1) at (0,0) {};'))).toBe('n2')
  })
})

describe('moveNodeTo', () => {
  it('sets an absolute position and strips the conflicting relative placement', () => {
    const out = serializePicture(moveNodeTo(picture(), 'intro', { x: 4, y: 2 }))
    expect(out).toContain('\\node[body, text width=12] (intro) at (4,2) {hi};')
    expect(out).not.toContain('below=0.7 of title')
  })

  it('updates an already-absolute node in place', () => {
    const out = serializePicture(moveNodeTo(picture(), 'o2', { x: 1, y: 5 }))
    expect(out).toContain('\\node[note] (o2) at (1,5) {x};')
  })

  it('is a serialization no-op for an unknown node', () => {
    expect(serializePicture(moveNodeTo(picture(), 'ghost', { x: 0, y: 0 }))).toBe(SOURCE)
  })

  it('is local: other statements are untouched', () => {
    const out = serializePicture(moveNodeTo(picture(), 'intro', { x: 4, y: 2 })).split('\n')
    expect(out[0]).toBe('\\node[title] (title) at (8,8) {T};')
    expect(out[2]).toBe('\\node[note] (o2) at (10,3) {x};')
    expect(out[3]).toBe('\\draw[->] (intro) -- (o2);')
  })

  it('round-trips', () => {
    expect(roundTrips(moveNodeTo(picture(), 'intro', { x: 4, y: 2 }))).toBe(true)
  })
})

describe('createNode', () => {
  it('appends a fresh empty node and returns its name', () => {
    const { picture: out, name } = createNode(picture(), { at: { x: 1, y: 1 } })
    expect(name).toBe('n1')
    expect(serializePicture(out)).toContain('\\node (n1) at (1,1) {};')
    expect(roundTrips(out)).toBe(true)
  })

  it('honours an explicit spec', () => {
    const { picture: out } = createNode(picture(), {
      name: 'box',
      at: { x: 2, y: 2 },
      options: ['note'],
    })
    expect(serializePicture(out)).toContain('\\node[note] (box) at (2,2) {};')
  })
})

describe('setNodeContent', () => {
  it('replaces the body and leaves geometry and options untouched', () => {
    const out = serializePicture(setNodeContent(picture(), 'intro', parseContent('**bold**')))
    expect(out).toContain('\\node[body, below=0.7 of title, text width=12] (intro) {**bold**};')
  })

  it('is local: other statements are untouched', () => {
    const lines = serializePicture(
      setNodeContent(picture(), 'intro', parseContent('new text')),
    ).split('\n')
    expect(lines[0]).toBe('\\node[title] (title) at (8,8) {T};')
    expect(lines[2]).toBe('\\node[note] (o2) at (10,3) {x};')
    expect(lines[3]).toBe('\\draw[->] (intro) -- (o2);')
  })

  it('preserves out-of-subset source verbatim in an error node (ADR 0015)', () => {
    const out = serializePicture(
      setNodeContent(picture(), 'intro', parseContent('\\usetikzlibrary{calc}')),
    )
    expect(out).toContain('(intro) {\\usetikzlibrary{calc}};')
  })

  it('is a serialization no-op for an unknown node', () => {
    expect(serializePicture(setNodeContent(picture(), 'ghost', parseContent('x')))).toBe(SOURCE)
  })

  it('round-trips, and re-parsing the edited body is stable', () => {
    const edited = setNodeContent(picture(), 'intro', parseContent('a *b* c'))
    expect(roundTrips(edited)).toBe(true)
    expect(serializeBody(findNode(edited, 'intro')!.content)).toBe('a *b* c')
  })
})

describe('deleteNode', () => {
  it('removes the node and prunes the connector that references it', () => {
    const out = serializePicture(deleteNode(picture(), 'o2'))
    expect(out).not.toContain('(o2)')
    expect(out).not.toContain('\\draw')
    expect(out).toContain('(intro)')
  })

  it('keeps connectors that do not reference the deleted node', () => {
    const out = serializePicture(deleteNode(picture(), 'title'))
    expect(out).not.toContain('(title)')
    expect(out).toContain('\\draw[->] (intro) -- (o2);')
    expect(roundTrips(deleteNode(picture(), 'title'))).toBe(true)
  })
})
