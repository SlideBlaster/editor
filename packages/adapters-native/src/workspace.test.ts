import { afterEach, describe, expect, it } from 'vitest'
import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createNodeWorkspace } from './node'

const dirs: string[] = []

async function makeDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'sb-native-ws-'))
  dirs.push(dir)
  return dir
}

afterEach(async () => {
  while (dirs.length) await rm(dirs.pop()!, { recursive: true, force: true })
})

const AUTHOR = { name: 'Dev', email: 'dev@local' }

describe('createNativeWorkspace', () => {
  it('bootstraps a local repo and shares the dir between storage and git', async () => {
    const dir = await makeDir()
    const { storage, git } = await createNodeWorkspace(dir)

    expect((await stat(join(dir, '.git'))).isDirectory()).toBe(true)
    expect(await git.currentBranch()).toBe('main')
    expect(await git.log()).toEqual([])

    // The load-bearing seam: a storage.write is immediately visible to git.status().
    await storage.write('deck.slideBlaster.md', '# hi\n')
    const status = await git.status()
    expect(status.files).toEqual([
      { path: 'deck.slideBlaster.md', index: 'unmodified', worktree: 'untracked' },
    ])

    await git.stage(['deck.slideBlaster.md'])
    const oid = await git.commit('first', AUTHOR)
    expect(oid).toMatch(/^[0-9a-f]{40}$/)
    expect(await git.log()).toHaveLength(1)
  })

  it('leaves an existing repository untouched on re-open', async () => {
    const dir = await makeDir()
    const first = await createNodeWorkspace(dir)
    await first.storage.write('deck.slideBlaster.md', '# hi\n')
    await first.git.stage(['deck.slideBlaster.md'])
    const oid = await first.git.commit('first', AUTHOR)

    const second = await createNodeWorkspace(dir)
    const log = await second.git.log()
    expect(log).toHaveLength(1)
    expect(log[0]?.oid).toBe(oid)
    expect(await second.storage.readText('deck.slideBlaster.md')).toBe('# hi\n')
  })
})
