/**
 * Workspace glue between the controller and the Storage port. Contract: see
 * workspace.md.
 *
 * Document discovery (which `.slideBlaster.md` files exist), first-run seeding,
 * last-opened memory, and a debounced autosave — everything createApp needs to
 * make the working copy the source of truth instead of an in-memory string.
 */
import type { AuthPort, GitPort, StoragePort } from '@slideblaster/editor'

/** The port bundle a shell wires in (M3: storage+git+auth; more ports later). */
export interface AppPorts {
  storage: StoragePort
  git: GitPort
  auth: AuthPort
}

export const DOC_EXTENSION = '.slideBlaster.md'
const LAST_DOC_KEY = 'slideblaster.last-doc'
const AUTOSAVE_DELAY_MS = 400

export function isDocPath(path: string): boolean {
  return path.endsWith(DOC_EXTENSION)
}

/** All documents in the working copy, recursive, `.git` excluded, sorted. */
export async function findDocs(storage: StoragePort, dir = ''): Promise<string[]> {
  const docs: string[] = []
  for (const entry of await storage.list(dir)) {
    if (entry.path === '.git') continue
    if (entry.type === 'dir') docs.push(...(await findDocs(storage, entry.path)))
    else if (isDocPath(entry.path)) docs.push(entry.path)
  }
  return docs.sort()
}

/**
 * Pick the document to open on startup: seed the bundled sample on a virgin
 * working copy, then prefer the last-opened doc if it still exists, else the
 * first doc found.
 */
export async function bootDocument(storage: StoragePort, sampleSource: string): Promise<string> {
  let docs = await findDocs(storage)
  if (docs.length === 0) {
    await storage.write(`sample${DOC_EXTENSION}`, sampleSource)
    docs = [`sample${DOC_EXTENSION}`]
  }
  const last = readLastDoc()
  return last && docs.includes(last) ? last : docs[0]!
}

export function rememberDoc(path: string): void {
  try {
    localStorage.setItem(LAST_DOC_KEY, path)
  } catch {
    // storage unavailable (private mode, tests): last-doc memory is best-effort
  }
}

function readLastDoc(): string | null {
  try {
    return localStorage.getItem(LAST_DOC_KEY)
  } catch {
    return null
  }
}

export interface AutosaveOptions {
  /** Called after each completed write (e.g. refresh the git panel). */
  onWrite?: () => void
  delayMs?: number
}

export interface Autosave {
  /** Debounce a write of `source` to `path`; later calls supersede earlier ones. */
  schedule(path: string, source: string): void
  /** Write any pending change now (doc switch, commit, unload). */
  flush(): Promise<void>
  /** Drop any pending change unwritten (the target was deleted/renamed away). */
  discard(): void
}

export function createAutosave(storage: StoragePort, options: AutosaveOptions = {}): Autosave {
  const delayMs = options.delayMs ?? AUTOSAVE_DELAY_MS
  let pending: { path: string; source: string } | null = null
  let timer: ReturnType<typeof setTimeout> | null = null

  const clear = (): void => {
    if (timer !== null) clearTimeout(timer)
    timer = null
  }

  const write = async (): Promise<void> => {
    if (!pending) return
    const { path, source } = pending
    pending = null
    await storage.write(path, source)
    options.onWrite?.()
  }

  return {
    schedule(path, source) {
      pending = { path, source }
      clear()
      timer = setTimeout(() => {
        timer = null
        void write()
      }, delayMs)
    },
    async flush() {
      clear()
      await write()
    },
    discard() {
      clear()
      pending = null
    },
  }
}
