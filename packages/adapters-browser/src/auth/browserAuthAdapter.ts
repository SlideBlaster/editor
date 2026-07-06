/**
 * Browser Auth adapter. Contract: see browserAuthAdapter.md.
 *
 * The real AuthPort for the web shell (ADR 0010, M4). Identity comes from a
 * session cookie established by GitHub OAuth against the Auth service; repo
 * tokens are minted on demand by the isolated minting service, scoped to a
 * single repo with a short TTL. The minted token lives in memory only — never
 * localStorage, never disk, never logged. Re-minted on expiry and on reload.
 *
 * The adapter is transport code: it talks the HTTP contract below and is blind
 * to whether a real GitHub App or the local dev stub answers, so the same
 * production code runs in Phase A (local stub) and Phase B (deployed service).
 */
import type {
  AuthPort,
  CapabilityFlags,
  Identity,
  RepoRef,
  ScopedToken,
} from '@slideblaster/editor'

export interface BrowserAuthOptions {
  /** Auth service base URL, no trailing slash (e.g. https://auth.slideblaster.app). */
  baseUrl: string
  /** Injected fetch (tests/SSR); defaults to global fetch. */
  fetch?: typeof fetch
  /** Reads a cookie by name (tests/SSR); defaults to document.cookie. */
  readCookie?: (name: string) => string | null
  /** Performs the OAuth full-page redirect (tests); defaults to location.assign. */
  navigate?: (url: string) => void
  /** Page URL used as the OAuth return target; defaults to location.href. */
  currentUrl?: () => string
}

/** Minting service response for POST /mint (the token value is secret). */
interface MintResponse {
  value: string
  /** Epoch milliseconds. */
  expiresAt: number
}

const CSRF_COOKIE = 'sb_csrf'
const CSRF_HEADER = 'x-sb-csrf'
/** Re-mint if the cached token expires within this window (clock-skew guard). */
const EXPIRY_SKEW_MS = 60_000

const FREE_TIER: CapabilityFlags = {
  premiumCollab: false,
  managedStorage: false,
  collaboratorSeats: 0,
}

function defaultReadCookie(name: string): string | null {
  if (typeof document === 'undefined') return null
  const prefix = `${name}=`
  for (const part of document.cookie.split('; ')) {
    if (part.startsWith(prefix)) return decodeURIComponent(part.slice(prefix.length))
  }
  return null
}

export class BrowserAuthAdapter implements AuthPort {
  private readonly baseUrl: string
  private readonly doFetch: typeof fetch
  private readonly readCookie: (name: string) => string | null
  private readonly navigate: (url: string) => void
  private readonly currentUrl: () => string

  private identity: Identity | null = null
  /** In-memory only: `${owner}/${name}:${scope}` -> minted token. */
  private readonly tokens = new Map<string, ScopedToken>()

  constructor(options: BrowserAuthOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, '')
    this.doFetch = options.fetch ?? ((...args) => fetch(...args))
    this.readCookie = options.readCookie ?? defaultReadCookie
    this.navigate =
      options.navigate ?? ((url) => void (globalThis.location as Location).assign(url))
    this.currentUrl = options.currentUrl ?? (() => (globalThis.location as Location).href)
  }

  /**
   * Probe the session (`GET /me`) so `currentIdentity()` answers synchronously
   * thereafter. The shell awaits this once at boot; callers use the factory.
   */
  async restore(): Promise<Identity | null> {
    try {
      const res = await this.doFetch(`${this.baseUrl}/me`, { credentials: 'include' })
      this.identity = res.ok ? ((await res.json()) as Identity) : null
    } catch {
      this.identity = null
    }
    return this.identity
  }

  async signIn(): Promise<Identity> {
    const returnTo = encodeURIComponent(this.currentUrl())
    // A full-page redirect into the GitHub OAuth flow; the page reloads on
    // return and `restore()` re-seeds identity, so this promise never resolves.
    this.navigate(`${this.baseUrl}/auth/github?return_to=${returnTo}`)
    return new Promise<Identity>(() => {})
  }

  async signOut(): Promise<void> {
    this.identity = null
    this.tokens.clear()
    try {
      await this.doFetch(`${this.baseUrl}/signout`, {
        method: 'POST',
        credentials: 'include',
        headers: this.csrfHeaders(),
      })
    } catch {
      // Best-effort: local state is already cleared.
    }
  }

  currentIdentity(): Identity | null {
    return this.identity
  }

  async getRepoToken(
    repo: RepoRef,
    scope: ScopedToken['scope'] = 'contents:write',
  ): Promise<ScopedToken> {
    const key = `${repo.owner}/${repo.name}:${scope}`
    const cached = this.tokens.get(key)
    if (cached && cached.expiresAt - Date.now() > EXPIRY_SKEW_MS) return cached

    const res = await this.doFetch(`${this.baseUrl}/mint`, {
      method: 'POST',
      credentials: 'include',
      headers: { 'content-type': 'application/json', ...this.csrfHeaders() },
      body: JSON.stringify({ owner: repo.owner, name: repo.name, scope }),
    })
    if (res.status === 401) throw new Error('sign in to sync with GitHub')
    if (res.status === 403) {
      throw new Error(
        `no access to ${repo.owner}/${repo.name} — install the SlideBlaster GitHub App on it`,
      )
    }
    if (!res.ok) throw new Error(`token mint failed (${res.status})`)

    const body = (await res.json()) as MintResponse
    const token: ScopedToken = { value: body.value, repo, scope, expiresAt: body.expiresAt }
    this.tokens.set(key, token)
    return token
  }

  async capabilities(): Promise<CapabilityFlags> {
    try {
      const res = await this.doFetch(`${this.baseUrl}/capabilities`, { credentials: 'include' })
      if (!res.ok) return FREE_TIER
      return (await res.json()) as CapabilityFlags
    } catch {
      return FREE_TIER
    }
  }

  /** Double-submit CSRF: echo the non-httpOnly cookie back as a header. */
  private csrfHeaders(): Record<string, string> {
    const csrf = this.readCookie(CSRF_COOKIE)
    return csrf ? { [CSRF_HEADER]: csrf } : {}
  }
}

/** Build a signed-in-aware adapter: probes the session before first paint. */
export async function createBrowserAuthAdapter(
  options: BrowserAuthOptions,
): Promise<BrowserAuthAdapter> {
  const adapter = new BrowserAuthAdapter(options)
  await adapter.restore()
  return adapter
}
