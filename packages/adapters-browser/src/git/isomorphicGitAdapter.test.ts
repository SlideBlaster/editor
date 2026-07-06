import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import * as nodeFs from 'node:fs'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { Server } from 'node:http'
import http from 'isomorphic-git/http/web'
import type { FsClient } from 'isomorphic-git'
import { createProxyServer, listen } from '@slideblaster/git-proxy'
import type { RemoteRef } from '@slideblaster/editor'
import { IsomorphicGitAdapter } from './isomorphicGitAdapter'

// Live round-trip against a real GitHub scratch repo through an in-process instance
// of the first-party proxy. Opt-in via env so CI stays green and offline:
//   SB_GIT_SPIKE_REPO=https://github.com/<owner>/<scratch>.git
//   SB_GIT_SPIKE_TOKEN=<fine-grained PAT, contents:write on that repo only>
// The push is destructive; point it at a throwaway repo.
const repoUrl = process.env.SB_GIT_SPIKE_REPO
const token = process.env.SB_GIT_SPIKE_TOKEN
const enabled = Boolean(repoUrl && token)

describe.skipIf(!enabled)('IsomorphicGitAdapter integration (real GitHub via proxy)', () => {
  let server: Server
  let corsProxy: string

  beforeAll(async () => {
    server = createProxyServer()
    const port = await listen(server, 0)
    corsProxy = `http://localhost:${port}`
  })

  afterAll(() => {
    server?.close()
  })

  it('clones, commits, and pushes through the first-party proxy', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'sb-git-spike-'))
    const remote: RemoteRef = {
      url: repoUrl!,
      token: {
        value: token!,
        repo: parseRepo(repoUrl!),
        scope: 'contents:write',
        expiresAt: Date.now() + 3_600_000,
      },
    }
    const adapter = new IsomorphicGitAdapter({
      fs: nodeFs as unknown as FsClient,
      http,
      corsProxy,
      dir,
    })

    await adapter.clone(remote, dir)

    writeFileSync(join(dir, 'SPIKE.md'), `browser-git spike ${new Date().toISOString()}\n`)
    await adapter.stage(['SPIKE.md'])
    const oid = await adapter.commit('spike: browser-git round-trip', {
      name: 'SlideBlaster Spike',
      email: 'spike@slideblaster.dev',
    })
    expect(oid).toMatch(/^[0-9a-f]{40}$/)

    const pushed = await adapter.push(remote)
    expect(pushed.oid).toBe(oid)

    const log = await adapter.log({ depth: 1 })
    expect(log[0]?.message).toContain('browser-git round-trip')
  }, 60_000)
})

function parseRepo(url: string): RemoteRef['token']['repo'] {
  const match = url.replace(/\.git$/, '').match(/github\.com[/:]([^/]+)\/([^/]+)$/)
  return { owner: match?.[1] ?? '', name: match?.[2] ?? '' }
}

// Local-only history — the offline M3 path. No network, always on.
describe('IsomorphicGitAdapter local history (offline)', () => {
  it('inits a repo, commits, and reads history and status', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'sb-git-local-'))
    const adapter = new IsomorphicGitAdapter({
      fs: nodeFs as unknown as FsClient,
      http,
      dir,
    })

    await adapter.init(dir)
    expect(await adapter.currentBranch()).toBe('main')
    expect(await adapter.log()).toEqual([]) // unborn branch: empty history, no throw

    writeFileSync(join(dir, 'deck.slideBlaster.md'), '# deck\n')
    const before = await adapter.status()
    expect(before.files).toEqual([
      { path: 'deck.slideBlaster.md', index: 'unmodified', worktree: 'untracked' },
    ])

    await adapter.stage(['deck.slideBlaster.md'])
    const oid = await adapter.commit('first deck', { name: 'Dev', email: 'dev@local' })
    expect(oid).toMatch(/^[0-9a-f]{40}$/)

    const log = await adapter.log()
    expect(log).toHaveLength(1)
    expect(log[0]?.message).toContain('first deck')
    expect(log[0]?.author).toEqual({ name: 'Dev', email: 'dev@local' })

    const after = await adapter.status()
    expect(after.branch).toBe('main')
    expect(after.files).toEqual([])
  })
})
