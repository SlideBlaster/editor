/**
 * Auth port — identity and short-lived, repo-scoped credentials.
 * Contract: see auth.md.
 */

export interface RepoRef {
  owner: string
  name: string
}

/**
 * A short-lived, single-repo, contents-scoped credential minted by the Auth
 * service (ADR 0010). Held in memory only; never persisted to disk or storage.
 */
export interface ScopedToken {
  value: string
  repo: RepoRef
  scope: 'contents:read' | 'contents:write'
  /** Epoch milliseconds. Callers must treat an expired token as unusable. */
  expiresAt: number
}

export interface Identity {
  login: string
  id: string
  avatarUrl?: string
}

/** Server-issued capability flags gating premium features (ADR 0010/0012). */
export interface CapabilityFlags {
  premiumCollab: boolean
  managedStorage: boolean
  /** Owner-pays collaborator seat cap; 0 for the free tier. */
  collaboratorSeats: number
}

export interface AuthPort {
  signIn(): Promise<Identity>
  signOut(): Promise<void>
  currentIdentity(): Identity | null
  /**
   * Return a valid repo-scoped token, minting a fresh one (or reusing a cached,
   * unexpired one) as needed. Defaults to `contents:write`.
   */
  getRepoToken(repo: RepoRef, scope?: ScopedToken['scope']): Promise<ScopedToken>
  capabilities(): Promise<CapabilityFlags>
}
