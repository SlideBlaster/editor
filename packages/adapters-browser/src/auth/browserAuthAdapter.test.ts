import { describe, expect, it, vi } from 'vitest'
import type { Identity } from '@slideblaster/editor'
import { BrowserAuthAdapter, createBrowserAuthAdapter } from './browserAuthAdapter'

const BASE = 'https://auth.test'
const IDENTITY: Identity = { login: 'octocat', id: 'gh:1' }
const REPO = { owner: 'octocat', name: 'deck' }

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

/** A fetch mock that routes by pathname; each route is a queue or a function. */
function makeFetch(routes: Record<string, (req: Request) => Response>) {
  return vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input.toString()
    const req = new Request(url, init)
    const path = new URL(url).pathname
    const handler = routes[path]
    if (!handler) throw new Error(`unexpected fetch: ${path}`)
    return handler(req)
  })
}

describe('BrowserAuthAdapter', () => {
  it('restore() seeds identity from GET /me and currentIdentity answers sync', async () => {
    const fetchMock = makeFetch({ '/me': () => jsonResponse(IDENTITY) })
    const auth = await createBrowserAuthAdapter({ baseUrl: BASE, fetch: fetchMock })
    expect(auth.currentIdentity()).toEqual(IDENTITY)
  })

  it('restore() leaves identity null on a 401 session probe', async () => {
    const fetchMock = makeFetch({ '/me': () => new Response(null, { status: 401 }) })
    const auth = await createBrowserAuthAdapter({ baseUrl: BASE, fetch: fetchMock })
    expect(auth.currentIdentity()).toBeNull()
  })

  it('signIn redirects to the OAuth start with an encoded return_to', async () => {
    const navigate = vi.fn()
    const auth = new BrowserAuthAdapter({
      baseUrl: BASE,
      fetch: makeFetch({}),
      navigate,
      currentUrl: () => 'https://app.test/deck?x=1',
    })
    void auth.signIn()
    expect(navigate).toHaveBeenCalledWith(
      `${BASE}/auth/github?return_to=${encodeURIComponent('https://app.test/deck?x=1')}`,
    )
  })

  it('getRepoToken mints, sends CSRF + credentials, and caches by repo/scope', async () => {
    const expiresAt = Date.now() + 3_600_000
    let mintCalls = 0
    let seenInit: RequestInit | undefined
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      seenInit = init
      mintCalls += 1
      return jsonResponse({ value: 'ghs_secret', expiresAt })
    })
    const auth = new BrowserAuthAdapter({
      baseUrl: BASE,
      fetch: fetchMock,
      readCookie: (name) => (name === 'sb_csrf' ? 'csrf-123' : null),
    })

    const first = await auth.getRepoToken(REPO)
    expect(first).toEqual({
      value: 'ghs_secret',
      repo: REPO,
      scope: 'contents:write',
      expiresAt,
    })
    expect(seenInit?.credentials).toBe('include')
    expect(new Headers(seenInit?.headers).get('x-sb-csrf')).toBe('csrf-123')

    // Second call for the same repo/scope is served from cache (no new mint).
    await auth.getRepoToken(REPO)
    expect(mintCalls).toBe(1)

    // A different scope mints again.
    await auth.getRepoToken(REPO, 'contents:read')
    expect(mintCalls).toBe(2)
  })

  it('getRepoToken re-mints once the cached token is within the skew window', async () => {
    let call = 0
    const fetchMock = vi.fn(async () => {
      call += 1
      // First token already inside the 60s skew window -> not reusable.
      const expiresAt = call === 1 ? Date.now() + 30_000 : Date.now() + 3_600_000
      return jsonResponse({ value: `t${call}`, expiresAt })
    })
    const auth = new BrowserAuthAdapter({ baseUrl: BASE, fetch: fetchMock })
    await auth.getRepoToken(REPO)
    const second = await auth.getRepoToken(REPO)
    expect(call).toBe(2)
    expect(second.value).toBe('t2')
  })

  it('getRepoToken maps 401/403 to actionable errors', async () => {
    const auth401 = new BrowserAuthAdapter({
      baseUrl: BASE,
      fetch: makeFetch({ '/mint': () => new Response(null, { status: 401 }) }),
    })
    await expect(auth401.getRepoToken(REPO)).rejects.toThrow(/sign in/i)

    const auth403 = new BrowserAuthAdapter({
      baseUrl: BASE,
      fetch: makeFetch({ '/mint': () => new Response(null, { status: 403 }) }),
    })
    await expect(auth403.getRepoToken(REPO)).rejects.toThrow(/install the SlideBlaster GitHub App/i)
  })

  it('signOut clears identity and the token cache', async () => {
    const fetchMock = makeFetch({
      '/me': () => jsonResponse(IDENTITY),
      '/mint': () => jsonResponse({ value: 't', expiresAt: Date.now() + 3_600_000 }),
      '/signout': () => new Response(null, { status: 204 }),
    })
    const auth = await createBrowserAuthAdapter({ baseUrl: BASE, fetch: fetchMock })
    await auth.getRepoToken(REPO)
    await auth.signOut()
    expect(auth.currentIdentity()).toBeNull()
    // Cache cleared: the next token requires a fresh mint (proven by call count).
    const before = fetchMock.mock.calls.length
    await auth.getRepoToken(REPO)
    expect(fetchMock.mock.calls.length).toBe(before + 1)
  })

  it('capabilities falls back to the free tier when unauthenticated', async () => {
    const auth = new BrowserAuthAdapter({
      baseUrl: BASE,
      fetch: makeFetch({ '/capabilities': () => new Response(null, { status: 401 }) }),
    })
    expect(await auth.capabilities()).toEqual({
      premiumCollab: false,
      managedStorage: false,
      collaboratorSeats: 0,
    })
  })
})
