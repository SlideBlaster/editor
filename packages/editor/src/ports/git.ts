/**
 * Git port — durability, history, and sync for the working copy.
 * Contract: see git.md.
 */
import type { ScopedToken } from './auth'

export type Oid = string

export interface Author {
  name: string
  email: string
}

export type IndexState = 'unmodified' | 'added' | 'modified' | 'deleted'
export type WorktreeState = IndexState | 'untracked'

export interface FileStatus {
  path: string
  index: IndexState
  worktree: WorktreeState
}

export interface GitStatus {
  branch: string
  /** Commits ahead of / behind the tracked remote branch. */
  ahead: number
  behind: number
  files: FileStatus[]
}

export interface Commit {
  oid: Oid
  message: string
  author: Author
  /** Epoch milliseconds. */
  timestamp: number
  parents: Oid[]
}

/** A remote plus the credential to reach it. */
export interface RemoteRef {
  url: string
  token: ScopedToken
}

export interface SyncResult {
  oid: Oid
  /** True if the update was a clean fast-forward (no merge needed). */
  fastForward: boolean
  /** Paths with merge conflicts; empty on a clean sync. */
  conflicts: string[]
}

export interface GitPort {
  /** Create an empty local repository at `dir` (no remote; offline-first M3). */
  init(dir: string): Promise<void>
  clone(remote: RemoteRef, dir: string): Promise<void>
  status(): Promise<GitStatus>
  stage(paths: string[]): Promise<void>
  commit(message: string, author: Author): Promise<Oid>
  log(options?: { depth?: number; ref?: string }): Promise<Commit[]>
  currentBranch(): Promise<string>
  checkout(ref: string): Promise<void>
  createBranch(name: string): Promise<void>
  merge(theirs: string): Promise<{ oid: Oid; conflicts: string[] }>
  pull(remote: RemoteRef): Promise<SyncResult>
  push(remote: RemoteRef): Promise<SyncResult>
}
