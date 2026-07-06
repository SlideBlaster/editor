/**
 * The Auth-service HTTP contract, runtime-agnostic core. Contract: handler.md.
 *
 * Identical contract to `services/auth-stub` + the retired Phoenix service, backed
 * by real GitHub OAuth + installation-token minting, so `BrowserAuthAdapter` cannot
 * tell them apart. Takes injected deps (config, session store, GitHub client) so it
 * runs on the Workers runtime and under Node (tests) unchanged.
 *
 * Session id in the HttpOnly `sb_session` cookie; double-submit csrf in the readable
 * `sb_csrf` cookie, required as `x-sb-csrf` on state-changing routes. `sb_flow`
 * carries the pending handoff across the GitHub round-trip (the install flow does
 * not reliably echo `state`).
 */
import type { AuthConfig, CapabilityFlags, Identity } from './config'
import type { GitHubClient } from './github'
import type { SessionStore } from './sessions'

const SESSION_COOKIE = 'sb_session'
const CSRF_COOKIE = 'sb_csrf'
const FLOW_COOKIE = 'sb_flow'
const CSRF_HEADER = 'x-sb-csrf'
const FLOW_MAX_AGE = 600

export interface AuthDeps {
  config: AuthConfig
  sessions: SessionStore
  github: GitHubClient
}

export interface AuthHandler {
  handle(request: Request): Promise<Response>
}

export function createAuthHandler(deps: AuthDeps): AuthHandler {
  const { config, sessions, github } = deps

  const handle = async (request: Request): Promise<Response> => {
    // Reflect credentialed CORS only for the allowlisted web-shell origin.
    const origin =
      request.headers.get('origin') === config.webShellOrigin ? config.webShellOrigin : null
    if (request.method === 'OPTIONS') return preflight(origin)

    const url = new URL(request.url)
    const route = `${request.method} ${url.pathname}`

    switch (route) {
      case 'GET /auth/github':
        return start(url, origin)
      case 'GET /auth/github/install':
        return install(url, origin)
      case 'GET /auth/github/callback':
        return callback(request, url, origin)
      case 'GET /me':
        return me(request, origin)
      case 'GET /capabilities':
        return capabilities(request, origin)
      case 'POST /mint':
        return mint(request, origin)
      case 'POST /signout':
        return signout(request, origin)
      default:
        return json({ error: 'not found' }, 404, origin)
    }
  }

  // GET /auth/github — SSO sign-in (identity only).
  const start = async (url: URL, origin: string | null): Promise<Response> => {
    const state = await sessions.putPending(safeReturnTo(config, url.searchParams.get('return_to')))
    const query = new URLSearchParams({ client_id: config.githubClientId, state })
    return redirect(
      `https://github.com/login/oauth/authorize?${query}`,
      [cookie(config, FLOW_COOKIE, state, { httpOnly: true, maxAge: FLOW_MAX_AGE })],
      origin,
    )
  }

  // GET /auth/github/install — send the user to grant the App a repo (install-per-repo).
  const install = async (url: URL, origin: string | null): Promise<Response> => {
    const state = await sessions.putPending(safeReturnTo(config, url.searchParams.get('return_to')))
    const target = await github.installUrl()
    if (!target) {
      return redirect(appendQuery(config.webShellOrigin, 'auth=install_unavailable'), [], origin)
    }
    return redirect(
      target,
      [cookie(config, FLOW_COOKIE, state, { httpOnly: true, maxAge: FLOW_MAX_AGE })],
      origin,
    )
  }

  // GET /auth/github/callback — exchange + identify; serves sign-in and install.
  const callback = async (request: Request, url: URL, origin: string | null): Promise<Response> => {
    const cookies = parseCookies(request)
    const state = url.searchParams.get('state') ?? cookies[FLOW_COOKIE] ?? null
    const returnTo = (await sessions.takePending(state)) ?? config.webShellOrigin
    const code = url.searchParams.get('code')

    const clearFlow = cookie(config, FLOW_COOKIE, '', { httpOnly: true, maxAge: 0 })

    if (code) {
      const userToken = await github.exchangeCode(code)
      const identity = userToken ? await github.getUser(userToken) : null
      if (userToken && identity) {
        const session = await sessions.create({ userToken, identity })
        return redirect(returnTo, [...sessionCookies(config, session), clearFlow], origin)
      }
    }
    return redirect(appendQuery(config.webShellOrigin, 'auth=error'), [clearFlow], origin)
  }

  const me = async (request: Request, origin: string | null): Promise<Response> => {
    const session = await currentSession(request)
    if (!session) return json({ error: 'unauthenticated' }, 401, origin)
    return json(identityJson(session.identity), 200, origin)
  }

  const capabilities = async (request: Request, origin: string | null): Promise<Response> => {
    const session = await currentSession(request)
    if (!session) return json({ error: 'unauthenticated' }, 401, origin)
    const flags: CapabilityFlags = {
      premiumCollab: false,
      managedStorage: false,
      collaboratorSeats: 0,
    }
    return json(flags, 200, origin)
  }

  const mint = async (request: Request, origin: string | null): Promise<Response> => {
    const session = await currentSession(request)
    if (!session) return json({ error: 'unauthenticated' }, 401, origin)
    if (request.headers.get(CSRF_HEADER) !== session.csrf) {
      return json({ error: 'bad_csrf' }, 403, origin)
    }
    const body = (await request.json().catch(() => null)) as {
      owner?: string
      name?: string
    } | null
    if (!body?.owner || !body?.name) return json({ error: 'owner/name required' }, 400, origin)

    const result = await github.mintRepoToken(session.userToken, body.owner, body.name)
    if (!result.ok) {
      const status = result.reason === 'no_repo_access' ? 403 : 502
      return json({ error: result.reason }, status, origin)
    }
    return json({ value: result.value, expiresAt: result.expiresAt }, 200, origin)
  }

  const signout = async (request: Request, origin: string | null): Promise<Response> => {
    const cookies = parseCookies(request)
    await sessions.delete(cookies[SESSION_COOKIE] ?? null)
    const cleared = [
      cookie(config, SESSION_COOKIE, '', { httpOnly: true, maxAge: 0 }),
      cookie(config, CSRF_COOKIE, '', { httpOnly: false, maxAge: 0 }),
    ]
    const headers = corsHeaders(config, origin)
    for (const c of cleared) headers.append('set-cookie', c)
    return new Response(null, { status: 204, headers })
  }

  const currentSession = (request: Request) => {
    const cookies = parseCookies(request)
    return sessions.get(cookies[SESSION_COOKIE] ?? null)
  }

  return { handle }
}

