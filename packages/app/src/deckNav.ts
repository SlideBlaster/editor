/**
 * The deck navigator. Contract: see deckNav.md.
 *
 * A vertical rail of slide thumbnails beside the scrolling canvas ([deck.ts](./deck.md))
 * — the secondary navigation. The active thumbnail is centred and highlighted. Clicking
 * a thumbnail asks the canvas to scroll there (`onSelect`); as the canvas scrolls, the
 * controller calls `setActive` to move the highlight and re-centre the rail. Navigation
 * only — it never edits (ux/deck-navigation.md).
 */
import { renderSlide, resolveLayout, naiveMeasurer, type Frame } from '@slideblaster/editor'
import { mathOptions } from './math'

export interface NavProps {
  frames: Frame[]
  active: number
  onSelect(index: number): void
}

export interface NavHandle {
  setActive(index: number): void
}

export function paintDeckNav(host: HTMLElement, props: NavProps): NavHandle {
  host.replaceChildren()
  const thumbs: HTMLElement[] = []

  props.frames.forEach((frame, index) => {
    const thumb = document.createElement('button')
    thumb.type = 'button'
    thumb.className = 'thumb'
    // Thumbnails are cheap and static, so the sync naive layout is fine here (the
    // editable canvas uses the DOM measurer). Math is rendered so thumbnails match.
    thumb.innerHTML = renderSlide(
      frame.picture,
      resolveLayout(frame.picture, naiveMeasurer),
      mathOptions,
    )
    thumb.addEventListener('click', () => props.onSelect(index))
    host.append(thumb)
    thumbs.push(thumb)
  })

  const setActive = (index: number): void => {
    thumbs.forEach((thumb, i) => thumb.classList.toggle('is-current', i === index))
    thumbs[index]?.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'nearest' })
  }
  setActive(props.active)

  return { setActive }
}
