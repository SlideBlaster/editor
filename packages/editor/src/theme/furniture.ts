/**
 * Furniture (deck-wide chrome) markup + CSS (ADR 0017). Contract: see furniture.md.
 *
 * Furniture — page number, logo, header/footer bands — is theme-defined chrome the
 * renderer draws on every slide, placed by a 3x3 anchor grid against a safe-area inset
 * (relative, so it holds across aspect ratios). It is frame, not author content (ADR
 * 0002 holds), and part of the render/export DOM (ADR 0014), so it prints. Pure strings.
 */
import type { Anchor9, BandFurniture, Theme } from './theme'

/** Per-slide context furniture needs: the 1-based number is `index + 1` of `total`. */
export interface FurnitureContext {
  /** 0-based slide index. */
  index: number
  /** Deck length. */
  total: number
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

/** Expand a template: `{n}` -> 1-based index, `{total}` -> deck length. */
function expand(template: string, ctx: FurnitureContext): string {
  return template.replace(/\{n\}/g, String(ctx.index + 1)).replace(/\{total\}/g, String(ctx.total))
}

function anchorClass(a: Anchor9): string {
  return `sb-fn-anchor sb-fn-${a}`
}

function band(cls: string, b: BandFurniture, ctx: FurnitureContext): string {
  const slot = (name: 'left' | 'center' | 'right'): string => {
    const t = b.slots[name]
    return `<span class="sb-fn-slot sb-fn-slot-${name}">${t ? escapeHtml(expand(t, ctx)) : ''}</span>`
  }
  const extra = b.class ? ` sb-style-${b.class}` : ''
  return `<div class="${cls} sb-fn-band${extra}">${slot('left')}${slot('center')}${slot('right')}</div>`
}

/**
 * The furniture chrome layer for one slide (`<div class="sb-furniture">…`), or '' when
 * the theme shows no furniture. Meant to sit inside `.sb-slide` (a positioned box).
 */
export function furnitureHtml(theme: Theme, ctx: FurnitureContext): string {
  const f = theme.furniture
  const parts: string[] = []
  if (f.pageNumber?.show) {
    const cls = [anchorClass(f.pageNumber.anchor), 'sb-fn-pagenumber']
    if (f.pageNumber.class) cls.push(`sb-style-${f.pageNumber.class}`)
    parts.push(
      `<div class="${cls.join(' ')}">${escapeHtml(expand(f.pageNumber.format ?? '{n}', ctx))}</div>`,
    )
  }
  if (f.logo) {
    parts.push(
      `<img class="${anchorClass(f.logo.anchor)} sb-fn-logo" src="${escapeHtml(f.logo.asset)}" alt="" ` +
        `style="width:${f.logo.size * 100}%"/>`,
    )
  }
  if (f.header) parts.push(band('sb-fn-header', f.header, ctx))
  if (f.footer) parts.push(band('sb-fn-footer', f.footer, ctx))
  return parts.length ? `<div class="sb-furniture" aria-hidden="true">${parts.join('')}</div>` : ''
}

/** CSS positioning the furniture chrome by anchor against the theme's safe-area inset. */
export function furnitureCss(theme: Theme): string {
  const s = theme.furniture.safeArea
  const pct = (n: number): string => `${n * 100}%`
  const top = pct(s.top)
  const right = pct(s.right)
  const bottom = pct(s.bottom)
  const left = pct(s.left)
  return [
    '.sb-furniture{position:absolute;inset:0;pointer-events:none;font-size:1.9cqw;color:var(--sb-ink)}',
    '.sb-fn-anchor{position:absolute}',
    // vertical placement
    `.sb-fn-top-left,.sb-fn-top-center,.sb-fn-top-right{top:${top}}`,
    '.sb-fn-mid-left,.sb-fn-center,.sb-fn-mid-right{top:50%}',
    `.sb-fn-bottom-left,.sb-fn-bottom-center,.sb-fn-bottom-right{bottom:${bottom}}`,
    // horizontal placement
    `.sb-fn-top-left,.sb-fn-mid-left,.sb-fn-bottom-left{left:${left}}`,
    '.sb-fn-top-center,.sb-fn-center,.sb-fn-bottom-center{left:50%}',
    `.sb-fn-top-right,.sb-fn-mid-right,.sb-fn-bottom-right{right:${right}}`,
    // centering transforms
    '.sb-fn-top-center,.sb-fn-bottom-center{transform:translateX(-50%)}',
    '.sb-fn-mid-left,.sb-fn-mid-right{transform:translateY(-50%)}',
    '.sb-fn-center{transform:translate(-50%,-50%)}',
    // header/footer bands span the safe-area width
    `.sb-fn-band{position:absolute;left:${left};right:${right};display:flex;align-items:center}`,
    `.sb-fn-header{top:${top}}`,
    `.sb-fn-footer{bottom:${bottom}}`,
    '.sb-fn-slot{flex:1}',
    '.sb-fn-slot-left{text-align:left}',
    '.sb-fn-slot-center{text-align:center}',
    '.sb-fn-slot-right{text-align:right}',
  ].join('\n')
}
