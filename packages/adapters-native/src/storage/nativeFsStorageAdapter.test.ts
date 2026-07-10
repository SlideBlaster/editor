import { afterEach, describe, expect, it } from 'vitest'
import { promises as fsp } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { FileEvent, Unsubscribe } from '@slideblaster/editor'
import { NativeFsStorageAdapter } from './nativeFsStorageAdapter'
import { nodeFs, nodeWatch } from '../node'

// Every test runs against a real, unique temp dir; dirs and any open watchers are
// torn down in afterEach so the process does not hang on inotify handles.
const dirs: string[] = []
const cleanups: Unsubscribe[] = []

async function makeAdapter(): Promise<NativeFsStorageAdapter> {
  const dir = await mkdtemp(join(tmpdir(), 'sb-native-storage-'))
  dirs.push(dir)
  return new NativeFsStorageAdapter({ dir, fs: nodeFs, watch: nodeWatch })
}

function track(unsubscribe: Unsubscribe): Unsubscribe {
  cleanups.push(unsubscribe)
  return unsubscribe
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function waitFor(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const start = Date.now()
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) throw new Error('waitFor timed out')
    await delay(10)
  }
}

afterEach(async () => {
  while (cleanups.length) cleanups.pop()!()
  while (dirs.length) await rm(dirs.pop()!, { recursive: true, force: true })
})

describe('NativeFsStorageAdapter', () => {
  it('writes and reads text and bytes', async () => {
    const storage = await makeAdapter()
    await storage.write('deck.slideBlaster.md', '# hello\n')
    expect(await storage.readText('deck.slideBlaster.md')).toBe('# hello\n')

    const bytes = new Uint8Array([1, 2, 3])
    await storage.write('assets/logo.bin', bytes)
    expect(Array.from(await storage.read('assets/logo.bin'))).toEqual([1, 2, 3])
  })

  it('creates intermediate directories on write', async () => {
    const storage = await makeAdapter()
    await storage.write('a/b/c.md', 'deep')
    expect(await storage.exists('a/b/c.md')).toBe(true)
    expect(await storage.list('a')).toEqual([{ path: 'a/b', type: 'dir' }])
  })

  it('lists one level, directories before files, with sizes', async () => {
    const storage = await makeAdapter()
    await storage.write('z.md', 'zz')
    await storage.write('sub/inner.md', 'x')
    const entries = await storage.list('')
    expect(entries).toEqual([
      { path: 'sub', type: 'dir' },
      { path: 'z.md', type: 'file', size: 2 },
    ])
  })

  it('exists distinguishes present, absent, and directories', async () => {
    const storage = await makeAdapter()
    await storage.write('dir/file.md', 'x')
    expect(await storage.exists('dir')).toBe(true)
    expect(await storage.exists('dir/file.md')).toBe(true)
    expect(await storage.exists('missing.md')).toBe(false)
  })

  it('removes files and directory subtrees', async () => {
    const storage = await makeAdapter()
    await storage.write('keep.md', 'k')
    await storage.write('gone/a.md', 'a')
    await storage.write('gone/deep/b.md', 'b')
    await storage.remove('gone')
    expect(await storage.exists('gone')).toBe(false)
    expect(await storage.exists('keep.md')).toBe(true)
  })

  it('rejects paths escaping the working copy', async () => {
    const storage = await makeAdapter()
    await expect(storage.read('../outside.md')).rejects.toThrow(/escapes/)
  })

  it('watch observes an EXTERNAL create and stops after unsubscribe', async () => {
    const storage = await makeAdapter()
    const [dir] = dirs.slice(-1)
    const events: FileEvent[] = []
    const unsubscribe = track(storage.watch('', (event) => events.push(event)))
    await delay(50) // let the OS watcher register before mutating behind the adapter

    // External write, straight to disk, bypassing the adapter entirely.
    await fsp.writeFile(join(dir!, 'external.md'), 'hi')
    await waitFor(() => events.some((e) => e.kind === 'create' && e.path === 'external.md'))

    unsubscribe()
    const settled = events.length
    await fsp.writeFile(join(dir!, 'after.md'), 'x')
    await delay(80)
    expect(events.length).toBe(settled) // nothing arrives once unsubscribed
  })

  it('watch reports update then delete for a pre-existing file with a nested POSIX path', async () => {
    const storage = await makeAdapter()
    const [dir] = dirs.slice(-1)
    await storage.write('sub/pre.md', 'v1') // exists before the watch: seeds "known"

    const events: FileEvent[] = []
    track(storage.watch('', (event) => events.push(event)))
    await delay(50)

    await fsp.writeFile(join(dir!, 'sub', 'pre.md'), 'v2') // external modify
    await waitFor(() => events.some((e) => e.kind === 'update' && e.path === 'sub/pre.md'))

    await fsp.rm(join(dir!, 'sub', 'pre.md')) // external delete
    await waitFor(() => events.some((e) => e.kind === 'delete' && e.path === 'sub/pre.md'))
  })
})
