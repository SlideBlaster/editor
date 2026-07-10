import { afterEach, describe, expect, it } from 'vitest'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { NativeGitAdapter } from './nativeGitAdapter'
import { nodeFs } from '../node'

// Offline, always-on: local history and branching against a real temp dir, using
// the adapter's default node:fs binding. push/pull require a live remote and are
// integration-only (network + a scoped credential); they run through the same
// isomorphic-git code path as the browser adapter's env-gated round-trip and are
// not exercised here.
const dirs: string[] = []

async function makeDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'sb-native-git-'))
  dirs.push(dir)
  return dir
}

afterEach(async () => {
  while (dirs.length) await rm(dirs.pop()!, { recursive: true, force: true })
})

const AUTHOR = { name: 'Dev', email: 'dev@local' }

describe('NativeGitAdapter local history (offline)', () => {
  it('inits a repo, commits, and reads history and status', async () => {
    const dir = await makeDir()
    const git = new NativeGitAdapter({ dir, fs: nodeFs })

    await git.init(dir)
    expect(await git.currentBranch()).toBe('main')
    expect(await git.log()).toEqual([]) // unborn branch: empty history, no throw

    await writeFile(join(dir, 'deck.slideBlaster.md'), '# deck\n')
    const before = await git.status()
    expect(before.files).toEqual([
      { path: 'deck.slideBlaster.md', index: 'unmodified', worktree: 'untracked' },
    ])

    await git.stage(['deck.slideBlaster.md'])
    const oid = await git.commit('first deck', AUTHOR)
    expect(oid).toMatch(/^[0-9a-f]{40}$/)

    const log = await git.log()
    expect(log).toHaveLength(1)
    expect(log[0]?.message).toContain('first deck')
    expect(log[0]?.author).toEqual(AUTHOR)

    const after = await git.status()
    expect(after.branch).toBe('main')
    expect(after.files).toEqual([])
  })

  it('creates a branch without switching, then checks it out', async () => {
    const dir = await makeDir()
    const git = new NativeGitAdapter({ dir, fs: nodeFs })
    await git.init(dir)
    await writeFile(join(dir, 'a.md'), 'a\n')
    await git.stage(['a.md'])
    await git.commit('base', AUTHOR)

    await git.createBranch('feature')
    expect(await git.currentBranch()).toBe('main') // createBranch does not switch

    await git.checkout('feature')
    expect(await git.currentBranch()).toBe('feature')
  })

  it('merges a fast-forward branch cleanly', async () => {
    const dir = await makeDir()
    const git = new NativeGitAdapter({ dir, fs: nodeFs })
    await git.init(dir)
    await writeFile(join(dir, 'a.md'), 'a\n')
    await git.stage(['a.md'])
    await git.commit('base', AUTHOR)

    await git.createBranch('feature')
    await git.checkout('feature')
    await writeFile(join(dir, 'b.md'), 'b\n')
    await git.stage(['b.md'])
    await git.commit('feature work', AUTHOR)

    await git.checkout('main')
    const result = await git.merge('feature')
    expect(result.conflicts).toEqual([])
    expect(result.oid).toMatch(/^[0-9a-f]{40}$/)

    const log = await git.log()
    expect(log.some((commit) => commit.message.includes('feature work'))).toBe(true)
  })
})
