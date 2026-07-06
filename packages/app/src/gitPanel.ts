/**
 * The source-control sidebar panel. Contract: see gitPanel.md.
 *
 * Local history over the working copy (M3): worktree status, stage-all commit,
 * and the log — through the Git port. Identity comes from the Auth port
 * (currentIdentity -> commit author), so the panel already works against the
 * real Auth service when it lands (M4); today the dev adapter answers.
 */
import type { AuthPort, GitPort, GitStatus } from '@slideblaster/editor'

export interface GitPanelDeps {
  git: GitPort
  auth: AuthPort
  /** Flush pending edits (autosave) so the commit includes the latest source. */
  beforeCommit(): Promise<void>
  /** Surface a failure outside the panel (status bar). */
  onError(message: string): void
}

export interface GitPanelHandle {
  /** Reload status + log and repaint. Call after any working-copy mutation. */
  refresh(): Promise<void>
}

const LOG_DEPTH = 20

export function createGitPanel(host: HTMLElement, deps: GitPanelDeps): GitPanelHandle {
  let message = ''
  let busy = false

  const refresh = async (): Promise<void> => {
    try {
      const [status, log] = await Promise.all([
        deps.git.status(),
        deps.git.log({ depth: LOG_DEPTH }),
      ])
      paint(status, log)
    } catch (err) {
      deps.onError(`git: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  const commit = async (): Promise<void> => {
    const identity = deps.auth.currentIdentity()
    if (!identity || busy) return
    busy = true
    try {
      await deps.beforeCommit()
      // The flush may have changed the worktree; stage from a fresh status.
      const fresh = await deps.git.status()
      const paths = fresh.files.map((file) => file.path)
      if (paths.length > 0) {
        await deps.git.stage(paths)
        await deps.git.commit(message.trim() || 'update slides', {
          name: identity.login,
          email: `${identity.login}@users.noreply.github.com`,
        })
        message = ''
      }
    } catch (err) {
      deps.onError(`commit failed: ${err instanceof Error ? err.message : String(err)}`)
    } finally {
      busy = false
      void refresh()
    }
  }

  const paint = (status: GitStatus, log: Awaited<ReturnType<GitPort['log']>>): void => {
    host.replaceChildren()

    const head = document.createElement('div')
    head.className = 'side-title'
    const label = document.createElement('span')
    label.textContent = `Source control · ${status.branch}`
    head.append(label)
    host.append(head)

    paintIdentity(host)
    paintChanges(host, status)
    paintCommitBox(host, status)
    paintLog(host, log)
  }

  const paintIdentity = (host: HTMLElement): void => {
    const identity = deps.auth.currentIdentity()
    const row = document.createElement('div')
    row.className = 'git-identity'
    const who = document.createElement('span')
    who.textContent = identity ? `@${identity.login}` : 'not signed in'
    const action = document.createElement('button')
    action.type = 'button'
    action.textContent = identity ? 'Sign out' : 'Sign in'
    action.addEventListener('click', () => {
      void (identity ? deps.auth.signOut() : deps.auth.signIn()).then(refresh)
    })
    row.append(who, action)
    host.append(row)
  }

  const paintChanges = (host: HTMLElement, status: GitStatus): void => {
    const list = document.createElement('ul')
    list.className = 'git-changes'
    if (status.files.length === 0) {
      const item = document.createElement('li')
      item.className = 'git-clean'
      item.textContent = 'working copy clean'
      list.append(item)
    }
    for (const file of status.files) {
      const item = document.createElement('li')
      const badge = document.createElement('span')
      badge.className = 'git-badge'
      badge.textContent = stateLetter(file.worktree === 'unmodified' ? file.index : file.worktree)
      const path = document.createElement('span')
      path.textContent = file.path
      path.title = `index: ${file.index} · worktree: ${file.worktree}`
      item.append(badge, path)
      list.append(item)
    }
    host.append(list)
  }

  const paintCommitBox = (host: HTMLElement, status: GitStatus): void => {
    const identity = deps.auth.currentIdentity()
    const box = document.createElement('div')
    box.className = 'git-commit'
    const input = document.createElement('input')
    input.type = 'text'
    input.placeholder = 'commit message'
    input.value = message
    input.addEventListener('input', () => {
      message = input.value
    })
    const button = document.createElement('button')
    button.type = 'button'
    button.textContent = 'Commit'
    button.disabled = busy || status.files.length === 0 || !identity
    button.title = !identity
      ? 'Sign in to commit'
      : status.files.length === 0
        ? 'No changes'
        : 'Stage all changes and commit'
    button.addEventListener('click', () => void commit())
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !button.disabled) void commit()
    })
    box.append(input, button)
    host.append(box)
  }

  const paintLog = (host: HTMLElement, log: Awaited<ReturnType<GitPort['log']>>): void => {
    const list = document.createElement('ul')
    list.className = 'git-log'
    if (log.length === 0) {
      const item = document.createElement('li')
      item.className = 'git-clean'
      item.textContent = 'no commits yet'
      list.append(item)
    }
    for (const entry of log) {
      const item = document.createElement('li')
      const subject = document.createElement('span')
      subject.className = 'git-subject'
      subject.textContent = entry.message.split('\n')[0] ?? ''
      const meta = document.createElement('span')
      meta.className = 'git-meta'
      meta.textContent = `${entry.oid.slice(0, 7)} · ${entry.author.name} · ${when(entry.timestamp)}`
      item.append(subject, meta)
      list.append(item)
    }
    host.append(list)
  }

  return { refresh }
}

function stateLetter(state: string): string {
  switch (state) {
    case 'untracked':
      return 'U'
    case 'added':
      return 'A'
    case 'modified':
      return 'M'
    case 'deleted':
      return 'D'
    default:
      return '·'
  }
}

function when(timestamp: number): string {
  const date = new Date(timestamp)
  const today = new Date()
  const sameDay = date.toDateString() === today.toDateString()
  return sameDay
    ? date.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
    : date.toLocaleDateString()
}
