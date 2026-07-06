/**
 * Exercises the Auth contract (routes, cookies, CSRF, mint gating) with an
 * in-memory session store and a fake GitHub client — no network, no real key.
 */
import { describe, expect, it } from 'vitest'
import type { AuthConfig } from './config'
import type { GitHubClient } from './github'
import { createAuthHandler } from './handler'
import { createMemorySessionStore } from './sessions'

const config: AuthConfig = {
  githubAppId: '4228880',
  githubClientId: 'Iv1.x',
  githubClientSecret: 'secret',
  appPrivateKey: '',
  webShellOrigin: 'http://localhost:5173',
  secureCookies: false,
  sameSite: 'Lax',
}

function fakeGitHub(overrides: Partial<GitHubClient> = {}): GitHubClient {
  return {
    exchangeCode: async () => 'user-token',
    getUser: async () => ({ login: 'octocat', id: '583231', avatarUrl: 'https://a' }),
    mintRepoToken: async () => ({
      ok: true,
      value: 'ghs_installtoken',
      expiresAt: 1_700_000_000_000,
    }),
    installUrl: async () => 'https://github.com/apps/slideblaster/installations/new',
    ...overrides,
  }
}

function build(gh: Partial<GitHubClient> = {}) {
  const sessions = createMemorySessionStore()
  const handler = createAuthHandler({ config, sessions, github: fakeGitHub(gh) })
  return { handler, sessions }
}

interface ReqOpts {
  cookie?: string
  csrf?: string
  body?: unknown
}
function req(method: string, path: string, opts: ReqOpts = {}): Request {
  const headers = new Headers()
  if (opts.cookie) headers.set('cookie', opts.cookie)
  if (opts.csrf) headers.set('x-sb-csrf', opts.csrf)
  if (opts.body !== undefined) headers.set('content-type', 'application/json')
  return new Request(`http://localhost${path}`, {
    method,
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  })
}

async function seedSession(sessions: ReturnType<typeof createMemorySessionStore>) {
  const { id, csrf } = await sessions.create({
    userToken: 'user-token',
    identity: { login: 'octocat', id: '583231', avatarUrl: 'https://a' },
  })
  return { cookie: `sb_session=${id}`, csrf }
}

describe('auth handler', () => {
  it('GET /me is 401 without a session, identity with one', async () => {
    const { handler, sessions } = build()
    expect((await handler.handle(req('GET', '/me'))).status).toBe(401)

    const { cookie } = await seedSession(sessions)
    const res = await handler.handle(req('GET', '/me', { cookie }))
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ login: 'octocat', id: '583231', avatarUrl: 'https://a' })
  })

  it('GET /capabilities returns the free tier for a session', async () => {
    const { handler, sessions } = build()
    const { cookie } = await seedSession(sessions)
    const res = await handler.handle(req('GET', '/capabilities', { cookie }))
    expect(await res.json()).toEqual({
      premiumCollab: false,
      managedStorage: false,
      collaboratorSeats: 0,
    })
  })

  it('GET /auth/github redirects to OAuth and sets the sb_flow cookie', async () => {
    const { handler } = build()
    const res = await handler.handle(req('GET', '/auth/github?return_to=/deck'))
    expect(res.status).toBe(302)
    expect(res.headers.get('location')).toContain('github.com/login/oauth/authorize')
    expect(res.headers.getSetCookie().join(';')).toContain('sb_flow=')
  })

  it('POST /mint gates on session then csrf, then returns a token', async () => {
    const { handler, sessions } = build()
    const body = { owner: 'octocat', name: 'demo' }

    expect((await handler.handle(req('POST', '/mint', { body }))).status).toBe(401)

    const { cookie, csrf } = await seedSession(sessions)
    expect((await handler.handle(req('POST', '/mint', { cookie, body }))).status).toBe(403) // no csrf

    const ok = await handler.handle(req('POST', '/mint', { cookie, csrf, body }))
    expect(ok.status).toBe(200)
    expect(await ok.json()).toEqual({ value: 'ghs_installtoken', expiresAt: 1_700_000_000_000 })
  })

  it('POST /mint is 403 when the App is not installed on the repo', async () => {
    const { handler, sessions } = build({
      mintRepoToken: async () => ({ ok: false, reason: 'no_repo_access' }),
    })
    const { cookie, csrf } = await seedSession(sessions)
    const res = await handler.handle(
      req('POST', '/mint', { cookie, csrf, body: { owner: 'octocat', name: 'demo' } }),
    )
    expect(res.status).toBe(403)
    expect(await res.json()).toEqual({ error: 'no_repo_access' })
  })

  it('callback establishes a session and redirects to return_to', async () => {
    const { handler, sessions } = build()
    // Seed a pending handoff, then present its state on the callback.
    const state = await sessions.putPending('http://localhost:5173/deck')
    const res = await handler.handle(req('GET', `/auth/github/callback?code=abc&state=${state}`))
    expect(res.status).toBe(302)
    expect(res.headers.get('location')).toBe('http://localhost:5173/deck')
    expect(res.headers.getSetCookie().join(';')).toContain('sb_session=')
  })

  it('POST /signout clears cookies', async () => {
    const { handler, sessions } = build()
    const { cookie } = await seedSession(sessions)
    const res = await handler.handle(req('POST', '/signout', { cookie }))
    expect(res.status).toBe(204)
    expect(res.headers.getSetCookie().join(';')).toContain('sb_session=;')
  })
})
