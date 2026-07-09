/**
 * The deck navigator. Contract: see deckNav.md.
 *
 * A vertical rail of slide thumbnails beside the scrolling canvas ([deck.ts](./deck.md))
 * — the secondary navigation. The active thumbnail is centred and highlighted. Selecting a
 * thumbnail (click or ArrowUp/Down while the rail holds focus) fires `onSelect`, which the
 * controller turns into an *immediate* highlight plus a best-effort canvas re-centre — the
 * highlight no longer waits for a scroll that may never come (a slide already in view). As
 * the canvas scrolls, the controller also calls `setActive` to move the highlight and
 * re-centre the rail. Focus is the rail's "direct selection": while a thumb holds focus the
 * rail owns the keyboard (arrows move, Delete removes — createApp.ts), and `setActive`
 * keeps focus on the active thumb; a canvas-driven update never steals focus into the rail.
 * It is navigation, plus one edit affordance: a "+ New slide" button at the bottom (`onAdd`)
 * that appends a blank slide (ux/deck-navigation.md).
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
  /** Append a blank slide (the rail's bottom "+" affordance). Omit to hide it. */
  onAdd?(): void
  /** After (re)building, put keyboard focus on the active thumbnail — so the carousel keeps
   *  "owning" the slide selection across a re-render it caused (e.g. deleting a slide), and
   *  ArrowUp/Down + Delete keep acting on the rail. The controller passes the rail's own
   *  prior focus state, so a canvas-driven re-render never steals focus into the rail. */
  focusActive?: boolean
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
 * One keydown handler per rail host, swapped on every rebuild so ArrowUp/Down always closes
 * over the current thumbnails (the same WeakMap pattern the deck uses for its
 * IntersectionObserver in deck.ts — the host element persists across rebuilds, only its
 * children are replaced, so a fresh `addEventListener` each paint would stack up).
 */
const navKeydown = new WeakMap<HTMLElement, (event: KeyboardEvent) => void>()

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
  // The active index, tracked here so ArrowUp/Down can compute the neighbour to jump to and
  // so setActive can move focus with the selection.
  let active = props.active

  props.frames.forEach((frame, index) => {
    const thumb = document.createElement('button')
    thumb.type = 'button'
    thumb.className = 'thumb'
    // Focus the thumb so the rail "owns" the slide selection (Delete/arrows act on it) and
    // the :focus-within "directly selected" ring engages. Buttons are not focused on click
    // in every browser, so do it explicitly; onSelect then makes it active + recentres.
    thumb.addEventListener('click', () => {
      thumb.focus({ preventScroll: true })
      props.onSelect(index)
    })
    host.append(thumb) // attach first so fillThumb can measure the thumb's width
    fillThumb(
      thumb,
      renderSlide(frame.picture, layouts[index]!, {
        ...renderOptions,
        slideWidth: props.slideWidth,
      }),
    )
    thumbs.push(thumb)
  })

  // The rail's add affordance: a blank-slide button below the last thumbnail (bottom of the
  // column). Not a thumb, so it never takes the `is-current` highlight or the active scroll.
  if (props.onAdd) {
    const add = document.createElement('button')
    add.type = 'button'
    add.className = 'deck-add'
    add.title = 'New slide'
    add.setAttribute('aria-label', 'New slide')
    add.textContent = '+ New slide'
    add.addEventListener('click', () => props.onAdd!())
    host.append(add)
  }

  const setActive = (index: number): void => {
    active = index
    thumbs.forEach((thumb, i) => thumb.classList.toggle('is-current', i === index))
    const thumb = thumbs[index]
    thumb?.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'nearest' })
    // If the rail already owns focus (a click or arrow drove this change), keep focus on the
    // active thumb so arrow-nav continues and the "directly selected" ring tracks it. Guarded
    // by focus-in-rail so a canvas scroll (onActiveChange) never pulls focus into the rail.
    if (thumb && host.contains(document.activeElement) && document.activeElement !== thumb) {
      thumb.focus({ preventScroll: true })
    }
  }
  setActive(props.active)
  // A re-render the carousel itself caused (e.g. deleting a slide) hands focus back to the
  // active thumb so the keyboard keeps acting on the rail; a canvas-driven render passes
  // false and leaves focus wherever the user is working.
  if (props.focusActive) thumbs[props.active]?.focus({ preventScroll: true })

  // ArrowUp/Down move the selection while the rail holds focus (this fires only for key
  // events inside the rail). Swap the single per-host handler so it closes over the latest
  // thumbs; PageUp/Down/Home/End stay with the global handler (createApp.ts keydown).
  const prevKeydown = navKeydown.get(host)
  if (prevKeydown) host.removeEventListener('keydown', prevKeydown)
  const onKeydown = (event: KeyboardEvent): void => {
    let next = active
    if (event.key === 'ArrowDown') next = Math.min(active + 1, thumbs.length - 1)
    else if (event.key === 'ArrowUp') next = Math.max(active - 1, 0)
    else return
    event.preventDefault()
    if (next !== active) props.onSelect(next)
  }
  host.addEventListener('keydown', onKeydown)
  navKeydown.set(host, onKeydown)

  const repaintThumb = async (index: number, frame: Frame): Promise<void> => {
    const thumb = thumbs[index]
    if (!thumb) return
    const layout = await resolveLayoutAsync(frame.picture, props.measurer)
    if (!thumb.isConnected) return // a full nav rebuild superseded this thumbnail
    fillThumb(
      thumb,
      renderSlide(frame.picture, layout, { ...renderOptions, slideWidth: props.slideWidth }),
    )
  }

  return { setActive, repaintThumb }
}
