/**
 * Master-layout region geometry (ADR 0017). Contract: see regions.md.
 *
 * A theme region is a `RelRect` — fractions of the slide box, origin top-left, y-down.
 * These pure helpers resolve regions against a concrete slide box (default 16x9, y-up)
 * for the editor: slide-space rects, snap guides, and hit-testing for creation seeding.
 * Regions are editor-only affordances — never rendered into output (ADR 0002 holds).
 */
import type { Point } from '../model/tikz'
import { getMeta, type DocumentMeta } from '../model/document'
import type { Anchor9, Theme, Region } from './theme'

/** The slide coordinate box (aspect-ratio-configurable, ADR 0017); y-up. */
export interface SlideBox {
  width: number
  height: number
}

/** The default 16:9 slide box (matches the render/measure path). */
export const DEFAULT_SLIDE_BOX: SlideBox = { width: 16, height: 9 }

/** Parse an `aspect`/`aspectRatio` frontmatter value (`16:9`, `4:3`, `16x10`) to a box.
 *  Height is fixed at 9 so y-coordinates are stable across ratios; only the x extent
 *  changes (width = ratio * 9). Unparseable values fall back to the default box. */
function parseAspect(raw: string): SlideBox {
  const m = /^\s*(\d+(?:\.\d+)?)\s*[:x/]\s*(\d+(?:\.\d+)?)\s*$/.exec(raw)
  if (m === null) return DEFAULT_SLIDE_BOX
  const w = Number(m[1])
  const h = Number(m[2])
  if (!(w > 0 && h > 0)) return DEFAULT_SLIDE_BOX
  return { width: (w / h) * 9, height: 9 }
}

/** The slide box for a document, from its `aspect`/`aspectRatio` frontmatter (ADR 0017);
 *  default 16x9. Theme geometry (regions, furniture) resolves against this box. */
export function slideBoxFromMeta(meta: DocumentMeta): SlideBox {
  const raw = getMeta(meta, 'aspect') ?? getMeta(meta, 'aspectRatio')
  return raw !== undefined ? parseAspect(raw) : DEFAULT_SLIDE_BOX
}

/** A region resolved to slide-space coordinates (y-up: `top` >= `bottom`). */
export interface RegionRect {
  name: string
  left: number
  right: number
  bottom: number
  top: number
  defaultClass?: string
  defaultAnchor?: Anchor9
}

/** Resolve one region's `RelRect` (y-down fractions) to a slide-space rect (y-up). */
function toRect(r: Region, box: SlideBox): RegionRect {
  return {
    name: r.name,
    left: r.rect.x * box.width,
    right: (r.rect.x + r.rect.w) * box.width,
    top: box.height * (1 - r.rect.y),
    bottom: box.height * (1 - r.rect.y - r.rect.h),
    ...(r.defaultClass !== undefined ? { defaultClass: r.defaultClass } : {}),
    ...(r.defaultAnchor !== undefined ? { defaultAnchor: r.defaultAnchor } : {}),
  }
}

/** A theme's regions as slide-space rects (y-up) against a slide box. */
export function regionRects(theme: Theme, box: SlideBox = DEFAULT_SLIDE_BOX): RegionRect[] {
  return theme.layout.regions.map((r) => toRect(r, box))
}

/** The region containing a slide-space point (first match), for creation seeding. */
export function regionAt(
  theme: Theme,
  point: Point,
  box: SlideBox = DEFAULT_SLIDE_BOX,
): RegionRect | undefined {
  return regionRects(theme, box).find(
    (r) => point.x >= r.left && point.x <= r.right && point.y >= r.bottom && point.y <= r.top,
  )
}

/** Snap-guide coordinates the regions contribute (x edges + centre, y edges + centre). */
export interface RegionGuides {
  xs: number[]
  ys: number[]
}

/** Region edges and centres as snap targets, merged into the drag guide set. */
export function regionGuides(theme: Theme, box: SlideBox = DEFAULT_SLIDE_BOX): RegionGuides {
  const xs: number[] = []
  const ys: number[] = []
  for (const r of regionRects(theme, box)) {
    xs.push(r.left, (r.left + r.right) / 2, r.right)
    ys.push(r.bottom, (r.bottom + r.top) / 2, r.top)
  }
  return { xs, ys }
}
