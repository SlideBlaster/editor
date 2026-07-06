/**
 * Development Auth adapter. Contract: see devAuthAdapter.md.
 *
 * Lets the app be written against the real AuthPort before the Auth service
 * exists (M4): identity is local and instant, tokens come from an optionally
 * injected PAT (for manual remote testing) or fail with a clear message.
 */
import type {
  AuthPort,
  CapabilityFlags,
  Identity,
  RepoRef,
  ScopedToken,
} from '@slideblaster/editor'

export interface DevAuthOptions {
  /** Login to sign in as (default "dev"). */
  login?: string
  /** Optional PAT enabling getRepoToken for manual remote testing. Never shipped. */
  tokenValue?: string
}

const STORAGE_KEY = 'slideblaster.dev-identity'
const TOKEN_TTL_MS = 3_600_000

/** localStorage when available (browser), else an in-memory map (tests/SSR). */
function identityStore(): Pick<Storage, 'getItem' | 'setItem' | 'removeItem'> {
  if (typeof localStorage !== 'undefined') return localStorage
  const memory = new Map<string, string>()
  return {
    getItem: (key) => memory.get(key) ?? null,
    setItem: (key, value) => void memory.set(key, value),
    removeItem: (key) => void memory.delete(key),
  }
}

export class DevAuthAdapter implements AuthPort {
  private readonly login: string
  private readonly tokenValue: string | undefined
  private readonly store = identityStore()

  constructor(options: DevAuthOptions = {}) {
    this.login = options.login ?? 'dev'
    this.tokenValue = options.tokenValue
  }

  async signIn(): Promise<Identity> {
    const identity: Identity = { login: this.login, id: `dev:${this.login}` }
    this.store.setItem(STORAGE_KEY, JSON.stringify(identity))
    return identity
  }

  async signOut(): Promise<void> {
    this.store.removeItem(STORAGE_KEY)
  }

  currentIdentity(): Identity | null {
    const raw = this.store.getItem(STORAGE_KEY)
    if (!raw) return null
    try {
      return JSON.parse(raw) as Identity
    } catch {
      return null
    }
  }

  async getRepoToken(repo: RepoRef, scope?: ScopedToken['scope']): Promise<ScopedToken> {
    if (!this.tokenValue) {
      throw new Error(
        'dev auth cannot mint repo tokens — remote git arrives with the Auth service (M4)',
      )
    }
    return {
      value: this.tokenValue,
      repo,
      scope: scope ?? 'contents:write',
      expiresAt: Date.now() + TOKEN_TTL_MS,
    }
  }

  async capabilities(): Promise<CapabilityFlags> {
    return { premiumCollab: false, managedStorage: false, collaboratorSeats: 0 }
  }
}
