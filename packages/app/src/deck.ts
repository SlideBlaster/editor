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
  type ConnectorPath,
  type Frame,
  type NodeContent,
  type Point,
} from '@slideblaster/editor'
import { paintCanvas, type CanvasActions } from './canvas'
import { paintColumnEditors } from './columnEditor'
import type { CurveFocus } from './connectorEditor'

/** Frame-addressed edit intents: the frame you touched is an explicit argument. */
export interface DeckActions {
  select(frame: number, name: string | null): void
  move(frame: number, name: string, center: Point): void
  bind(frame: number, name: string, binding: { side: RelativeSide; gap: number; ref: string }): void
  requestCreate(frame: number, center: Point, client: Point): void
  remove(frame: number, name: string): void
  editContent(frame: number, name: string, body: string): void
  /** Commit a structured content edit (grid affordance): the new node content directly,
   *  taking the node-scoped delta path (ADR 0016) instead of a whole-doc round-trip. */
  editContentModel(frame: number, name: string, content: NodeContent): void
  /** Resize a node: `scaleX`/`scaleY` scale the content (drag), `textWidth`/`minHeight` set
   *  the natural box (panel), optionally re-anchoring an absolute node via `center`. */
  resize(
    frame: number,
    name: string,
    patch: {
      textWidth?: number | null
      minHeight?: number | null
      scaleX?: number | null
      scaleY?: number | null
      center?: Point
    },
  ): void
  connect(frame: number, from: string, to: string): void
  selectConnector(frame: number, index: number | null): void
  updateConnector(frame: number, index: number, path: ConnectorPath): void
  /** E4+: focus an anchor (dot) for angle editing in the properties panel (null clears). */
  focusConnectorCurve(frame: number, focus: CurveFocus | null): void
}

type RelativeSide = 'above' | 'below' | 'left' | 'right'

/** A selected node, qualified by its slide (node names are unique per slide only). */
export interface Selection {
  frame: number
  name: string
}

/** A selected connector, qualified by its slide and its index among that slide's paths. */
export interface ConnectorSelection {
  frame: number
  index: number
}

export interface DeckProps {
  frames: Frame[]
  selected: Selection | null
  selectedConnector: ConnectorSelection | null
  /** Which anchor (dot) of the selected connector the panel edits (frame-qualified). */
  selectedCurve: { frame: number; anchor: number } | null
  /** When true, dragging a node draws an arrow to the node under the pointer (E4). */
  connectMode: boolean
  /** A just-created node to open in edit mode, qualified by its slide (W5). */
  autoEdit: Selection | null
  /** Overlay-step preview for one slide (ADR 0018); every other slide renders all-visible. */
  preview: { frame: number; step: number } | null
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
  /**
   * Re-measure and re-paint just one frame's card in place, leaving every other slide's
   * DOM untouched (ADR 0016 canvas delta). Re-measuring the whole frame is what keeps a
   * content edit correct when it reflows the node's box and shifts its `below=of` peers.
   * Returns false if the card is gone (a full re-render superseded this handle).
   */
  repaintFrame(index: number, frame: Frame, ctx: RepaintCtx): Promise<boolean>
  /**
   * Mount (or clear) the column grid affordance for the selected node without a
   * repaint — selection is deliberately repaint-free (a drag may be starting), so the
   * dashed bounds + divider grips are added straight to the live overlay. Pass null to
   * clear. A full render / `repaintFrame` mounts it via `paintCanvas` instead.
   */
  setColumnEditors(target: { frame: number; name: string; content: NodeContent } | null): void
}

/** Current selection/mode a targeted repaint needs (the handle's own copy is stale). */
interface RepaintCtx {
  selected: Selection | null
  selectedConnector: ConnectorSelection | null
  selectedCurve: { frame: number; anchor: number } | null
  connectMode: boolean
  /** Overlay-step preview for this frame (ADR 0018); undefined renders all-visible. */
  step?: number
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
    const selectedConnector =
      props.selectedConnector?.frame === index ? props.selectedConnector.index : null
    const selectedCurve = props.selectedCurve?.frame === index ? props.selectedCurve.anchor : null
    const autoEdit = props.autoEdit?.frame === index ? props.autoEdit.name : null
    const step = props.preview?.frame === index ? props.preview.step : undefined
    paintCanvas(card, {
      picture: frame.picture,
      layout: layouts[index]!,
      selected: selectedName,
      selectedConnector,
      selectedCurve,
      connectMode: props.connectMode,
      autoEdit,
      ...(step !== undefined ? { step } : {}),
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
    async repaintFrame(index, frame, ctx) {
      const card = cards[index]
      if (!card) return false
      const layout = await resolveLayoutAsync(frame.picture, props.measurer)
      if (!card.isConnected) return false // a full re-render replaced the deck under us
      paintCanvas(card, {
        picture: frame.picture,
        layout,
        selected: ctx.selected?.frame === index ? ctx.selected.name : null,
        selectedConnector:
          ctx.selectedConnector?.frame === index ? ctx.selectedConnector.index : null,
        selectedCurve: ctx.selectedCurve?.frame === index ? ctx.selectedCurve.anchor : null,
        connectMode: ctx.connectMode,
        autoEdit: null,
        ...(ctx.step !== undefined ? { step: ctx.step } : {}),
        actions: bindFrame(props.actions, index),
      })
      return true
    },
    setColumnEditors(target) {
      cards.forEach((card) => card.querySelectorAll('.sb-col-edit').forEach((el) => el.remove()))
      if (!target || target.content.kind !== 'text') return
      const card = cards[target.frame]
      const slideEl = card?.querySelector<HTMLElement>('.sb-slide')
      const overlay = card?.querySelector<HTMLElement>('.sb-overlay')
      const contentEl = card?.querySelector<HTMLElement>(
        `.sb-node[data-node="${CSS.escape(target.name)}"]`,
      )
      if (!slideEl || !overlay || !contentEl) return
      paintColumnEditors(
        overlay,
        slideEl,
        contentEl,
        target.name,
        target.content,
        bindFrame(props.actions, target.frame),
      )
    },
  }
}

/** Wrap frame-agnostic DeckActions into the CanvasActions a single slide expects. */
function bindFrame(actions: DeckActions, frame: number): CanvasActions {
  return {
    select: (name) => actions.select(frame, name),
    move: (name, center) => actions.move(frame, name, center),
    bind: (name, binding) => actions.bind(frame, name, binding),
    requestCreate: (center, client) => actions.requestCreate(frame, center, client),
    remove: (name) => actions.remove(frame, name),
    editContent: (name, body) => actions.editContent(frame, name, body),
    editContentModel: (name, content) => actions.editContentModel(frame, name, content),
    resize: (name, patch) => actions.resize(frame, name, patch),
    connect: (from, to) => actions.connect(frame, from, to),
    selectConnector: (index) => actions.selectConnector(frame, index),
    updateConnector: (index, path) => actions.updateConnector(frame, index, path),
    focusConnectorCurve: (focus) => actions.focusConnectorCurve(frame, focus),
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
