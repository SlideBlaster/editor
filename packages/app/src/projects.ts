/**
 * Project registry. Contract: see projects.md.
 *
 * A project is one git working copy (= one repo): it holds any files and dirs,
 * and its `*.slideBlaster.md` files are its presentations (product.md, ui.md).
 * This registry is just the *metadata* list the landing page shows — id, name,
 * timestamps. The working copy itself lives at `/projects/<id>` in the browser
 * FS and is created lazily by the shell (`createBrowserWorkspace({ dir })`) when
 * the project is opened; the registry never touches storage or git.
 */

export interface Project {
  /** Stable id; also the working-copy directory name (`/projects/<id>`). */
  id: string
  name: string
  /** Epoch milliseconds. */
  createdAt: number
  /** Epoch milliseconds; drives the most-recent-first ordering. */
  lastOpenedAt: number
}

/** The subset of the Web Storage API the registry needs (localStorage / a stub). */
export type StorageLike = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>

export interface ProjectRegistry {
  /** Every project, most-recently-opened first. */
  list(): Project[]
  get(id: string): Project | null
  /** Create a project (fresh id + timestamps) and persist it. */
  create(name: string): Project
  /** Mark a project opened now (moves it to the front of the list). */
  touch(id: string): void
  /** Forget a project's metadata. The working-copy dir is left in place. */
  remove(id: string): void
}

const STORAGE_KEY = 'slideblaster.projects'
const DEFAULT_NAME = 'Untitled project'

/** localStorage when available (browser), else an in-memory map (tests/SSR). */
function defaultStore(): StorageLike {
  if (typeof localStorage !== 'undefined') return localStorage
  const memory = new Map<string, string>()
  return {
    getItem: (key) => memory.get(key) ?? null,
    setItem: (key, value) => void memory.set(key, value),
    removeItem: (key) => void memory.delete(key),
  }
}

export function createProjectRegistry(store: StorageLike = defaultStore()): ProjectRegistry {
  const read = (): Project[] => {
    try {
      const raw = store.getItem(STORAGE_KEY)
      if (!raw) return []
      const parsed = JSON.parse(raw) as unknown
      return Array.isArray(parsed) ? (parsed.filter(isProject) as Project[]) : []
    } catch {
      return []
    }
  }

  const write = (projects: Project[]): void => {
    try {
      store.setItem(STORAGE_KEY, JSON.stringify(projects))
    } catch {
      // storage unavailable (private mode, tests): best-effort, like the rest of
      // the browser-side memory in this app.
    }
  }

  const sorted = (projects: Project[]): Project[] =>
    [...projects].sort((a, b) => b.lastOpenedAt - a.lastOpenedAt)

  return {
    list() {
      return sorted(read())
    },
    get(id) {
      return read().find((project) => project.id === id) ?? null
    },
    create(name) {
      const now = Date.now()
      const project: Project = {
        id: crypto.randomUUID(),
        name: name.trim() || DEFAULT_NAME,
        createdAt: now,
        lastOpenedAt: now,
      }
      write([project, ...read()])
      return project
    },
    touch(id) {
      const projects = read()
      const project = projects.find((p) => p.id === id)
      if (!project) return
      project.lastOpenedAt = Date.now()
      // Move to the front so ordering is stable even when several opens land in
      // the same millisecond (the timestamp sort would otherwise tie).
      write([project, ...projects.filter((p) => p.id !== id)])
    },
    remove(id) {
      write(read().filter((project) => project.id !== id))
    },
  }
}

function isProject(value: unknown): value is Project {
  if (!value || typeof value !== 'object') return false
  const p = value as Record<string, unknown>
  return (
    typeof p.id === 'string' &&
    typeof p.name === 'string' &&
    typeof p.createdAt === 'number' &&
    typeof p.lastOpenedAt === 'number'
  )
}
