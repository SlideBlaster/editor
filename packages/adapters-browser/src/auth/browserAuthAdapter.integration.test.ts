import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { Server } from 'node:http'
import { createAuthStubServer, listen } from '@slideblaster/auth-stub'
import { BrowserAuthAdapter, createBrowserAuthAdapter } from './browserAuthAdapter'

// End-to-end over real HTTP: the real BrowserAuthAdapter against an in-process
// auth-stub, with a cookie jar standing in for the browser. Proves the whole
// signed-in client path — session probe, OAuth "redirect", CSRF-gated minting,
// capabilities, sign-out — works against the actual service contract, not a mock.
describe('BrowserAuthAdapter <-> auth-stub (real HTTP)', () => {
  let server: Server
  let baseUrl: string

  beforeAll(async () => {
    server = createAuthStubServer({
      identity: { login: 'octocat', id: 'gh:42' },
    })
    const port = await listen(server, 0)
    baseUrl = `http://localhost:${port}`
  })

  afterAll(() => {
    server?.close()
  })

  /** A fetch + cookie jar: sends stored cookies, records Set-Cookie, no auto-redirect. */
  function browserLike() {
    const jar = new Map<string, string>()
    const readCookie = (name: string): string | null => jar.get(name) ?? null
    const doFetch: typeof fetch = async (input, init) => {
      const headers = new Headers(init?.headers)
      if (jar.size > 0) {
        headers.set('cookie', [...jar].map(([k, v]) => `${k}=${v}`).join('; '))
      }
      const res = await fetch(input, { ...init, headers, redirect: 'manual' })
      for (const raw of res.headers.getSetCookie()) {
        const pair = raw.split('; ')[0] ?? ''
        const eq = pair.indexOf('=')
        const name = pair.slice(0, eq)
        const value = pair.slice(eq + 1)
        const expired = /(?:^|; )Max-Age=0(?:;|$)/i.test(raw) || value === ''
        if (expired) jar.delete(name)
        else jar.set(name, value)
      }
      return res
    }
    return { doFetch, readCookie, jar }
  }

  it('runs the full session -> mint -> signout loop against the live contract', async () => {
    const { doFetch, readCookie } = browserLike()
    let navigatedTo = ''
    const navigate = (url: string): void => {
      navigatedTo = url
    }

    // 1. Cold start: no session yet.
    const auth = await createBrowserAuthAdapter({
      baseUrl,
      fetch: doFetch,
      readCookie,
      navigate,
      currentUrl: () => 'http://app.local/deck',
    })
    expect(auth.currentIdentity()).toBeNull()

    // 2. Sign in redirects to the OAuth start; the browser "follows" it (which sets
    //    the session + csrf cookies), then a re-probe seeds identity.
    void auth.signIn()
    expect(navigatedTo).toBe(
      `${baseUrl}/auth/github?return_to=${encodeURIComponent('http://app.local/deck')}`,
    )
    await doFetch(navigatedTo)
    expect(await auth.restore()).toEqual({ login: 'octocat', id: 'gh:42' })
    expect(auth.currentIdentity()).toEqual({ login: 'octocat', id: 'gh:42' })

    // 3. Mint a repo-scoped token (CSRF header sourced from the jar cookie).
    const token = await auth.getRepoToken({ owner: 'octocat', name: 'deck' })
    expect(token.value).toBe('dev-token:octocat/deck')
    expect(token.scope).toBe('contents:write')
    expect(token.expiresAt).toBeGreaterThan(Date.now())

    // 4. Free-tier capabilities while signed in.
    expect(await auth.capabilities()).toEqual({
      premiumCollab: false,
      managedStorage: false,
      collaboratorSeats: 0,
    })

    // 5. Sign out drops the session; a fresh adapter over the same jar sees nobody.
    await auth.signOut()
    expect(auth.currentIdentity()).toBeNull()
    const after = new BrowserAuthAdapter({ baseUrl, fetch: doFetch, readCookie, navigate })
    expect(await after.restore()).toBeNull()
    await expect(after.getRepoToken({ owner: 'octocat', name: 'deck' })).rejects.toThrow(/sign in/i)
  })
})
