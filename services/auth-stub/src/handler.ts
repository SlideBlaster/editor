/**
 * Local dev double for the Auth + minting service. Contract: see handler.md.
 *
 * Speaks exactly the HTTP contract BrowserAuthAdapter calls (auth.md, ADR 0010)
 * so the whole signed-in client path works locally with no GitHub, no KMS, and
 * no real backend — Phase A. It fakes what the real service does for real: `/auth/
 * github` "authenticates" a fixed dev identity instead of round-tripping GitHub
 * OAuth, and `/mint` returns a configured/synthetic token instead of a
 * KMS-signed App installation token. The real service (Phase B) replaces it
 * wholesale; the adapter and app code do not change.
 *
 * Web-standard Request/Response so the same core runs under Node (node.ts) and
 * could run on a Worker. Sessions are in-memory (a dev process); nothing is
 * persisted.
 */
import type { CapabilityFlags, Identity } from '@slideblaster/editor'

export interface AuthStubOptions {
  /** Identity handed out on sign-in (default a local `dev` user). */
  identity?: Identity
  /**
   * Token value returned by `/mint`. Default is a synthetic per-repo dev token
   * (fine for a local git server). Set a real fine-grained PAT to test against a
   * real GitHub repo through the git-proxy — the same seam the spike used.
   */
  mintToken?: string
  /** Minted-token TTL in ms (default 1h, matching the ADR ceiling). */
  tokenTtlMs?: number
  /** Capability flags reported by `/capabilities` (default free tier). */
  capabilities?: CapabilityFlags
  /** Emit `Secure` on cookies. Off by default so http://localhost dev works. */
  secureCookies?: boolean
}

interface Session {
  identity: Identity
  csrf: string
}

const SESSION_COOKIE = 'sb_session'
const CSRF_COOKIE = 'sb_csrf'
const CSRF_HEADER = 'x-sb-csrf'
const HOUR_MS = 3_600_000

const DEFAULT_IDENTITY: Identity = { login: 'dev', id: 'dev:local' }
const DEFAULT_CAPABILITIES: CapabilityFlags = {
  premiumCollab: false,
  managedStorage: false,
  collaboratorSeats: 0,
}

export interface AuthStub {
  /** Handle one request against the Auth-service HTTP contract. */
  handle(request: Request): Promise<Response>
}

/**
 * Build a stub with its own in-memory session store. One instance per dev
 * server / test so state does not leak between them.
 */
export function createAuthStub(options: AuthStubOptions = {}): AuthStub {
  const identity = options.identity ?? DEFAULT_IDENTITY
  const tokenTtlMs = options.tokenTtlMs ?? HOUR_MS
  const capabilities = options.capabilities ?? DEFAULT_CAPABILITIES
  const secure = options.secureCookies ?? false
  const sessions = new Map<string, Session>()

  const handle = async (request: Request): Promise<Response> => {
    const origin = request.headers.get('origin')
    if (request.method === 'OPTIONS') return preflight(origin)

    const url = new URL(request.url)
    const route = `${request.method} ${url.pathname}`

    switch (route) {
      case 'GET /auth/github':
        return startOAuth(url, sessions, identity, secure, origin)
      case 'GET /me':
        return me(request, sessions, origin)
      case 'POST /mint':
        return mint(request, sessions, options.mintToken, tokenTtlMs, origin)
      case 'GET /capabilities':
        return capabilitiesRoute(request, sessions, capabilities, origin)
      case 'POST /signout':
        return signOut(request, sessions, secure, origin)
      default:
        return json({ error: 'not found' }, 404, origin)
    }
  }

  return { handle }
}

/** Fake the OAuth round-trip: create a session and 302 back to `return_to`. */
function startOAuth(
  url: URL,
  sessions: Map<string, Session>,
  identity: Identity,
  secure: boolean,
  origin: string | null,
): Response {
  const sessionId = crypto.randomUUID()
  const csrf = crypto.randomUUID()
  sessions.set(sessionId, { identity, csrf })

  const returnTo = safeReturnTo(url.searchParams.get('return_to'))
  const headers = corsHeaders(origin)
  headers.set('location', returnTo)
  headers.append('set-cookie', cookie(SESSION_COOKIE, sessionId, { httpOnly: true, secure }))
  headers.append('set-cookie', cookie(CSRF_COOKIE, csrf, { httpOnly: false, secure }))
  return new Response(null, { status: 302, headers })
}

