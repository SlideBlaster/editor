import { describe, expect, it } from 'vitest'
import { createProjectRegistry, type StorageLike } from './projects'

/** An in-memory Storage stand-in (tests run in node — no localStorage). */
function memoryStore(): StorageLike {
  const map = new Map<string, string>()
  return {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => void map.set(k, v),
    removeItem: (k) => void map.delete(k),
  }
}

describe('project registry', () => {
  it('starts empty and creates projects with distinct ids', () => {
    const reg = createProjectRegistry(memoryStore())
    expect(reg.list()).toEqual([])

    const a = reg.create('Talk A')
    const b = reg.create('Talk B')
    expect(a.id).not.toBe(b.id)
    expect(a.name).toBe('Talk A')
    expect(reg.list()).toHaveLength(2)
    expect(reg.get(a.id)?.name).toBe('Talk A')
  })

  it('blank names fall back to a default', () => {
    const reg = createProjectRegistry(memoryStore())
    expect(reg.create('   ').name).toBe('Untitled project')
  })

  it('lists most-recently-opened first; touch reorders', () => {
    const reg = createProjectRegistry(memoryStore())
    const a = reg.create('A')
    const b = reg.create('B')
    // b was created last, so it leads.
    expect(reg.list().map((p) => p.id)).toEqual([b.id, a.id])
    reg.touch(a.id)
    expect(reg.list()[0]?.id).toBe(a.id)
  })

  it('remove drops only the named project; persists across instances', () => {
    const store = memoryStore()
    const reg = createProjectRegistry(store)
    const a = reg.create('A')
    const b = reg.create('B')
    reg.remove(a.id)

    // A fresh registry over the same store sees the persisted state.
    const reopened = createProjectRegistry(store)
    expect(reopened.list().map((p) => p.id)).toEqual([b.id])
    expect(reopened.get(a.id)).toBeNull()
  })

  it('tolerates malformed stored data', () => {
    const store = memoryStore()
    store.setItem('slideblaster.projects', '{ not an array')
    const reg = createProjectRegistry(store)
    expect(reg.list()).toEqual([])
    expect(reg.create('ok').name).toBe('ok')
  })
})
