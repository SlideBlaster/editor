/**
 * Working-copy zip codec. Contract: see workspaceZip.md.
 *
 * A no-GitHub way to move a whole working copy between machines (and between the web
 * and desktop shells): export every file under the storage root into one `.zip`, and
 * import a `.zip` back in. Both operate purely over the `StoragePort` — no DOM, no
 * browser APIs — so any shell (web or desktop/native) reuses them; the download/upload
 * glue is the only platform-specific part and lives in the shell/app chrome.
 */
import type { StoragePort } from '@slideblaster/editor'
import { zipSync, unzipSync } from 'fflate'

/** Why an entry was skipped on import (surfaced for UI feedback). */
export type SkipReason = 'unsafe-path' | 'git-internal'

export interface ImportZipOptions {
  /** Called after each entry successfully written to the working copy. */
  onWrite?(path: string): void
  /** Called for each entry skipped for safety (zip-slip / absolute path, or `.git`). */
  onSkip?(name: string, reason: SkipReason): void
}

/**
 * Read every file under the working-copy root (recursively, `.git` excluded) and pack
 * it into a zip. Mirrors the file-tree walk (`findDocs`/`listFilesUnder`): entries are
 * the full working-copy-relative POSIX paths. Paths are sorted so the archive is
 * deterministic for a given tree.
 */
export async function exportWorkspaceZip(storage: StoragePort): Promise<Uint8Array> {
  const paths: string[] = []
  await collectFiles(storage, '', paths)
  paths.sort()

  const entries: Record<string, Uint8Array> = {}
  for (const path of paths) entries[path] = await storage.read(path)
  return zipSync(entries)
}

/**
 * Unzip `bytes` and write each entry back through the Storage port. Every entry path is
 * sanitized first (see `sanitizeZipEntryPath`): absolute paths and any `..` segment are
 * refused (zip-slip), and `.git` internals are skipped — so a crafted archive can never
 * write outside the working-copy root or corrupt the repository.
 *
 * Overwrite behavior: files are **merged into the root**, last-writer-wins on a matching
 * path (exactly `storage.write`'s documented contract); files present in the working copy
 * but absent from the zip are left untouched (a merge, not a mirror). See workspaceZip.md
 * for why root-merge — not namespacing under a prefix — is the safe and correct default.
 */
export async function importWorkspaceZip(
  storage: StoragePort,
  bytes: Uint8Array,
  opts: ImportZipOptions = {},
): Promise<void> {
  const files = unzipSync(bytes)
  for (const [name, data] of Object.entries(files).sort(([a], [b]) =>
    a < b ? -1 : a > b ? 1 : 0,
  )) {
    // fflate lists explicit directory entries with a trailing slash and no bytes.
    if (name.endsWith('/')) continue
    const safe = sanitizeZipEntryPath(name)
    if (safe === null) {
      opts.onSkip?.(name, 'unsafe-path')
      continue
    }
    if (isGitPath(safe)) {
      opts.onSkip?.(name, 'git-internal')
      continue
    }
    await storage.write(safe, data)
    opts.onWrite?.(safe)
  }
}

/**
 * Normalize a zip entry name to a safe working-copy-relative path, or `null` if it must
 * be refused. Rejects absolute paths (POSIX root or Windows drive) and any `..` segment;
 * collapses `.` and empty segments; treats a backslash as a separator (Windows archives).
 * A non-null result never starts with `/` and never contains `..`, so writing it can only
 * land inside the root. Exported so callers (and tests) can reason about the guarantee.
 */
export function sanitizeZipEntryPath(name: string): string | null {
  const normalized = name.replace(/\\/g, '/') // Windows separators -> POSIX
  if (normalized.startsWith('/')) return null // absolute (POSIX root)
  if (/^[a-zA-Z]:/.test(normalized)) return null // absolute (Windows drive, e.g. C:\)

  const segments: string[] = []
  for (const segment of normalized.split('/')) {
    if (segment === '' || segment === '.') continue // collapse empty + current-dir
    if (segment === '..') return null // parent traversal -> zip-slip
    segments.push(segment)
  }
  return segments.length > 0 ? segments.join('/') : null // empty / pure-directory entry
}

/** A path inside a git repository's `.git` dir (any level) — never exported or imported. */
function isGitPath(path: string): boolean {
  return path.split('/').some((segment) => segment === '.git')
}

/** Collect every file path under `dir` recursively, `.git` excluded (mirrors the file-tree walk). */
async function collectFiles(storage: StoragePort, dir: string, out: string[]): Promise<void> {
  for (const entry of await storage.list(dir)) {
    if (isGitPath(entry.path)) continue
    if (entry.type === 'dir') await collectFiles(storage, entry.path, out)
    else out.push(entry.path)
  }
}
