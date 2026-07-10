import { describe, expect, it } from 'vitest'
import { zipSync, unzipSync } from 'fflate'
import type { FileEntry, StoragePort, Unsubscribe } from '@slideblaster/editor'
import { exportWorkspaceZip, importWorkspaceZip, sanitizeZipEntryPath } from './workspaceZip'

/**
 * A minimal in-memory StoragePort: files in a flat map keyed by working-copy-relative
 * POSIX path, with directories synthesized on `list` (matching the real adapters, whose
 * `list` entries carry the full path). Enough to exercise the zip codec's port use.
 */
class MemStorage implements StoragePort {
  private readonly files = new Map<string, Uint8Array>()

  private static norm(dir: string): string {
    return dir === '.' ? '' : dir.replace(/\/+$/, '')
  }

  list(dir: string): Promise<FileEntry[]> {
    const base = MemStorage.norm(dir)
    const prefix = base === '' ? '' : `${base}/`
    const fileNames = new Set<string>()
    const dirNames = new Set<string>()
    for (const path of this.files.keys()) {
      if (prefix && !path.startsWith(prefix)) continue
      const rest = path.slice(prefix.length)
      const slash = rest.indexOf('/')
      if (slash === -1) fileNames.add(rest)
      else dirNames.add(rest.slice(0, slash))
    }
    const entries: FileEntry[] = []
    for (const name of dirNames) entries.push({ path: `${prefix}${name}`, type: 'dir' })
    for (const name of fileNames)
      entries.push({
        path: `${prefix}${name}`,
        type: 'file',
        size: this.files.get(`${prefix}${name}`)!.length,
      })
    return Promise.resolve(entries)
  }

  exists(path: string): Promise<boolean> {
    if (this.files.has(path)) return Promise.resolve(true)
    const prefix = `${path}/`
    for (const key of this.files.keys()) if (key.startsWith(prefix)) return Promise.resolve(true)
    return Promise.resolve(false)
  }

  read(path: string): Promise<Uint8Array> {
    const data = this.files.get(path)
    if (!data) return Promise.reject(new Error(`no such file: ${path}`))
    return Promise.resolve(data)
  }

  readText(path: string): Promise<string> {
    return this.read(path).then((bytes) => new TextDecoder().decode(bytes))
  }

  write(path: string, data: Uint8Array | string): Promise<void> {
    this.files.set(path, typeof data === 'string' ? new TextEncoder().encode(data) : data)
    return Promise.resolve()
  }

  remove(path: string): Promise<void> {
    this.files.delete(path)
    const prefix = `${path}/`
    for (const key of [...this.files.keys()]) if (key.startsWith(prefix)) this.files.delete(key)
    return Promise.resolve()
  }

  watch(): Unsubscribe {
    return () => {}
  }
}

/** Every file path in a storage, recursive, sorted — for asserting the tree shape. */
async function allFiles(storage: StoragePort): Promise<string[]> {
  const out: string[] = []
  const walk = async (dir: string): Promise<void> => {
    for (const entry of await storage.list(dir)) {
      if (entry.type === 'dir') await walk(entry.path)
      else out.push(entry.path)
    }
  }
  await walk('')
  return out.sort()
}

const enc = (text: string): Uint8Array => new TextEncoder().encode(text)

// A nested working copy: a deck, a standalone figure, a theme file, a binary asset, and
// the bibliography — one of each kind the working copy holds.
const DECK = ['---', 'title: Demo', 'bibliography: refs.bib', '---', '', '## S1 {#s1}'].join('\n')
const TIKZ = '\\node (a) at (8,4.5) {Hello};\n'
const THEME = '{"id":"corp","style":{}}'
const BIB = '@book{k, title={T}}\n'
// Non-UTF8 bytes (a PNG signature + arbitrary high bytes) so binary safety is exercised.
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x01, 0xff, 0xfe])

async function seedWorkingCopy(storage: MemStorage): Promise<void> {
  await storage.write('talks/demo.slideBlaster.md', DECK)
  await storage.write('figures/tree.tikz', TIKZ)
  await storage.write('themes/corp/theme.json', THEME)
  await storage.write('assets/logo.png', PNG)
  await storage.write('refs.bib', BIB)
  await storage.write('notes/todo.md', 'a plain note\n')
}

