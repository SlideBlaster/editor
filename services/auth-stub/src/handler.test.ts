import { describe, expect, it } from 'vitest'
import { createAuthStub } from './handler'

const BASE = 'http://auth.local'

/** Parse the session + csrf cookies out of a Set-Cookie list into a Cookie header. */
function cookieHeader(res: Response): string {
  return res.headers
    .getSetCookie()
    .map((c) => c.split(';')[0])
    .join('; ')
}

function csrfValue(res: Response): string {
  const set = res.headers.getSetCookie().find((c) => c.startsWith('sb_csrf='))!
  return decodeURIComponent(set.split(';')[0]!.split('=')[1]!)
}

async function signIn(stub: ReturnType<typeof createAuthStub>) {
  const res = await stub.handle(
    new Request(`${BASE}/auth/github?return_to=${encodeURIComponent('/deck')}`),
  )
  return { cookies: cookieHeader(res), csrf: csrfValue(res), res }
}

describe('auth stub', () => {
  it('GET /auth/github creates a session and 302s back to return_to', async () => {
    const stub = createAuthStub()
    const { res } = await signIn(stub)
    expect(res.status).toBe(302)
    expect(res.headers.get('location')).toBe('/deck')
    const setCookies = res.headers.getSetCookie()
    expect(setCookies.some((c) => c.startsWith('sb_session=') && /HttpOnly/.test(c))).toBe(true)
    expect(setCookies.some((c) => c.startsWith('sb_csrf=') && !/HttpOnly/.test(c))).toBe(true)
  })

  it('rejects an absolute return_to (no open redirect)', async () => {
    const stub = createAuthStub()
    const res = await stub.handle(
      new Request(`${BASE}/auth/github?return_to=${encodeURIComponent('https://evil.test/x')}`),
    )
    expect(res.headers.get('location')).toBe('/x')
  })

  it('GET /me is 401 without a session, identity with one', async () => {
    const stub = createAuthStub({ identity: { login: 'octocat', id: 'gh:1' } })
    expect((await stub.handle(new Request(`${BASE}/me`))).status).toBe(401)

    const { cookies } = await signIn(stub)
    const me = await stub.handle(new Request(`${BASE}/me`, { headers: { cookie: cookies } }))
    expect(me.status).toBe(200)
    expect(await me.json()).toEqual({ login: 'octocat', id: 'gh:1' })
  })

  it('POST /mint needs a session and a matching CSRF header, then returns a token', async () => {
    const stub = createAuthStub({ tokenTtlMs: 1000 })
    const { cookies, csrf } = await signIn(stub)
    const body = JSON.stringify({ owner: 'octocat', name: 'deck', scope: 'contents:write' })

    // No session.
    expect((await stub.handle(new Request(`${BASE}/mint`, { method: 'POST', body }))).status).toBe(
      401,
    )

    // Session but wrong CSRF.
    const badCsrf = await stub.handle(
      new Request(`${BASE}/mint`, {
        method: 'POST',
        headers: { cookie: cookies, 'x-sb-csrf': 'nope', 'content-type': 'application/json' },
        body,
      }),
    )
    expect(badCsrf.status).toBe(403)

    // Valid.
    const ok = await stub.handle(
      new Request(`${BASE}/mint`, {
        method: 'POST',
        headers: { cookie: cookies, 'x-sb-csrf': csrf, 'content-type': 'application/json' },
        body,
      }),
    )
    expect(ok.status).toBe(200)
    const token = (await ok.json()) as { value: string; expiresAt: number }
    expect(token.value).toBe('dev-token:octocat/deck')
    expect(token.expiresAt).toBeGreaterThan(Date.now())
  })

  it('/mint returns the configured PAT when one is set (real-GitHub path)', async () => {
    const stub = createAuthStub({ mintToken: 'github_pat_real' })
    const { cookies, csrf } = await signIn(stub)
    const res = await stub.handle(
      new Request(`${BASE}/mint`, {
        method: 'POST',
        headers: { cookie: cookies, 'x-sb-csrf': csrf, 'content-type': 'application/json' },
        body: JSON.stringify({ owner: 'o', name: 'r' }),
      }),
    )
    expect(((await res.json()) as { value: string }).value).toBe('github_pat_real')
  })

  it('POST /signout drops the session and clears cookies', async () => {
    const stub = createAuthStub()
    const { cookies } = await signIn(stub)
    const out = await stub.handle(
      new Request(`${BASE}/signout`, { method: 'POST', headers: { cookie: cookies } }),
    )
    expect(out.status).toBe(204)
    expect(out.headers.getSetCookie().some((c) => /Max-Age=0/.test(c))).toBe(true)
    // Session no longer valid.
    const me = await stub.handle(new Request(`${BASE}/me`, { headers: { cookie: cookies } }))
    expect(me.status).toBe(401)
  })

  it('OPTIONS preflight echoes a credentialed CORS envelope', async () => {
    const stub = createAuthStub()
    const res = await stub.handle(
      new Request(`${BASE}/mint`, { method: 'OPTIONS', headers: { origin: 'http://app.local' } }),
    )
    expect(res.status).toBe(204)
    expect(res.headers.get('access-control-allow-origin')).toBe('http://app.local')
    expect(res.headers.get('access-control-allow-credentials')).toBe('true')
  })
})
