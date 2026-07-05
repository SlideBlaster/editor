/**
 * The deck canvas. Contract: see deck.md.
 *
 * The editing surface: every slide stacked top-to-bottom in one continuous
 * vertical scroll (like Overleaf's preview), each fully interactive. A gesture on
 * any slide edits *that* slide — actions are bound to the slide's frame index, so
 * the slide you touch is the slide that changes. An IntersectionObserver tracks
 * which slide is most in view and reports it as the active slide, which drives the
 * navigator highlight (ux/deck-navigation.md). The navigator, in turn, scrolls
 * this canvas via `scrollToSlide`.
 */
import {
  resolveLayoutAsync,
  type BatchMeasurer,
  type Frame,
  type Point,
} from '@slideblaster/editor'
import { paintCanvas, type CanvasActions } from './canvas'

/** Frame-addressed edit intents: the frame you touched is an explicit argument. */
export interface DeckActions {
  select(frame: number, name: string | null): void
  move(frame: number, name: string, center: Point): void
  create(frame: number, center: Point): void
  remove(frame: number, name: string): void
}

/** A selected node, qualified by its slide (node names are unique per slide only). */
export interface Selection {
  frame: number
  name: string
}

export interface DeckProps {
  frames: Frame[]
  selected: Selection | null
  actions: DeckActions
  /** Sizes node boxes; the DOM measurer in the browser, naive in tests. */
  measurer: BatchMeasurer
  /** Checked after async measuring: if a newer render has started, skip the paint. */
  isStale?(): boolean
  /** Fired when scrolling changes which slide is most in view. */
  onActiveChange(index: number): void
}

export interface DeckHandle {
  /** Smooth-scroll the slide at `index` into view (centred). */
  scrollToSlide(index: number): void
  /** Update selection outlines without a re-render (a drag may be in flight). */
  showSelection(selected: Selection | null): void
}

/** One IntersectionObserver per deck host, disconnected before each rebuild. */
const observers = new WeakMap<HTMLElement, IntersectionObserver>()

export async function paintDeck(host: HTMLElement, props: DeckProps): Promise<DeckHandle | null> {
  // Measure/resolve every slide first (async), so the paint below stays synchronous
  // and never shows a half-built deck.
  const layouts = await Promise.all(
    props.frames.map((frame) => resolveLayoutAsync(frame.picture, props.measurer)),
  )
  // A newer edit may have landed while we measured; drop this paint so we don't clobber
  // the DOM with a stale layout (the newer render owns the deck now).
  if (props.isStale?.()) return null

  const scrollTop = host.scrollTop // preserve position across a rebuild
  const scrollLeft = host.scrollLeft
  observers.get(host)?.disconnect()
  host.replaceChildren()

  // Inner wrapper carries the zoom (--zoom, set by zoom.ts on the scrollport);
  // `#deck` stays the fixed viewport that pans.
  const canvas = document.createElement('div')
  canvas.className = 'deck-canvas'
  const cards: HTMLElement[] = []

  props.frames.forEach((frame, index) => {
    const card = document.createElement('div')
    card.className = 'deck-slide'
    card.dataset.frame = String(index)
    const selectedName = props.selected?.frame === index ? props.selected.name : null
    paintCanvas(card, {
      picture: frame.picture,
      layout: layouts[index]!,
      selected: selectedName,
      actions: bindFrame(props.actions, index),
    })
    canvas.append(card)
    cards.push(card)
  })
  host.append(canvas)

  host.scrollTop = scrollTop
  host.scrollLeft = scrollLeft
  observers.set(host, watchActive(host, cards, props.onActiveChange))

  return {
    scrollToSlide(index) {
      cards[index]?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    },
    showSelection(selected) {
      cards.forEach((card, i) => {
        const name = selected?.frame === i ? selected.name : null
        card
          .querySelectorAll<HTMLElement>('.sb-handle')
          .forEach((h) => h.classList.toggle('is-selected', h.dataset.node === name))
      })
    },
  }
}

/** Wrap frame-agnostic DeckActions into the CanvasActions a single slide expects. */
function bindFrame(actions: DeckActions, frame: number): CanvasActions {
  return {
    select: (name) => actions.select(frame, name),
    move: (name, center) => actions.move(frame, name, center),
    create: (center) => actions.create(frame, center),
    remove: (name) => actions.remove(frame, name),
  }
}

/** Report the slide with the greatest visible area as the viewport scrolls. */
function watchActive(
  host: HTMLElement,
  cards: HTMLElement[],
  onActiveChange: (index: number) => void,
): IntersectionObserver {
  const ratios = new Map<number, number>()
  let active = -1
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        ratios.set(Number((entry.target as HTMLElement).dataset.frame), entry.intersectionRatio)
      }
      let best = active
      let bestRatio = -1
      ratios.forEach((ratio, frame) => {
        if (ratio > bestRatio) {
          bestRatio = ratio
          best = frame
        }
      })
      if (best >= 0 && best !== active) {
        active = best
        onActiveChange(best)
      }
    },
    { root: host, threshold: [0.2, 0.4, 0.6, 0.8, 1] },
  )
  cards.forEach((card) => observer.observe(card))
  return observer
}
