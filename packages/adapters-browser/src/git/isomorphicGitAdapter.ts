/**
 * Git port implemented with isomorphic-git. Contract: see isomorphicGitAdapter.md.
 *
 * Filesystem and HTTP client are injected, so the same logic runs in the browser
 * (LightningFS + isomorphic-git/http/web) and under Node tests (node:fs + the same
 * web http client), both pointing `corsProxy` at the first-party git-proxy.
 */
import * as git from 'isomorphic-git'
import type { AuthCallback, FsClient, HttpClient } from 'isomorphic-git'
import type {
  Author,
  Commit,
  GitPort,
  GitStatus,
  IndexState,
  Oid,
  RemoteRef,
  SyncResult,
  WorktreeState,
} from '@slideblaster/editor'

export interface IsomorphicGitAdapterDeps {
  fs: FsClient
  http: HttpClient
  /** URL of the first-party CORS proxy (required in the browser). */
  corsProxy?: string
  /** Working-copy root inside `fs`. */
  dir?: string
  /** Committer used for merge commits created by `pull` / `merge`. */
  mergeAuthor?: Author
}

const DEFAULT_DIR = '/repo'
const DEFAULT_MERGE_AUTHOR: Author = { name: 'SlideBlaster', email: 'sync@slideblaster.dev' }

// GitHub accepts a PAT or App installation token as HTTP basic auth with the
// magic username `x-access-token`.
function tokenAuth(token: RemoteRef['token']): AuthCallback {
  return () => ({ username: 'x-access-token', password: token.value })
}

export class IsomorphicGitAdapter implements GitPort {
  private readonly fs: FsClient
  private readonly http: HttpClient
  private readonly corsProxy: string | undefined
  private readonly mergeAuthor: Author
  private dir: string

  constructor(deps: IsomorphicGitAdapterDeps) {
    this.fs = deps.fs
    this.http = deps.http
    this.corsProxy = deps.corsProxy
    this.dir = deps.dir ?? DEFAULT_DIR
    this.mergeAuthor = deps.mergeAuthor ?? DEFAULT_MERGE_AUTHOR
  }

  async clone(remote: RemoteRef, dir: string): Promise<void> {
    this.dir = dir
    await git.clone({
      fs: this.fs,
      http: this.http,
      dir,
      url: remote.url,
      corsProxy: this.corsProxy,
      onAuth: tokenAuth(remote.token),
      singleBranch: true,
      depth: 50,
    })
  }

  async status(): Promise<GitStatus> {
    const branch =
      (await git.currentBranch({ fs: this.fs, dir: this.dir, fullname: false })) ?? 'HEAD'
    const matrix = await git.statusMatrix({ fs: this.fs, dir: this.dir })
    const files = matrix
      .filter(([, head, workdir, stage]) => !(head === 1 && workdir === 1 && stage === 1))
      .map(toFileStatus)
    // Ahead/behind requires comparing against the tracked remote ref; deferred
    // past the spike (not needed to prove the round-trip).
    return { branch, ahead: 0, behind: 0, files }
  }

  async stage(paths: string[]): Promise<void> {
    for (const filepath of paths) {
      const row = (await git.statusMatrix({ fs: this.fs, dir: this.dir, filepaths: [filepath] }))[0]
      const workdir = row?.[2] ?? 0
      if (workdir === 0) await git.remove({ fs: this.fs, dir: this.dir, filepath })
      else await git.add({ fs: this.fs, dir: this.dir, filepath })
    }
  }

  async commit(message: string, author: Author): Promise<Oid> {
    return git.commit({
      fs: this.fs,
      dir: this.dir,
      message,
      author: { name: author.name, email: author.email },
    })
  }

