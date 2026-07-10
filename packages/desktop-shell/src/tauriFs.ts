/**
 * Tauri-fs binding for the native adapters. Contract: see tauriFs.md.
 *
 * Supplies the runtime-specific pieces `createNativeWorkspace` needs INSIDE the
 * desktop webview (which has no Node): a `PromiseFsClient` and a `NativeWatch`, both
 * over `@tauri-apps/plugin-fs`. This is the desktop peer of adapters-native/node.ts —
 * the SAME tested storage + git logic runs on top of it. Paths are absolute OS paths
 * (from the folder picker); no `baseDir` is used.
 *
 * VERIFICATION: unlike node.ts this CANNOT be exercised headlessly — plugin-fs only
 * works inside a running Tauri webview. It is checked by typechecking against the
 * plugin's types; runtime behaviour must be validated on a Tauri-toolchain machine.
 */
import {
  exists as fsExists,
  lstat as fsLstat,
  mkdir as fsMkdir,
  readDir as fsReadDir,
  readFile as fsReadFile,
  remove as fsRemove,
  stat as fsStat,
  watchImmediate,
  writeFile as fsWriteFile,
  type FileInfo,
  type UnwatchFn,
  type WatchEvent,
} from '@tauri-apps/plugin-fs'
import type { NativeWatch, PromiseFsClient } from '@slideblaster/adapters-native'
import type { FileEvent } from '@slideblaster/editor'

/** A Node-style filesystem error carrying a `code` the adapters branch on (ENOENT/EEXIST). */
function fsError(code: string, message: string): Error {
  return Object.assign(new Error(message), { code })
}

/** Map a Tauri `FileInfo` onto the stat shape isomorphic-git expects (methods + fields). */
function toStat(info: FileInfo): object {
  const mtimeMs = info.mtime ? info.mtime.getTime() : 0
  return {
    type: info.isDirectory ? 'dir' : info.isSymlink ? 'symlink' : 'file',
    mode: info.mode ?? (info.isDirectory ? 0o40000 : 0o100644),
    size: info.size,
    ino: info.ino ?? 0,
    mtimeMs,
    ctimeMs: mtimeMs,
    birthtimeMs: info.birthtime ? info.birthtime.getTime() : mtimeMs,
    uid: info.uid ?? 1,
    gid: info.gid ?? 1,
    dev: info.dev ?? 1,
    isFile: () => info.isFile,
    isDirectory: () => info.isDirectory,
    isSymbolicLink: () => info.isSymlink,
  }
}

/**
 * PromiseFsClient over the Tauri fs plugin. plugin-fs has no `unlink`/`rmdir`; both map
 * to `remove` (a non-recursive `remove` deletes a file or an empty dir, matching the
 * isomorphic-git contract). `stat`/`mkdir` translate plugin errors into the ENOENT/EEXIST
 * codes the storage adapter and isomorphic-git test against.
 */
export const tauriFs = {
  promises: {
    async readFile(
      path: string,
      options?: { encoding?: string } | string,
    ): Promise<Uint8Array | string> {
      const bytes = await fsReadFile(path)
      const encoding = typeof options === 'string' ? options : options?.encoding
      return encoding ? new TextDecoder().decode(bytes) : bytes
    },
    async writeFile(path: string, data: Uint8Array | string): Promise<void> {
      await fsWriteFile(path, typeof data === 'string' ? new TextEncoder().encode(data) : data)
    },
    async unlink(path: string): Promise<void> {
      await fsRemove(path)
    },
    async readdir(path: string): Promise<string[]> {
      return (await fsReadDir(path)).map((entry) => entry.name)
    },
    async mkdir(path: string): Promise<void> {
      try {
        await fsMkdir(path)
      } catch (err) {
        if (await fsExists(path)) throw fsError('EEXIST', `exists: ${path}`)
        throw err
      }
    },
    async rmdir(path: string): Promise<void> {
      await fsRemove(path)
    },
    async stat(path: string): Promise<object> {
      try {
        return toStat(await fsStat(path))
      } catch (err) {
        if (!(await fsExists(path))) throw fsError('ENOENT', `no such file: ${path}`)
        throw err
      }
    },
    async lstat(path: string): Promise<object> {
      try {
        return toStat(await fsLstat(path))
      } catch (err) {
        if (!(await fsExists(path))) throw fsError('ENOENT', `no such file: ${path}`)
        throw err
      }
    },
    async readlink(path: string): Promise<string> {
      // Symlinks are outside the SlideBlaster working-copy model; report unsupported.
      throw fsError('EINVAL', `readlink unsupported: ${path}`)
    },
    async symlink(): Promise<void> {
      throw fsError('EINVAL', 'symlink unsupported')
    },
  },
} as unknown as PromiseFsClient

/** Map a plugin-fs watch event kind to our create/update/delete (ignore access/other). */
function mapKind(type: WatchEvent['type']): FileEvent['kind'] | null {
  if (type === 'any' || type === 'other') return null
  if ('create' in type) return 'create'
  if ('modify' in type) return 'update'
  if ('remove' in type) return 'delete'
  return null
}

/**
 * `NativeWatch` over plugin-fs `watchImmediate`. plugin-fs resolves the watcher
 * asynchronously while `NativeWatch` returns synchronously, so the returned
 * unsubscribe stops the watcher whenever it eventually attaches. Best-effort per the
 * port contract: paths outside the working copy and access-only events are ignored.
 */
export const tauriWatch: NativeWatch = (dir, rel, onEvent) => {
  const root = dir.replace(/\/+$/, '')
  const target = rel === '' ? root : `${root}/${rel}`
  let unwatch: UnwatchFn | undefined
  let stopped = false

  const toRel = (abs: string): string | null => {
    const norm = abs.replace(/\\/g, '/')
    if (norm === root) return null
    const prefix = `${root}/`
    return norm.startsWith(prefix) ? norm.slice(prefix.length) : null
  }

  void watchImmediate(
    target,
    (event) => {
      const kind = mapKind(event.type)
      if (!kind) return
      for (const abs of event.paths) {
        const relPath = toRel(abs)
        if (relPath !== null) onEvent({ kind, path: relPath })
      }
    },
    { recursive: true },
  )
    .then((fn) => {
      if (stopped) fn()
      else unwatch = fn
    })
    .catch(() => {
      /* best-effort: watching is optional per the port contract */
    })

  return () => {
    stopped = true
    unwatch?.()
  }
}
