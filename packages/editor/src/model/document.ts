/**
 * The document model: a presentation as frontmatter + ordered slides.
 * Contract: see document.md.
 */
import type { TikzPicture } from './tikz'

export interface SlideDocument {
  meta: DocumentMeta
  frames: Frame[]
}

/**
 * Frontmatter as an ordered list of raw key/value entries. Keeping the file order
 * and raw values makes the round-trip lossless (A1 scope); a typed schema layers on
 * top later.
 */
export interface DocumentMeta {
  entries: FrontmatterEntry[]
}

export interface FrontmatterEntry {
  key: string
  value: string
}

/**
 * One slide. The heading supplies `title` as navigation metadata only (outline /
 * thumbnails); the visible content — including any title node — lives in `picture`
 * (a slide is a TikZ picture, ADR 0004). `id` is the stable slide identity from the
 * heading's `{#id}`.
 */
export interface Frame {
  id: string
  title: string
  picture: TikzPicture
}

/** First value for `key` in document order, or undefined. */
export function getMeta(meta: DocumentMeta, key: string): string | undefined {
  return meta.entries.find((entry) => entry.key === key)?.value
}
