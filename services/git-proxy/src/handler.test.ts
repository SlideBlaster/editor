import { describe, it, expect } from 'vitest'
import { handleProxy, resolveTarget } from './handler'

const HOST = 'github.com'
const proxied = (path: string, init?: RequestInit) => new Request(`http://proxy.local${path}`, init)

describe('resolveTarget allowlist', () => {
  it('accepts github git-smart-http endpoints', () => {
    const target = resolveTarget(
      proxied('/github.com/octocat/hello.git/info/refs?service=git-upload-pack'),
      HOST,
    )
    expect(target?.toString()).toBe(
      'https://github.com/octocat/hello.git/info/refs?service=git-upload-pack',
    )
  })

  it('accepts repos addressed without the .git suffix', () => {
    const target = resolveTarget(proxied('/github.com/octocat/hello/git-upload-pack'), HOST)
    expect(target?.pathname).toBe('/octocat/hello/git-upload-pack')
  })

  it('rejects a non-github host', () => {
    expect(resolveTarget(proxied('/evil.com/o/r/info/refs'), HOST)).toBeNull()
  })

  it('rejects a look-alike subdomain host', () => {
    expect(resolveTarget(proxied('/github.com.evil.com/o/r/info/refs'), HOST)).toBeNull()
  })

  it('rejects non git-smart-http paths (e.g. the contents API)', () => {
    expect(resolveTarget(proxied('/github.com/o/r/contents/secret.env'), HOST)).toBeNull()
  })

  it('rejects a plaintext http upstream', () => {
    expect(resolveTarget(proxied('/http://github.com/o/r/info/refs'), HOST)).toBeNull()
  })

  it('rejects an empty target', () => {
    expect(resolveTarget(proxied('/'), HOST)).toBeNull()
  })
})

describe('handleProxy CORS envelope (no upstream call)', () => {
  it('answers preflight without forwarding', async () => {
    const res = await handleProxy(proxied('/github.com/o/r.git/info/refs', { method: 'OPTIONS' }))
    expect(res.status).toBe(204)
    expect(res.headers.get('access-control-allow-methods')).toContain('POST')
    expect(res.headers.get('access-control-allow-headers')).toContain('authorization')
  })

  it('rejects disallowed methods before touching the network', async () => {
    const res = await handleProxy(proxied('/github.com/o/r.git/info/refs', { method: 'PUT' }))
    expect(res.status).toBe(405)
  })

  it('denies a forbidden target with a CORS-readable 403', async () => {
    const res = await handleProxy(proxied('/evil.com/o/r/info/refs'))
    expect(res.status).toBe(403)
    expect(res.headers.get('access-control-allow-origin')).toBe('*')
  })

  it('echoes the request origin on denials so the browser can read them', async () => {
    const res = await handleProxy(
      proxied('/evil.com/o/r/info/refs', { headers: { origin: 'https://app.slideblaster.dev' } }),
    )
    expect(res.headers.get('access-control-allow-origin')).toBe('https://app.slideblaster.dev')
  })
})
