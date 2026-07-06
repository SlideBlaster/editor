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
  onSelect(index: number): void
}

export interface NavHandle {
  setActive(index: number): void
  /** Re-render just one thumbnail after a node-scoped content edit (ADR 0016), so the
   *  rail stays in sync without rebuilding the whole nav. */
  repaintThumb(index: number, frame: Frame): Promise<void>
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
    thumb.innerHTML = renderSlide(frame.picture, layouts[index]!, renderOptions)
    thumb.addEventListener('click', () => props.onSelect(index))
    host.append(thumb)
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
    thumb.innerHTML = renderSlide(frame.picture, layout, renderOptions)
  }

  return { setActive, repaintThumb }
}
