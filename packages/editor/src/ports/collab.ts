/**
 * Collab port — live multiplayer session lifecycle, transport, and awareness.
 * Off for solo editing. Contract: see collab.md.
 */
import type { Unsubscribe } from './common'
import type { Identity, RepoRef, ScopedToken } from './auth'

/** Ephemeral presence channel (cursors, selections, live-drag streaming). */
export interface Awareness {
  setLocalState(state: unknown): void
  getStates(): Map<number, unknown>
  on(event: 'change', callback: () => void): Unsubscribe
}

export type SyncPhase = 'connecting' | 'synced' | 'disconnected'

export interface Session {
  readonly id: string
  readonly awareness: Awareness
  onSync(callback: (phase: SyncPhase) => void): Unsubscribe
  peers(): Identity[]
  leave(): Promise<void>
}

/**
 * Opaque wrapper around the CRDT document (a Yjs `Y.Doc`). The port surface keeps
 * the concrete CRDT type out of the editor core's public contract.
 */
export interface CollabDoc {
  readonly handle: unknown
}

export interface StartSessionOptions {
  doc: CollabDoc
  repo: RepoRef
  /** Free peer-to-peer or premium server-authoritative (ADR 0012). */
  mode: 'p2p' | 'server'
}

export interface JoinOptions {
  sessionId: string
  /** Identity-scoped join token by default; an opt-in link capability otherwise. */
  credential: ScopedToken | { kind: 'link'; value: string }
}

export interface CollabPort {
  startSession(options: StartSessionOptions): Promise<Session>
  join(options: JoinOptions): Promise<Session>
}
