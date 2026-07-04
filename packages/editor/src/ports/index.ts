/**
 * The six ports the editor core depends on. Contract: see index.md.
 */
export type { Unsubscribe } from './common'
export type { StoragePort, FileEntry, FileEvent, FileEventKind } from './storage'
export type {
  GitPort,
  Oid,
  Author,
  FileStatus,
  GitStatus,
  Commit,
  RemoteRef,
  SyncResult,
  IndexState,
  WorktreeState,
} from './git'
export type { AuthPort, RepoRef, ScopedToken, Identity, CapabilityFlags } from './auth'
export type {
  CollabPort,
  Awareness,
  Session,
  SyncPhase,
  CollabDoc,
  StartSessionOptions,
  JoinOptions,
} from './collab'
export type { CompilePort, CompileKind } from './compile'
export type { ExportPort, RenderedSlide } from './export'
