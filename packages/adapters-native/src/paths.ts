/**
 * Pure path helpers shared by the native adapters. Contract: see paths.md.
 *
 * Working-copy paths are always POSIX and relative to the root; only the injected
 * filesystem binding knows the OS layout. These helpers have NO Node dependency, so
 * the adapters that use them bundle unchanged into the Tauri webview.
 */

/** The `code` of a Node-style filesystem error (`ENOENT`, `EEXIST`, ...), if any. */
export function errorCode(error: unknown): string | undefined {
  return error && typeof error === 'object' && 'code' in error
    ? String((error as { code: unknown }).code)
    : undefined
}

/** Normalize a working-copy-relative path: POSIX, no leading `./` or `/`, no `..`. */
export function normalize(path: string): string {
  const parts = path.split('/').filter((part) => part !== '' && part !== '.')
  if (parts.includes('..')) throw new Error(`path escapes the working copy: ${path}`)
  return parts.join('/')
}

/** Join a POSIX base and a single child name (base may be empty for the root). */
export function posixJoin(base: string, name: string): string {
  return base === '' ? name : `${base}/${name}`
}

/** The parent of a normalized POSIX path (`''` for a top-level entry). */
export function posixDirname(rel: string): string {
  const slash = rel.lastIndexOf('/')
  return slash === -1 ? '' : rel.slice(0, slash)
}
