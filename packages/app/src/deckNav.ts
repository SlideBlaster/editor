/**
 * The deck navigator. Contract: see deckNav.md.
 *
 * A vertical rail of slide thumbnails beside the scrolling canvas ([deck.ts](./deck.md))
 * — the secondary navigation. The active thumbnail is centred and highlighted. Clicking
 * a thumbnail asks the canvas to scroll there (`onSelect`); as the canvas scrolls, the
 * controller calls `setActive` to move the highlight and re-centre the rail. Navigation
 * only — it never edits (ux/deck-navigation.md).
 */
import {
  renderSlide,
  resolveLayoutAsync,
  type BatchMeasurer,
  type Frame,
} from '@slideblaster/editor'
import { renderOptions } from './tableCompiler'

export interface NavProps {
  frames: Frame[]
  active: number
  /** The SAME measurer the canvas uses, so a thumbnail is the exact same render — the naive
   *  estimate mis-sized tables and scaled nodes, drifting the thumbnail off the canvas. */
  measurer: BatchMeasurer
  /** Slide-box width in slide units (ADR 0017 aspect ratio); default 16 = 16:9. */
  slideWidth?: number
  onSelect(index: number): void
}

export interface NavHandle {
  setActive(index: number): void
  /** Re-render just one thumbnail after a node-scoped content edit (ADR 0016), so the
   *  rail stays in sync without rebuilding the whole nav. */
  repaintThumb(index: number, frame: Frame): Promise<void>
}

/**
 * Fallback reference width (px) if the canvas slide isn't mounted yet (it always is, in
 * practice — the deck paints before the nav).
 */
const THUMB_REF_W = 1280

/**
 * The width (px) a thumbnail's slide is rendered at before being shrunk to fit: the live
 * canvas slide's OWN content width. A thumbnail is NOT a second, tiny render — it is the
 * *same* full-size render scaled down by a CSS transform (a photographic reduction).
 * Rendering at ~140px directly rounds borders, radii, and text at a different pixel scale
 * than the ~1000px canvas, so the two drift apart no matter how carefully units match.
 * Rendering at the canvas's exact width and scaling by transform makes every rounding
 * decision identical, so the thumbnail is pixel-for-pixel the canvas slide, uniformly
 * reduced — divergence is impossible by construction (and it's sharper). We match the
 * canvas slide's `clientWidth` (its content box), which is what its `cqw` type resolves
 * against, so the thumbnail's proportional units resolve to the identical pixels.
 */
function canvasRefWidth(): number {
  const canvasSlide = document.querySelector('.deck-slide .sb-slide')
  const w = canvasSlide instanceof HTMLElement ? canvasSlide.clientWidth : 0
  return w > 0 ? w : THUMB_REF_W
}

/** Mount `slideHtml` in a thumbnail: render at the canvas width, then scale to fill the thumb. */
function fillThumb(thumb: HTMLElement, slideHtml: string): void {
  thumb.innerHTML = `<div class="thumb-canvas">${slideHtml}</div>`
  const canvas = thumb.firstElementChild as HTMLElement
  const ref = canvasRefWidth()
  canvas.style.width = `${ref}px`
  // clientWidth is the thumb's content box (its CSS width less border); the scaled slide
  // then exactly fills it. The thumb is attached + fixed-width here, so this is stable.
  canvas.style.transform = `scale(${thumb.clientWidth / ref})`
}

export async function paintDeckNav(host: HTMLElement, props: NavProps): Promise<NavHandle> {
  // Thumbnails share the canvas's DOM-measured layout so each is a faithful miniature of
  // the real slide. The measurer caches by content, so re-resolving here is just cache
  // hits from the canvas render — cheap, and byte-for-byte the same geometry.
  const layouts = await Promise.all(
    props.frames.map((frame) => resolveLayoutAsync(frame.picture, props.measurer)),
  )
  host.replaceChildren()
  const thumbs: HTMLElement[] = []

  props.frames.forEach((frame, index) => {
    const thumb = document.createElement('button')
    thumb.type = 'button'
    thumb.className = 'thumb'
    thumb.addEventListener('click', () => props.onSelect(index))
    host.append(thumb) // attach first so fillThumb can measure the thumb's width
    fillThumb(thumb, renderSlide(frame.picture, layouts[index]!, { ...renderOptions, slideWidth: props.slideWidth }))
    thumbs.push(thumb)
  })

  const setActive = (index: number): void => {
    thumbs.forEach((thumb, i) => thumb.classList.toggle('is-current', i === index))
    thumbs[index]?.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'nearest' })
  }
  setActive(props.active)

  const repaintThumb = async (index: number, frame: Frame): Promise<void> => {
    const thumb = thumbs[index]
    if (!thumb) return
    const layout = await resolveLayoutAsync(frame.picture, props.measurer)
    if (!thumb.isConnected) return // a full nav rebuild superseded this thumbnail
    fillThumb(thumb, renderSlide(frame.picture, layout, { ...renderOptions, slideWidth: props.slideWidth }))
  }

  return { setActive, repaintThumb }
}