describe('workspace zip round-trip', () => {
  it('exports a nested tree and imports it back byte-identically', async () => {
    const source = new MemStorage()
    await seedWorkingCopy(source)
    const before = await allFiles(source)

    const zip = await exportWorkspaceZip(source)

    // Wipe: import into a fresh, empty working copy.
    const target = new MemStorage()
    await importWorkspaceZip(target, zip)

    // Identical paths…
    expect(await allFiles(target)).toEqual(before)
    // …and identical bytes for every file (text and binary).
    for (const path of before) {
      expect(await target.read(path)).toEqual(await source.read(path))
    }
    // The binary asset survived unchanged (not UTF-8 mangled).
    expect(await target.read('assets/logo.png')).toEqual(PNG)
  })

  it('produces a deterministic archive for a given tree', async () => {
    const a = new MemStorage()
    const b = new MemStorage()
    await seedWorkingCopy(a)
    await seedWorkingCopy(b)
    expect(await exportWorkspaceZip(a)).toEqual(await exportWorkspaceZip(b))
  })
})

describe('workspace zip skips .git', () => {
  it('never packs .git internals on export', async () => {
    const source = new MemStorage()
    await source.write('deck.slideBlaster.md', 'x')
    await source.write('.gitignore', 'node_modules\n') // a real file, must travel
    await source.write('.git/HEAD', 'ref: refs/heads/main')
    await source.write('.git/config', '[core]\n')

    const entries = Object.keys(unzipSync(await exportWorkspaceZip(source)))
    expect(entries).toContain('deck.slideBlaster.md')
    expect(entries).toContain('.gitignore')
    expect(entries.some((name) => name === '.git' || name.startsWith('.git/'))).toBe(false)
  })

  it('never writes .git internals on import', async () => {
    const zip = zipSync({ 'deck.slideBlaster.md': enc('x'), '.git/config': enc('[core]\n') })
    const target = new MemStorage()
    const skipped: Array<[string, string]> = []
    await importWorkspaceZip(target, zip, {
      onSkip: (name, reason) => skipped.push([name, reason]),
    })

    expect(await target.exists('deck.slideBlaster.md')).toBe(true)
    expect(await target.exists('.git/config')).toBe(false)
    expect(skipped).toContainEqual(['.git/config', 'git-internal'])
  })
})

describe('workspace zip refuses zip-slip', () => {
  it('skips traversal/absolute entries and writes nothing outside the root', async () => {
    const zip = zipSync({
      'safe.md': enc('ok'),
      '../evil.txt': enc('pwned'),
      '/abs.txt': enc('pwned'),
      'a/../../escape.txt': enc('pwned'),
    })
    const target = new MemStorage()
    const skipped: string[] = []
    await importWorkspaceZip(target, zip, { onSkip: (name) => skipped.push(name) })

    // Only the safe entry landed.
    expect(await allFiles(target)).toEqual(['safe.md'])
    // Nothing escaped the root.
    for (const path of await allFiles(target)) {
      expect(path.startsWith('/')).toBe(false)
      expect(path.split('/')).not.toContain('..')
    }
    expect(skipped).toEqual(
      expect.arrayContaining(['../evil.txt', '/abs.txt', 'a/../../escape.txt']),
    )
  })
})

describe('sanitizeZipEntryPath', () => {
  it('accepts and normalizes safe relative paths', () => {
    expect(sanitizeZipEntryPath('a/b/c.md')).toBe('a/b/c.md')
    expect(sanitizeZipEntryPath('./a/./b.md')).toBe('a/b.md')
    expect(sanitizeZipEntryPath('a//b.md')).toBe('a/b.md')
    expect(sanitizeZipEntryPath('a\\b\\c.md')).toBe('a/b/c.md') // Windows separators
    expect(sanitizeZipEntryPath('.gitignore')).toBe('.gitignore') // not a .git segment
  })

  it('refuses traversal, absolute, and empty entries', () => {
    expect(sanitizeZipEntryPath('../evil')).toBeNull()
    expect(sanitizeZipEntryPath('a/../../evil')).toBeNull()
    expect(sanitizeZipEntryPath('a/..')).toBeNull()
    expect(sanitizeZipEntryPath('/etc/passwd')).toBeNull()
    expect(sanitizeZipEntryPath('C:\\Windows\\x')).toBeNull()
    expect(sanitizeZipEntryPath('')).toBeNull()
    expect(sanitizeZipEntryPath('.')).toBeNull()
  })
})
