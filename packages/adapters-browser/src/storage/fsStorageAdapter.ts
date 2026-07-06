/**
 * Storage port over a promises-style filesystem. Contract: see fsStorageAdapter.md.
 *
 * The filesystem is injected as the small `PromiseFs` subset that both
 * `LightningFS(...).promises` (browser/IndexedDB) and `node:fs.promises` (tests)
 * satisfy, so one implementation covers both. The same fs instance backs the git
 * adapter, which is what makes `git.status()` see storage writes.
 */
import type { FileEntry, FileEvent, StoragePort, Unsubscribe } from '@slideblaster/editor'

/** The fs.promises subset the adapter needs (LightningFS and node:fs both provide it). */
export interface PromiseFs {
  readFile(path: string): Promise<Uint8Array>
  writeFile(path: string, data: Uint8Array | string): Promise<void>
  unlink(path: string): Promise<void>
  readdir(path: string): Promise<string[]>
  mkdir(path: string): Promise<void>
  rmdir(path: string): Promise<void>
  stat(path: string): Promise<{ size?: number; isDirectory(): boolean }>
}

export interface FsStorageAdapterOptions {
  fs: PromiseFs
  /** Working-copy root inside `fs` (same directory the git adapter operates on). */
  dir: string
}

function errorCode(error: unknown): string | undefined {
  return error && typeof error === 'object' && 'code' in error
    ? String((error as { code: unknown }).code)
    : undefined
}

/** Normalize a working-copy-relative path: POSIX, no leading `./` or `/`, no `..`. */
function normalize(path: string): string {
  const parts = path.split('/').filter((part) => part !== '' && part !== '.')
  if (parts.includes('..')) throw new Error(`path escapes the working copy: ${path}`)
  return parts.join('/')
}

export class FsStorageAdapter implements StoragePort {
  private readonly fs: PromiseFs
  private readonly dir: string
  private readonly watchers = new Set<{ prefix: string; onEvent: (event: FileEvent) => void }>()

  constructor(options: FsStorageAdapterOptions) {
    this.fs = options.fs
    this.dir = options.dir.replace(/\/+$/, '')
  }

  private abs(path: string): string {
    const rel = normalize(path)
    return rel === '' ? this.dir : `${this.dir}/${rel}`
  }

  async list(dir: string): Promise<FileEntry[]> {
    const base = normalize(dir)
    const names = await this.fs.readdir(this.abs(base))
    const entries = await Promise.all(
      names.map(async (name): Promise<FileEntry> => {
        const path = base === '' ? name : `${base}/${name}`
        const stat = await this.fs.stat(this.abs(path))
        return stat.isDirectory() ? { path, type: 'dir' } : { path, type: 'file', size: stat.size }
      }),
    )
    return entries.sort((a, b) =>
      a.type === b.type ? a.path.localeCompare(b.path) : a.type === 'dir' ? -1 : 1,
    )
  }

  async exists(path: string): Promise<boolean> {
    try {
      await this.fs.stat(this.abs(path))
      return true
    } catch (error) {
      if (errorCode(error) === 'ENOENT') return false
      throw error
    }
  }

  async read(path: string): Promise<Uint8Array> {
    const data = await this.fs.readFile(this.abs(path))
    return data instanceof Uint8Array ? data : new Uint8Array(data)
  }

  async readText(path: string): Promise<string> {
    return new TextDecoder().decode(await this.read(path))
  }

  async write(path: string, data: Uint8Array | string): Promise<void> {
    const rel = normalize(path)
    const existed = await this.exists(rel)
    await this.mkdirp(rel.split('/').slice(0, -1))
    const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data
    await this.fs.writeFile(this.abs(rel), bytes)
    this.emit({ kind: existed ? 'update' : 'create', path: rel })
  }

  async remove(path: string): Promise<void> {
    const rel = normalize(path)
    const stat = await this.fs.stat(this.abs(rel))
    if (!stat.isDirectory()) {
      await this.fs.unlink(this.abs(rel))
      this.emit({ kind: 'delete', path: rel })
      return
    }
    // Directories go depth-first; each removed file emits its own delete event.
    for (const entry of await this.list(rel)) await this.remove(entry.path)
    await this.fs.rmdir(this.abs(rel))
  }

  watch(path: string, onEvent: (event: FileEvent) => void): Unsubscribe {
    const watcher = { prefix: normalize(path), onEvent }
    this.watchers.add(watcher)
    return () => this.watchers.delete(watcher)
  }

  /** Create missing intermediate directories (`write` contract), tolerating races. */
  private async mkdirp(segments: string[]): Promise<void> {
    let current = ''
    for (const segment of segments) {
      current = current === '' ? segment : `${current}/${segment}`
      try {
        await this.fs.mkdir(this.abs(current))
      } catch (error) {
        if (errorCode(error) !== 'EEXIST') throw error
      }
    }
  }

  /** In-process change feed: only this adapter's own writes/removes are observed —
   *  best-effort per the port contract (no native watch in IndexedDB filesystems). */
  private emit(event: FileEvent): void {
    for (const { prefix, onEvent } of this.watchers) {
      if (prefix === '' || event.path === prefix || event.path.startsWith(`${prefix}/`)) {
        onEvent(event)
      }
    }
  }
}
