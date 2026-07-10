/**
 * Storage port over an injected filesystem. Contract: see nativeFsStorageAdapter.md.
 *
 * The native peer of the browser FsStorageAdapter: the editor's working copy over a
 * real directory. API paths are working-copy-relative with POSIX separators; the
 * injected `fs` (an isomorphic-git `FsClient`) maps them onto the OS. The SAME
 * directory backs the git adapter, which is what makes `git.status()` see storage
 * writes.
 *
 * `fs` is injected rather than hard-wired to `node:fs` so the identical, tested code
 * runs in two runtimes: `node:fs` under Node (CLI, tests — see ./node) and a
 * Tauri-fs client inside the desktop webview (which has no Node). `watch` is likewise
 * injected: the Node binding observes EXTERNAL changes via `fs.watch`; a shell with no
 * watcher degrades to no-op, which the port contract permits.
 */
import type { PromiseFsClient } from 'isomorphic-git'
import type { FileEntry, FileEvent, StoragePort, Unsubscribe } from '@slideblaster/editor'
import { errorCode, normalize, posixDirname, posixJoin } from '../paths'

/**
 * A filesystem watcher over one working copy. Given the OS root `dir` and a
 * normalized POSIX `relPath`, it emits debounced create/update/delete events with
 * POSIX-relative paths until unsubscribed. Injected because watching is inherently
 * runtime-specific (Node `fs.watch`, Tauri fs `watch`, ...); see ./node for the Node one.
 */
export type NativeWatch = (
  dir: string,
  relPath: string,
  onEvent: (event: FileEvent) => void,
) => Unsubscribe

export interface NativeFsStorageAdapterOptions {
  /** Working-copy root on the OS filesystem (the same directory the git adapter uses). */
  dir: string
  /** Filesystem binding (isomorphic-git `PromiseFsClient`). See ./node for the `node:fs` one. */
  fs: PromiseFsClient
  /** Optional external-change watcher; omitted -> `watch` is a no-op (best-effort contract). */
  watch?: NativeWatch
}

export class NativeFsStorageAdapter implements StoragePort {
  private readonly dir: string
  private readonly fs: PromiseFsClient['promises']
  private readonly watchImpl: NativeWatch | undefined

  constructor(options: NativeFsStorageAdapterOptions) {
    this.dir = options.dir.replace(/\/+$/, '')
    this.fs = options.fs.promises
    this.watchImpl = options.watch
  }

  /** Absolute OS path for a working-copy-relative path. `/` works on every OS Node/Tauri target. */
  private abs(path: string): string {
    const rel = normalize(path)
    return rel === '' ? this.dir : `${this.dir}/${rel}`
  }

  /** mkdir -p from the (existing) root down; portable across FsClients that lack recursive mkdir. */
  private async ensureDir(relDir: string): Promise<void> {
    let cur = this.dir
    for (const seg of normalize(relDir).split('/').filter(Boolean)) {
      cur = `${cur}/${seg}`
      try {
        await this.fs.mkdir(cur)
      } catch (error) {
        if (errorCode(error) !== 'EEXIST') throw error
      }
    }
  }

  async list(dir: string): Promise<FileEntry[]> {
    const base = normalize(dir)
    const names = (await this.fs.readdir(this.abs(base))) as string[]
    const entries = await Promise.all(
      names.map(async (name): Promise<FileEntry> => {
        const path = posixJoin(base, name)
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
    return new Uint8Array((await this.fs.readFile(this.abs(path))) as Uint8Array)
  }

  async readText(path: string): Promise<string> {
    return new TextDecoder().decode(await this.read(path))
  }

  async write(path: string, data: Uint8Array | string): Promise<void> {
    const rel = normalize(path)
    await this.ensureDir(posixDirname(rel))
    const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data
    await this.fs.writeFile(this.abs(rel), bytes)
  }

  async remove(path: string): Promise<void> {
    const rel = normalize(path)
    const abs = this.abs(rel)
    const stat = await this.fs.stat(abs)
    if (!stat.isDirectory()) {
      await this.fs.unlink(abs)
      return
    }
    // Directories go depth-first so the whole subtree is gone when this resolves.
    for (const entry of await this.list(rel)) await this.remove(entry.path)
    await this.fs.rmdir(abs)
  }

  /**
   * Observe changes under `path`, delegating to the injected watcher. Best-effort per
   * the port contract: with no watcher this is a no-op. The Node binding (./node)
   * debounces and resolves raw events against the live filesystem so a coalesced burst
   * emits a single create/update/delete with a POSIX-relative path, and observes
   * EXTERNAL changes (git, other tools) as well as the adapter's own writes.
   */
  watch(path: string, onEvent: (event: FileEvent) => void): Unsubscribe {
    if (!this.watchImpl) return () => {}
    return this.watchImpl(this.dir, normalize(path), onEvent)
  }
}
