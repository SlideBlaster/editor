import { describe, expect, it } from 'vitest'
import { promises as fsp } from 'node:fs'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { FileEvent } from '@slideblaster/editor'
import { FsStorageAdapter, type PromiseFs } from './fsStorageAdapter'

function makeAdapter(): FsStorageAdapter {
  const dir = mkdtempSync(join(tmpdir(), 'sb-storage-'))
  return new FsStorageAdapter({ fs: fsp as unknown as PromiseFs, dir })
}

describe('FsStorageAdapter', () => {
  it('writes and reads text and bytes', async () => {
    const storage = makeAdapter()
    await storage.write('deck.slideBlaster.md', '# hello\n')
    expect(await storage.readText('deck.slideBlaster.md')).toBe('# hello\n')

    const bytes = new Uint8Array([1, 2, 3])
    await storage.write('assets/logo.bin', bytes)
    expect(Array.from(await storage.read('assets/logo.bin'))).toEqual([1, 2, 3])
  })

  it('creates intermediate directories on write', async () => {
    const storage = makeAdapter()
    await storage.write('a/b/c.md', 'deep')
    expect(await storage.exists('a/b/c.md')).toBe(true)
    expect(await storage.list('a')).toEqual([{ path: 'a/b', type: 'dir' }])
  })

  it('lists one level, directories before files, with sizes', async () => {
    const storage = makeAdapter()
    await storage.write('z.md', 'zz')
    await storage.write('sub/inner.md', 'x')
    const entries = await storage.list('')
    expect(entries).toEqual([
      { path: 'sub', type: 'dir' },
      { path: 'z.md', type: 'file', size: 2 },
    ])
  })

  it('exists distinguishes present, absent, and directories', async () => {
    const storage = makeAdapter()
    await storage.write('dir/file.md', 'x')
    expect(await storage.exists('dir')).toBe(true)
    expect(await storage.exists('dir/file.md')).toBe(true)
    expect(await storage.exists('missing.md')).toBe(false)
  })

  it('removes files and directory subtrees', async () => {
    const storage = makeAdapter()
    await storage.write('keep.md', 'k')
    await storage.write('gone/a.md', 'a')
    await storage.write('gone/deep/b.md', 'b')
    await storage.remove('gone')
    expect(await storage.exists('gone')).toBe(false)
    expect(await storage.exists('keep.md')).toBe(true)
  })

  it('rejects paths escaping the working copy', async () => {
    const storage = makeAdapter()
    await expect(storage.read('../outside.md')).rejects.toThrow(/escapes/)
  })

  it('watch reports create/update/delete under a prefix and unsubscribes', async () => {
    const storage = makeAdapter()
    const events: FileEvent[] = []
    const unsubscribe = storage.watch('docs', (event) => events.push(event))

    await storage.write('docs/a.md', 'v1') // create
    await storage.write('docs/a.md', 'v2') // update
    await storage.write('elsewhere.md', 'x') // outside the prefix: not reported
    await storage.remove('docs/a.md') // delete

    expect(events).toEqual([
      { kind: 'create', path: 'docs/a.md' },
      { kind: 'update', path: 'docs/a.md' },
      { kind: 'delete', path: 'docs/a.md' },
    ])

    unsubscribe()
    await storage.write('docs/b.md', 'x')
    expect(events).toHaveLength(3)
  })
})
