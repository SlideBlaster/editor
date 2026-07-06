/**
 * Theme <-> on-disk JSON (ADR 0017). Contract: see serialize.md.
 *
 * A theme is stored per-project as a structured JSON file (zero-dep: no YAML parser).
 * `serializeTheme` emits canonical, key-sorted, pretty JSON so a theme file diffs and
 * merges per-property like the document format; `parseTheme` validates a file back into
 * the typed `Theme`, throwing `ThemeParseError` with a field path on malformed input.
 */
import type { Theme } from './theme'

export class ThemeParseError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ThemeParseError'
  }
}

/** Recursively sort object keys so serialization is canonical (arrays keep their order). */
function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys)
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const k of Object.keys(value as object).sort()) {
      out[k] = sortKeys((value as Record<string, unknown>)[k])
    }
    return out
  }
  return value
}

/** Canonical JSON for a theme: key-sorted, 2-space indent, trailing newline. Deterministic. */
export function serializeTheme(theme: Theme): string {
  return JSON.stringify(sortKeys(theme), null, 2) + '\n'
}

// --- validation ---

function fail(path: string, msg: string): never {
  throw new ThemeParseError(`${path ? 'theme.' + path : 'theme'}: ${msg}`)
}
function asObject(v: unknown, path: string): Record<string, unknown> {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) fail(path, 'expected an object')
  return v as Record<string, unknown>
}
function asString(v: unknown, path: string): string {
  if (typeof v !== 'string') fail(path, 'expected a string')
  return v
}
function asNumber(v: unknown, path: string): number {
  if (typeof v !== 'number' || Number.isNaN(v)) fail(path, 'expected a number')
  return v
}
function asArray(v: unknown, path: string): unknown[] {
  if (!Array.isArray(v)) fail(path, 'expected an array')
  return v
}

/** Validate a parsed value into a `Theme`, throwing `ThemeParseError` with a field path. */
function validateTheme(raw: unknown): Theme {
  const root = asObject(raw, '')
  asString(root.id, 'id')
  asString(root.name, 'name')

  const style = asObject(root.style, 'style')
  const palette = asObject(style.palette, 'style.palette')
  asString(palette.bg, 'style.palette.bg')
  asString(palette.ink, 'style.palette.ink')
  asString(palette.accent, 'style.palette.accent')
  const type = asObject(style.type, 'style.type')
  asString(type.bodyFamily, 'style.type.bodyFamily')
  asString(type.headingFamily, 'style.type.headingFamily')
  asNumber(type.baseSize, 'style.type.baseSize')
  asNumber(type.scale, 'style.type.scale')
  asNumber(type.lineHeight, 'style.type.lineHeight')
  asObject(style.classes, 'style.classes')
  asNumber(style.nodeDistance, 'style.nodeDistance')

  const layout = asObject(root.layout, 'layout')
  asArray(layout.regions, 'layout.regions').forEach((r, i) => {
    const reg = asObject(r, `layout.regions[${i}]`)
    asString(reg.name, `layout.regions[${i}].name`)
    const rect = asObject(reg.rect, `layout.regions[${i}].rect`)
    for (const k of ['x', 'y', 'w', 'h']) asNumber(rect[k], `layout.regions[${i}].rect.${k}`)
  })

  const furniture = asObject(root.furniture, 'furniture')
  const safe = asObject(furniture.safeArea, 'furniture.safeArea')
  for (const k of ['top', 'right', 'bottom', 'left']) asNumber(safe[k], `furniture.safeArea.${k}`)

  // Shape validated; the value already matches Theme (it is the JSON of a Theme).
  return raw as Theme
}

/** Parse a theme JSON file into a validated `Theme`. */
export function parseTheme(text: string): Theme {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch (e) {
    throw new ThemeParseError('invalid JSON: ' + (e instanceof Error ? e.message : String(e)))
  }
  return validateTheme(raw)
}