// --- helpers ---

function identityJson(identity: Identity): Identity {
  return { login: identity.login, id: identity.id, avatarUrl: identity.avatarUrl }
}

function sessionCookies(config: AuthConfig, session: { id: string; csrf: string }): string[] {
  return [
    cookie(config, SESSION_COOKIE, session.id, { httpOnly: true }),
    cookie(config, CSRF_COOKIE, session.csrf, { httpOnly: false }),
  ]
}

function cookie(
  config: AuthConfig,
  name: string,
  value: string,
  opts: { httpOnly: boolean; maxAge?: number },
): string {
  const parts = [`${name}=${encodeURIComponent(value)}`, 'Path=/', `SameSite=${config.sameSite}`]
  if (opts.httpOnly) parts.push('HttpOnly')
  if (config.secureCookies) parts.push('Secure')
  if (opts.maxAge !== undefined) parts.push(`Max-Age=${opts.maxAge}`)
  return parts.join('; ')
}

function parseCookies(request: Request): Record<string, string> {
  const header = request.headers.get('cookie')
  if (!header) return {}
  const out: Record<string, string> = {}
  for (const part of header.split('; ')) {
    const eq = part.indexOf('=')
    if (eq < 0) continue
    out[part.slice(0, eq)] = decodeURIComponent(part.slice(eq + 1))
  }
  return out
}

// Accept a bare path, or an absolute URL whose origin is the web shell; else fall
// back to the web-shell root. Prevents open-redirect abuse.
function safeReturnTo(config: AuthConfig, value: string | null): string {
  if (!value) return config.webShellOrigin
  if (value.startsWith('/')) return config.webShellOrigin + value
  if (value.startsWith(config.webShellOrigin)) return value
  return config.webShellOrigin
}

function appendQuery(url: string, query: string): string {
  return url + (url.includes('?') ? '&' : '?') + query
}

function corsHeaders(config: AuthConfig, origin: string | null): Headers {
  const headers = new Headers()
  if (origin && origin === config.webShellOrigin) {
    headers.set('access-control-allow-origin', origin)
    headers.set('access-control-allow-credentials', 'true')
    headers.append('vary', 'origin')
  }
  return headers
}

function preflight(origin: string | null): Response {
  const headers = new Headers()
  if (origin) {
    headers.set('access-control-allow-origin', origin)
    headers.set('access-control-allow-credentials', 'true')
    headers.append('vary', 'origin')
  }
  headers.set('access-control-allow-methods', 'GET, POST, OPTIONS')
  headers.set('access-control-allow-headers', `content-type, ${CSRF_HEADER}`)
  headers.set('access-control-max-age', '600')
  return new Response(null, { status: 204, headers })
}

// A 302 top-level navigation; CORS headers are irrelevant (not a fetch read).
function redirect(location: string, cookies: string[], _origin: string | null): Response {
  const headers = new Headers({ location })
  for (const c of cookies) headers.append('set-cookie', c)
  return new Response(null, { status: 302, headers })
}

function json(body: unknown, status: number, origin: string | null): Response {
  const headers = new Headers({ 'content-type': 'application/json' })
  if (origin) {
    headers.set('access-control-allow-origin', origin)
    headers.set('access-control-allow-credentials', 'true')
    headers.append('vary', 'origin')
  }
  return new Response(status === 204 ? null : JSON.stringify(body), { status, headers })
}
