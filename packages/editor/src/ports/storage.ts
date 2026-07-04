/**
 * Storage port — the editor's working copy of files and assets.
 * Contract: see storage.md.
 */
import type { Unsubscribe } from './common'

export interface FileEntry {
  /** Path relative to the working-copy root, POSIX separators. */
  path: string
  type: 'file' | 'dir'
  /** Byte size for files; omitted for directories. */
  size?: number
}

export type FileEventKind = 'create' | 'update' | 'delete'

export interface FileEvent {
  kind: FileEventKind
  path: string
}

export interface StoragePort {
  /** Entries directly under `dir` (non-recursive). Root is `''` or `'.'`. */
  list(dir: string): Promise<FileEntry[]>
  exists(path: string): Promise<boolean>
  read(path: string): Promise<Uint8Array>
  readText(path: string): Promise<string>
  write(path: string, data: Uint8Array | string): Promise<void>
  remove(path: string): Promise<void>
  /** Observe changes under `path` (a file or a directory subtree). */
  watch(path: string, onEvent: (event: FileEvent) => void): Unsubscribe
}
