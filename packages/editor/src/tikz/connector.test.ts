import { describe, it, expect } from 'vitest'
import { parseConnector, serializeConnector, type ConnectorPath } from './connector'

describe('parseConnector', () => {
  it('parses a straight two-node connector', () => {
    const path = parseConnector(' (a) -- (b)')
    expect(path).not.toBeNull()
    expect(path!.anchors).toEqual([
      { kind: 'node', name: 'a' },
      { kind: 'node', name: 'b' },
    ])
    expect(path!.curves).toEqual([null])
  })

  it('parses a point anchor', () => {
    const path = parseConnector(' (a) -- (3,4)')
    expect(path!.anchors[1]).toEqual({ kind: 'point', at: { x: 3, y: 4 } })
  })

  it('parses a node border anchor (name.anchor)', () => {
    const path = parseConnector(' (a.north) -- (b.south east)')
    expect(path!.anchors).toEqual([
      { kind: 'node', name: 'a', anchor: 'north' },
      { kind: 'node', name: 'b', anchor: 'south east' },
    ])
  })

  it('parses waypoints', () => {
    const path = parseConnector(' (a) -- (5,5) -- (b)')
    expect(path!.anchors).toHaveLength(3)
    expect(path!.curves).toEqual([null, null])
  })

  it('parses a cubic Bézier segment', () => {
    const path = parseConnector(' (a) .. controls (2,3) and (4,3) .. (b)')
    expect(path!.curves[0]).toEqual({ c1: { x: 2, y: 3 }, c2: { x: 4, y: 3 } })
  })

  it('parses mixed straight and curved segments', () => {
    const path = parseConnector(' (a) -- (m) .. controls (1,1) and (2,2) .. (b)')
    expect(path!.anchors).toHaveLength(3)
    expect(path!.curves[0]).toBeNull()
    expect(path!.curves[1]).toEqual({ c1: { x: 1, y: 1 }, c2: { x: 2, y: 2 } })
  })

  it('returns null for a body outside the editable subset', () => {
    expect(parseConnector(' (a) -| (b)')).toBeNull()
    expect(parseConnector(' (a) to[bend left=30] (b)')).toBeNull()
    expect(parseConnector(' (a)')).toBeNull() // needs at least one segment
    expect(parseConnector(' circle (2)')).toBeNull()
  })
})

describe('serializeConnector', () => {
  const roundTrip = (body: string): string => serializeConnector(parseConnector(body)!)

  it('round-trips a straight connector', () => {
    expect(roundTrip(' (a) -- (b)')).toBe(' (a) -- (b)')
  })

  it('round-trips waypoints and points', () => {
    expect(roundTrip(' (a) -- (5,5) -- (b)')).toBe(' (a) -- (5,5) -- (b)')
  })

  it('round-trips a node border anchor', () => {
    expect(roundTrip(' (a.north) -- (b.south east)')).toBe(' (a.north) -- (b.south east)')
  })

  it('round-trips a cubic segment', () => {
    expect(roundTrip(' (a) .. controls (2,3) and (4,3) .. (b)')).toBe(
      ' (a) .. controls (2,3) and (4,3) .. (b)',
    )
  })

  it('serializes a hand-built curved path', () => {
    const path: ConnectorPath = {
      anchors: [
        { kind: 'node', name: 'x' },
        { kind: 'node', name: 'y' },
      ],
      curves: [{ c1: { x: 1, y: 2 }, c2: { x: 3, y: 4 } }],
    }
    expect(serializeConnector(path)).toBe(' (x) .. controls (1,2) and (3,4) .. (y)')
  })
})