  async log(options?: { depth?: number; ref?: string }): Promise<Commit[]> {
    const entries = await git.log({
      fs: this.fs,
      dir: this.dir,
      depth: options?.depth ?? 50,
      ref: options?.ref,
    })
    return entries.map((entry): Commit => ({
      oid: entry.oid,
      message: entry.commit.message,
      author: { name: entry.commit.author.name, email: entry.commit.author.email },
      timestamp: entry.commit.author.timestamp * 1000,
      parents: entry.commit.parent,
    }))
  }

  async currentBranch(): Promise<string> {
    return (await git.currentBranch({ fs: this.fs, dir: this.dir, fullname: false })) ?? 'HEAD'
  }

  async checkout(ref: string): Promise<void> {
    await git.checkout({ fs: this.fs, dir: this.dir, ref })
  }

  async createBranch(name: string): Promise<void> {
    await git.branch({ fs: this.fs, dir: this.dir, ref: name, checkout: false })
  }

  async merge(theirs: string): Promise<{ oid: Oid; conflicts: string[] }> {
    try {
      const result = await git.merge({
        fs: this.fs,
        dir: this.dir,
        theirs,
        author: this.mergeAuthor,
        abortOnConflict: true,
      })
      const oid = result.oid ?? (await git.resolveRef({ fs: this.fs, dir: this.dir, ref: 'HEAD' }))
      return { oid, conflicts: [] }
    } catch (error) {
      const conflicts = mergeConflicts(error)
      if (conflicts) {
        const oid = await git.resolveRef({ fs: this.fs, dir: this.dir, ref: 'HEAD' })
        return { oid, conflicts }
      }
      throw error
    }
  }

  async pull(remote: RemoteRef): Promise<SyncResult> {
    try {
      await git.pull({
        fs: this.fs,
        http: this.http,
        dir: this.dir,
        corsProxy: this.corsProxy,
        onAuth: tokenAuth(remote.token),
        singleBranch: true,
        fastForward: true,
        author: this.mergeAuthor,
      })
      const oid = await git.resolveRef({ fs: this.fs, dir: this.dir, ref: 'HEAD' })
      return { oid, fastForward: true, conflicts: [] }
    } catch (error) {
      const conflicts = mergeConflicts(error)
      if (conflicts) {
        const oid = await git.resolveRef({ fs: this.fs, dir: this.dir, ref: 'HEAD' })
        return { oid, fastForward: false, conflicts }
      }
      throw error
    }
  }

  async push(remote: RemoteRef): Promise<SyncResult> {
    const result = await git.push({
      fs: this.fs,
      http: this.http,
      dir: this.dir,
      corsProxy: this.corsProxy,
      onAuth: tokenAuth(remote.token),
      remote: 'origin',
    })
    if (result.error) throw new Error(`push rejected: ${result.error}`)
    const oid = await git.resolveRef({ fs: this.fs, dir: this.dir, ref: 'HEAD' })
    return { oid, fastForward: true, conflicts: [] }
  }
}

// isomorphic-git statusMatrix rows: [filepath, headStatus, workdirStatus, stageStatus].
type StatusRow = [string, number, number, number]

function toFileStatus(row: StatusRow): GitStatus['files'][number] {
  const [path, head, workdir, stage] = row

  let index: IndexState = 'unmodified'
  if (head === 0 && stage > 0) index = 'added'
  else if (head === 1 && stage === 0) index = 'deleted'
  else if (head === 1 && stage > 1) index = 'modified'

  let worktree: WorktreeState = 'unmodified'
  if (workdir === 0 && (head === 1 || stage > 0)) worktree = 'deleted'
  else if (head === 0 && stage === 0) worktree = 'untracked'
  else if (workdir === 2) worktree = 'modified'

  return { path, index, worktree }
}

function mergeConflicts(error: unknown): string[] | null {
  if (
    error &&
    typeof error === 'object' &&
    'code' in error &&
    error.code === 'MergeConflictError'
  ) {
    const data = (error as { data?: { filepaths?: string[] } }).data
    return data?.filepaths ?? []
  }
  return null
}