function me(request: Request, sessions: Map<string, Session>, origin: string | null): Response {
  const session = sessionOf(request, sessions)
  if (!session) return json({ error: 'no session' }, 401, origin)
  return json(session.identity, 200, origin)
}

function mint(
  request: Request,
  sessions: Map<string, Session>,
  mintToken: string | undefined,
  tokenTtlMs: number,
  origin: string | null,
): Promise<Response> {
  return (async () => {
    const session = sessionOf(request, sessions)
    if (!session) return json({ error: 'no session' }, 401, origin)
    if (request.headers.get(CSRF_HEADER) !== session.csrf) {
      return json({ error: 'bad csrf' }, 403, origin)
    }
    const body = (await request.json().catch(() => null)) as {
      owner?: string
      name?: string
    } | null
    if (!body?.owner || !body?.name) return json({ error: 'owner/name required' }, 400, origin)

    // The real service authorizes the user against the repo's App installation
    // and mints a KMS-signed, single-repo token here. The stub grants all.
    const value = mintToken ?? `dev-token:${body.owner}/${body.name}`
    return json({ value, expiresAt: Date.now() + tokenTtlMs }, 200, origin)
  })()
}

function capabilitiesRoute(
  request: Request,
  sessions: Map<string, Session>,
  capabilities: CapabilityFlags,
  origin: string | null,
): Response {
  const session = sessionOf(request, sessions)
  if (!session) return json({ error: 'no session' }, 401, origin)
  return json(capabilities, 200, origin)
}

function signOut(
  request: Request,
  sessions: Map<string, Session>,
  secure: boolean,
  origin: string | null,
): Response {
  const sessionId = cookieOf(request, SESSION_COOKIE)
  if (sessionId) sessions.delete(sessionId)
  const headers = corsHeaders(origin)
  headers.append('set-cookie', cookie(SESSION_COOKIE, '', { httpOnly: true, secure, maxAge: 0 }))
  headers.append('set-cookie', cookie(CSRF_COOKIE, '', { httpOnly: false, secure, maxAge: 0 }))
  return new Response(null, { status: 204, headers })
}

function sessionOf(request: Request, sessions: Map<string, Session>): Session | undefined {
  const id = cookieOf(request, SESSION_COOKIE)
  return id ? sessions.get(id) : undefined
}

function cookieOf(request: Request, name: string): string | null {
  const header = request.headers.get('cookie')
  if (!header) return null
  const prefix = `${name}=`
  for (const part of header.split('; ')) {
    if (part.startsWith(prefix)) return decodeURIComponent(part.slice(prefix.length))
  }
  return null
}

interface CookieAttrs {
  httpOnly: boolean
  secure: boolean
  maxAge?: number
}

function cookie(name: string, value: string, attrs: CookieAttrs): string {
  const parts = [`${name}=${encodeURIComponent(value)}`, 'Path=/', 'SameSite=Lax']
  if (attrs.httpOnly) parts.push('HttpOnly')
  if (attrs.secure) parts.push('Secure')
  if (attrs.maxAge !== undefined) parts.push(`Max-Age=${attrs.maxAge}`)
  return parts.join('; ')
}

/** Only same-origin-ish relative paths; never an open redirect off to elsewhere. */
function safeReturnTo(raw: string | null): string {
  if (!raw) return '/'
  try {
    // Reject absolute URLs (protocol/host); keep path + query + hash only.
    const parsed = new URL(raw, 'http://localhost')
    return `${parsed.pathname}${parsed.search}${parsed.hash}` || '/'
  } catch {
    return '/'
  }
}

/** CORS for credentialed cross-origin dev (e.g. hitting the stub directly). */
function corsHeaders(origin: string | null): Headers {
  const headers = new Headers()
  if (origin) {
    headers.set('access-control-allow-origin', origin)
    headers.set('access-control-allow-credentials', 'true')
    headers.append('vary', 'origin')
  }
  return headers
}

function preflight(origin: string | null): Response {
  const headers = corsHeaders(origin)
  headers.set('access-control-allow-methods', 'GET, POST, OPTIONS')
  headers.set('access-control-allow-headers', `content-type, ${CSRF_HEADER}`)
  headers.set('access-control-max-age', '600')
  return new Response(null, { status: 204, headers })
}

function json(body: unknown, status: number, origin: string | null): Response {
  const headers = corsHeaders(origin)
  headers.set('content-type', 'application/json')
  return new Response(status === 204 ? null : JSON.stringify(body), { status, headers })
}
