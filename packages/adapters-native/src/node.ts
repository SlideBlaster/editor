/**
 * Node bindings for the native adapters. Contract: see node.md.
 *
 * This is the ONLY file in the package that imports `node:*`. It supplies the three
 * runtime-specific pieces the runtime-agnostic adapters need under Node: the
 * `node:fs` FsClient, isomorphic-git's node HTTP client, and an `fs.watch`-based
 * watcher; plus `createNodeWorkspace`, which wires them into `createNativeWorkspace`.
 *
 * The desktop webview must NOT import this file (it has no Node runtime); it injects a
 * Tauri-fs client into `createNativeWorkspace` instead. Keeping every `node:*` import
 * here is what lets the adapter classes bundle into that webview.
 */
import * as nodeFsModule from 'node:fs'
import type { FSWatcher } from 'node:fs'
import { join, sep } from 'node:path'
import nodeHttpClient from 'isomorphic-git/http/node'
import type { HttpClient, PromiseFsClient } from 'isomorphic-git'
import type { FileEvent } from '@slideblaster/editor'
import { errorCode, posixJoin } from './paths'
import { createNativeWorkspace, type NativeWorkspace } from './workspace'
import type { NativeWatch } from './storage/nativeFsStorageAdapter'

const { readdirSync, statSync, watch: fsWatch, promises: fsp } = nodeFsModule

/** The `node:fs` binding as an isomorphic-git PromiseFsClient (has `.promises`). */
export const nodeFs = nodeFsModule as unknown as PromiseFsClient

/** isomorphic-git's Node HTTP client, for remote git over Node. */
export const nodeHttp: HttpClient = nodeHttpClient

/** Debounce window that coalesces the burst of raw watch events one change produces. */
const WATCH_DEBOUNCE_MS = 20

/** OS-separated fragment (as emitted by `fs.watch`) to a POSIX working-copy path. */
function toPosix(fragment: string): string {
  return fragment.split(sep).join('/')
}

function isDirectorySync(path: string): boolean {
  try {
    return statSync(path).isDirectory()
  } catch {
    // A not-yet-existing target is watched as a directory (require a child name).
    return true
  }
}

/**
 * `node:fs`-based external-change watcher (the `NativeWatch` the storage adapter
 * delegates to under Node). Recursive where the platform supports it, else one
 * directory level; raw events are debounced and resolved against the live filesystem
 * so a coalesced burst emits a single create/update/delete with a POSIX-relative path.
 * A seeded snapshot distinguishes a first create from an update and enables delete
 * detection for files that predate the subscription.
 */
export const nodeWatch: NativeWatch = (dir, rel, onEvent) => {
  const abs = (r: string): string => (r === '' ? dir : join(dir, ...r.split('/')))
  const target = abs(rel)
  const watchingDir = isDirectorySync(target)
  const known = new Set<string>()

  const seedKnown = (r: string): void => {
    let names: string[]
    try {
      names = readdirSync(abs(r))
    } catch {
      return
    }
    for (const name of names) {
      const childRel = posixJoin(r, name)
      let stat
      try {
        stat = statSync(abs(childRel))
      } catch {
        continue
      }
      if (stat.isDirectory()) seedKnown(childRel)
      else known.add(childRel)
    }
  }
  seedKnown(rel)

  let closed = false
  const timers = new Map<string, ReturnType<typeof setTimeout>>()

  const resolve = async (relPath: string): Promise<void> => {
    let present = false
    let isDir = false
    try {
      const stat = await fsp.stat(abs(relPath))
      present = true
      isDir = stat.isDirectory()
    } catch (error) {
      if (errorCode(error) !== 'ENOENT') return
    }
    if (closed) return
    if (present) {
      if (isDir) return // directories are not reported as file events
      const kind: FileEvent['kind'] = known.has(relPath) ? 'update' : 'create'
      known.add(relPath)
      onEvent({ kind, path: relPath })
    } else if (known.delete(relPath)) {
      onEvent({ kind: 'delete', path: relPath })
    }
  }

  const schedule = (relPath: string): void => {
    const existing = timers.get(relPath)
    if (existing !== undefined) clearTimeout(existing)
    timers.set(
      relPath,
      setTimeout(() => {
        timers.delete(relPath)
        void resolve(relPath)
      }, WATCH_DEBOUNCE_MS),
    )
  }

  const onRaw = (_eventType: string, filename: string | null): void => {
    const relPath = watchingDir
      ? filename === null
        ? null
        : posixJoin(rel, toPosix(filename))
      : rel
    if (relPath === null) return
    schedule(relPath)
  }

  let watcher: FSWatcher
  try {
    watcher = fsWatch(target, { recursive: true }, onRaw)
  } catch {
    // Recursive watch is unavailable on some platforms; fall back to one level.
    watcher = fsWatch(target, onRaw)
  }
  watcher.on('error', () => {
    // Best-effort: a watch error (e.g. the target was removed) ends the feed.
  })

  return () => {
    closed = true
    for (const timer of timers.values()) clearTimeout(timer)
    timers.clear()
    watcher.close()
  }
}

/**
 * Convenience wiring for a Node working copy: `createNativeWorkspace` bound to the
 * `node:fs` client, the node HTTP client, and the `fs.watch` watcher. The CLI and the
 * tests use this; the desktop webview builds its own Tauri-fs equivalent.
 */
export function createNodeWorkspace(dir: string): Promise<NativeWorkspace> {
  return createNativeWorkspace({ dir, fs: nodeFs, watch: nodeWatch, http: nodeHttp })
}
