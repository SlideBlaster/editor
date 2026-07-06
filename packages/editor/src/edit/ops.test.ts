import { describe, it, expect } from 'vitest'
import { parsePicture } from '../tikz/parse'
import { serializePicture } from '../tikz/serialize'
import { parseContent } from '../content/parse'
import { serializeBody } from '../content/serialize'
import { parseConnector, type ConnectorPath } from '../tikz/connector'
import { nodeOverlay } from '../tikz/options'
import {
  findNode,
  uniqueName,
  moveNodeTo,
  resizeNode,
  createNode,
  deleteNode,
  setNodeContent,
  setNodeOverlay,
  placeNodeRelative,
  adjustPlacement,
  createConnector,
  deleteConnector,
  updateConnector,
  connectorOptions,
  setConnectorOptions,
} from './ops'

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

describe('resizeNode', () => {
  it('replaces an existing text width in place, keeping other options', () => {
    const out = serializePicture(resizeNode(picture(), 'intro', { textWidth: 8 }))
    expect(out).toContain('\\node[body, below=0.7 of title, text width=8] (intro) {hi};')
  })

  it('adds a text width to a node that had none', () => {
    const out = serializePicture(resizeNode(picture(), 'o2', { textWidth: 5 }))
    expect(out).toContain('\\node[note, text width=5] (o2) at (10,3) {x};')
  })

  it('adds and later clears a minimum height (null resets to auto)', () => {
    const sized = resizeNode(picture(), 'o2', { minHeight: 2.5 })
    expect(serializePicture(sized)).toContain(
      '\\node[note, minimum height=2.5] (o2) at (10,3) {x};',
    )
    const cleared = resizeNode(sized, 'o2', { minHeight: null })
    expect(serializePicture(cleared)).toContain('\\node[note] (o2) at (10,3) {x};')
  })

  it('sets width and height together and round-trips', () => {
    const out = resizeNode(picture(), 'o2', { textWidth: 6, minHeight: 3 })
    expect(serializePicture(out)).toContain(
      '\\node[note, text width=6, minimum height=3] (o2) at (10,3) {x};',
    )
    expect(roundTrips(out)).toBe(true)
  })

  it('leaves an omitted axis untouched', () => {
    const out = serializePicture(resizeNode(picture(), 'intro', { minHeight: 1 }))
    // width stays at its original 12; height token is appended
    expect(out).toContain('text width=12')
    expect(out).toContain('minimum height=1')
  })

  it('writes a single scale token when the axes are equal', () => {
    const out = serializePicture(resizeNode(picture(), 'o2', { scaleX: 1.5, scaleY: 1.5 }))
    expect(out).toContain('\\node[note, scale=1.5] (o2) at (10,3) {x};')
  })

  it('writes xscale/yscale when the axes differ, and round-trips', () => {
    const out = resizeNode(picture(), 'o2', { scaleX: 2, scaleY: 1.25 })
    expect(serializePicture(out)).toContain(
      '\\node[note, xscale=2, yscale=1.25] (o2) at (10,3) {x};',
    )
    expect(roundTrips(out)).toBe(true)
  })

  it('clears scale tokens at 1x1 (natural size)', () => {
    const scaled = resizeNode(picture(), 'o2', { scaleX: 2, scaleY: 1.25 })
    const reset = resizeNode(scaled, 'o2', { scaleX: 1, scaleY: 1 })
    expect(serializePicture(reset)).toContain('\\node[note] (o2) at (10,3) {x};')
  })

  it('replaces a prior scale form (xscale/yscale -> scale) rather than stacking', () => {
    const uneven = resizeNode(picture(), 'o2', { scaleX: 2, scaleY: 1.25 })
    const even = serializePicture(resizeNode(uneven, 'o2', { scaleX: 1.5, scaleY: 1.5 }))
    expect(even).toContain('scale=1.5')
    expect(even).not.toContain('xscale')
    expect(even).not.toContain('yscale')
  })

  it('is a serialization no-op for an unknown node', () => {
    expect(serializePicture(resizeNode(picture(), 'ghost', { textWidth: 3 }))).toBe(SOURCE)
  })

  it('is local: other statements are untouched', () => {
    const out = serializePicture(resizeNode(picture(), 'intro', { textWidth: 8 })).split('\n')
    expect(out[0]).toBe('\\node[title] (title) at (8,8) {T};')
    expect(out[2]).toBe('\\node[note] (o2) at (10,3) {x};')
    expect(out[3]).toBe('\\draw[->] (intro) -- (o2);')
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

describe('placeNodeRelative', () => {
  it('binds an absolute node below another, dropping its at', () => {
    const out = serializePicture(
      placeNodeRelative(picture(), 'o2', { side: 'below', gap: 0.5, ref: 'title' }),
    )
    expect(out).toContain('\\node[note, below=0.5 of title] (o2) {x};')
    expect(out).not.toContain('at (10,3)')
  })

  it('replaces an existing placement token in place, keeping other options', () => {
    const out = serializePicture(
      placeNodeRelative(picture(), 'intro', { side: 'right', gap: 1, ref: 'title' }),
    )
    expect(out).toContain('\\node[body, right=1 of title, text width=12] (intro) {hi};')
    expect(out).not.toContain('below=0.7')
  })

  it('is a no-op when the ref does not exist', () => {
    expect(
      serializePicture(placeNodeRelative(picture(), 'o2', { side: 'below', gap: 1, ref: 'ghost' })),
    ).toBe(SOURCE)
  })

  it('refuses to bind a node to itself', () => {
    expect(
      serializePicture(placeNodeRelative(picture(), 'o2', { side: 'below', gap: 1, ref: 'o2' })),
    ).toBe(SOURCE)
  })

  it('refuses a binding that would form a placement cycle', () => {
    // intro is already below title; binding title below intro would close the cycle.
    expect(
      serializePicture(
        placeNodeRelative(picture(), 'title', { side: 'below', gap: 1, ref: 'intro' }),
      ),
    ).toBe(SOURCE)
  })

  it('is local and round-trips', () => {
    const edited = placeNodeRelative(picture(), 'o2', { side: 'above', gap: 0.5, ref: 'title' })
    const lines = serializePicture(edited).split('\n')
    expect(lines[0]).toBe('\\node[title] (title) at (8,8) {T};')
    expect(lines[1]).toBe('\\node[body, below=0.7 of title, text width=12] (intro) {hi};')
    expect(roundTrips(edited)).toBe(true)
  })
})

describe('adjustPlacement', () => {
  it('changes the gap, keeping side and ref', () => {
    const out = serializePicture(adjustPlacement(picture(), 'intro', { gap: 1.5 }))
    expect(out).toContain('\\node[body, below=1.5 of title, text width=12] (intro) {hi};')
  })

  it('flips the side, keeping gap and ref', () => {
    const out = serializePicture(adjustPlacement(picture(), 'intro', { side: 'right' }))
    expect(out).toContain('\\node[body, right=0.7 of title, text width=12] (intro) {hi};')
  })

  it('is a no-op on an absolutely-placed node', () => {
    expect(serializePicture(adjustPlacement(picture(), 'o2', { gap: 2 }))).toBe(SOURCE)
  })
})

describe('createConnector', () => {
  it('appends a forward arrow between two nodes', () => {
    const out = serializePicture(createConnector(picture(), 'title', 'o2'))
    expect(out).toContain('\\draw[->] (title) -- (o2);')
    expect(roundTrips(createConnector(picture(), 'title', 'o2'))).toBe(true)
  })

  it('honours explicit options', () => {
    const out = serializePicture(createConnector(picture(), 'title', 'o2', ['<->', 'dashed']))
    expect(out).toContain('\\draw[<->, dashed] (title) -- (o2);')
  })

  it('is a no-op when an endpoint is missing', () => {
    expect(serializePicture(createConnector(picture(), 'title', 'ghost'))).toBe(SOURCE)
    expect(serializePicture(createConnector(picture(), 'ghost', 'o2'))).toBe(SOURCE)
  })
})

describe('updateConnector', () => {
  it('reshapes the connector body while keeping its options', () => {
    const reshaped = parseConnector(' (intro) -- (title)')! // move the o2 endpoint to title
    const out = serializePicture(updateConnector(picture(), 0, reshaped))
    expect(out).toContain('\\draw[->] (intro) -- (title);')
    expect(out).not.toContain('-- (o2)') // the old endpoint is gone from the connector
  })

  it('writes a curved segment and round-trips', () => {
    const curved: ConnectorPath = {
      anchors: [
        { kind: 'node', name: 'intro' },
        { kind: 'node', name: 'o2' },
      ],
      curves: [{ c1: { x: 2, y: 2 }, c2: { x: 4, y: 2 } }],
    }
    const edited = updateConnector(picture(), 0, curved)
    expect(serializePicture(edited)).toContain(
      '\\draw[->] (intro) .. controls (2,2) and (4,2) .. (o2);',
    )
    expect(roundTrips(edited)).toBe(true)
  })

  it('is a no-op when the index is out of range', () => {
    const reshaped = parseConnector(' (intro) -- (o2)')!
    expect(serializePicture(updateConnector(picture(), 5, reshaped))).toBe(SOURCE)
  })
})

describe('connectorOptions / setConnectorOptions', () => {
  it('reads the connector option tokens', () => {
    expect(connectorOptions(picture(), 0)).toEqual(['->'])
    expect(connectorOptions(picture(), 5)).toBeUndefined()
  })

  it('replaces the option tokens, keeping the body', () => {
    const out = serializePicture(setConnectorOptions(picture(), 0, ['<->', 'dashed']))
    expect(out).toContain('\\draw[<->, dashed] (intro) -- (o2);')
  })

  it('is a no-op when the index is out of range', () => {
    expect(serializePicture(setConnectorOptions(picture(), 5, ['->']))).toBe(SOURCE)
  })
})

describe('deleteConnector', () => {
  it('removes the connector at the given path index', () => {
    // SOURCE has exactly one path (index 0): the intro -> o2 arrow.
    const out = serializePicture(deleteConnector(picture(), 0))
    expect(out).not.toContain('\\draw')
    expect(out).toContain('(intro)') // nodes untouched
  })

  it('removes only the addressed connector when several exist', () => {
    const two = createConnector(picture(), 'title', 'o2') // becomes path index 1
    const out = serializePicture(deleteConnector(two, 1))
    expect(out).toContain('\\draw[->] (intro) -- (o2);') // index 0 kept
    expect(out).not.toContain('(title) -- (o2)') // index 1 removed
  })

  it('is a no-op when the index is out of range', () => {
    expect(serializePicture(deleteConnector(picture(), 5))).toBe(SOURCE)
  })
})

describe('setNodeOverlay', () => {
  it('sets a brace-wrapped overlay option (commas survive tokenizing) and round-trips', () => {
    const out = serializePicture(setNodeOverlay(picture(), 'o2', '1,3'))
    expect(out).toContain('overlay={1,3}')
    expect(roundTrips(setNodeOverlay(picture(), 'o2', '1,3'))).toBe(true)
    expect(nodeOverlay(findNode(setNodeOverlay(picture(), 'o2', '1,3'), 'o2')!)).toEqual({
      raw: '1,3',
    })
  })

  it('replaces an existing overlay in place and clears it on null/blank', () => {
    const set = setNodeOverlay(picture(), 'o2', '2-')
    expect(serializePicture(setNodeOverlay(set, 'o2', '3-'))).toContain('overlay={3-}')
    expect(serializePicture(setNodeOverlay(set, 'o2', '3-'))).not.toContain('overlay={2-}')
    expect(serializePicture(setNodeOverlay(set, 'o2', null))).not.toContain('overlay=')
    expect(serializePicture(setNodeOverlay(set, 'o2', '  '))).not.toContain('overlay=')
  })

  it('is a no-op when the node is not found', () => {
    expect(serializePicture(setNodeOverlay(picture(), 'nope', '2-'))).toBe(SOURCE)
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
