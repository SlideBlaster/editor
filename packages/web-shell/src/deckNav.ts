/**
 * The deck navigator. Contract: see deckNav.md.
 *
 * A strip of slide thumbnails for jumping around the deck — the secondary
 * navigation beside the scrolling canvas ([deck.ts](./deck.md)). Two styles,
 * chosen by a setting: `filmstrip` (a flat rail) and `carousel` (the active
 * thumbnail centred and enlarged). Clicking a thumbnail asks the canvas to scroll
 * there (`onSelect`); as the canvas scrolls, the controller calls `setActive` to
 * move the highlight and, in carousel style, re-centre. Navigation only — it
 * never edits (ux/deck-navigation.md).
 */
import { renderSlide, resolveLayout, naiveMeasurer, type Frame } from '@slideblaster/editor'

export type NavStyle = 'filmstrip' | 'carousel'

export interface NavProps {
  frames: Frame[]
  active: number
  style: NavStyle
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
    thumb.innerHTML = renderSlide(frame.picture, resolveLayout(frame.picture, naiveMeasurer))
    thumb.addEventListener('click', () => props.onSelect(index))
    host.append(thumb)
    thumbs.push(thumb)
  })

  // Carousel is the vertical side rail (centre the active thumb); filmstrip is
  // the horizontal bottom rail (just keep the active thumb in view).
  const options: ScrollIntoViewOptions =
    props.style === 'carousel'
      ? { behavior: 'smooth', block: 'center', inline: 'nearest' }
      : { behavior: 'smooth', block: 'nearest', inline: 'nearest' }

  const setActive = (index: number): void => {
    thumbs.forEach((thumb, i) => thumb.classList.toggle('is-current', i === index))
    thumbs[index]?.scrollIntoView(options)
  }
  setActive(props.active)

  return { setActive }
}
