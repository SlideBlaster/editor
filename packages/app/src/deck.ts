/**
 * The deck canvas. Contract: see deck.md.
 *
 * The editing surface: every slide stacked top-to-bottom in one continuous vertical
 * scroll (like Overleaf's preview), each fully interactive. A gesture on any slide edits
 * *that* slide — actions are bound to the slide's frame index, so the slide you touch is
 * the slide that changes. An IntersectionObserver tracks which slide is most in view and
 * reports it as the active slide, which drives the navigator highlight
 * (ux/deck-navigation.md). The navigator, in turn, scrolls this canvas via `scrollToSlide`.
 *
 * Each frame is a ROW: the audience slide on the left and its presenter-notes sidecar on
 * the right (ADR 0019). Both cards are the same interactive canvas — edits are addressed
 * by `(frame, surface)`, so a gesture on the notes card writes back to `frame.notes`. A
 * frame with no notes shows an empty cell with an "Add notes" affordance.
 */
import {
  resolveLayoutAsync,
  type BatchMeasurer,
  type ConnectorPath,
  type Frame,
  type NodeContent,
  type Point,
  type TikzPicture,
  type Layout,
} from '@slideblaster/editor'
import { paintCanvas, type CanvasActions } from './canvas'
import { paintColumnEditors } from './columnEditor'
import { paintTableEditors } from './tableEditor'
import type { CurveFocus } from './connectorEditor'

/** Which picture of a frame an edit targets: the audience slide or its notes sidecar. */
export type Surface = 'slide' | 'notes'

/** Frame-addressed edit intents: the frame AND surface you touched are explicit arguments. */
export interface DeckActions {
  select(frame: number, surface: Surface, name: string | null): void
  move(frame: number, surface: Surface, name: string, center: Point): void
  bind(
    frame: number,
    surface: Surface,
    name: string,
    binding: { side: RelativeSide; gap: number; ref: string },
  ): void
  requestCreate(frame: number, surface: Surface, center: Point, client: Point): void
  remove(frame: number, surface: Surface, name: string): void
  editContent(frame: number, surface: Surface, name: string, body: string): void
  /** Commit a structured content edit (grid affordance): the new node content directly,
   *  taking the node-scoped delta path (ADR 0016) instead of a whole-doc round-trip. */
  editContentModel(frame: number, surface: Surface, name: string, content: NodeContent): void
  /** Resize a node: `scaleX`/`scaleY` scale the content (drag), `textWidth`/`minHeight` set
   *  the natural box (panel), optionally re-anchoring an absolute node via `center`. */
  resize(
    frame: number,
    surface: Surface,
    name: string,
    patch: {
      textWidth?: number | null
      minHeight?: number | null
      scaleX?: number | null
      scaleY?: number | null
      center?: Point
    },
  ): void
  connect(frame: number, surface: Surface, from: string, to: string): void
  selectConnector(frame: number, surface: Surface, index: number | null): void
  updateConnector(frame: number, surface: Surface, index: number, path: ConnectorPath): void
  /** E4+: focus an anchor (dot) for angle editing in the properties panel (null clears). */
  focusConnectorCurve(frame: number, surface: Surface, focus: CurveFocus | null): void
  /** Create an empty notes sidecar on `frame` (ADR 0019) and open it for editing. */
  addNotes(frame: number): void
}

type RelativeSide = 'above' | 'below' | 'left' | 'right'

/** A selected node, qualified by its slide and surface (names are unique per picture only). */
export interface Selection {
  frame: number
  surface: Surface
  name: string
}

/** A selected connector, qualified by its slide, surface, and index among that picture's paths. */
export interface ConnectorSelection {
  frame: number
  surface: Surface
  index: number
}

export interface DeckProps {
  frames: Frame[]
  selected: Selection | null
  selectedConnector: ConnectorSelection | null
  /** Which anchor (dot) of the selected connector the panel edits (frame/surface-qualified). */
  selectedCurve: { frame: number; surface: Surface; anchor: number } | null
  /** When true, dragging a node draws an arrow to the node under the pointer (E4). */
  connectMode: boolean
  /** A just-created node to open in edit mode, qualified by its slide + surface (W5). */
  autoEdit: Selection | null
  /** Overlay-step preview for one slide (ADR 0018); drives BOTH cards of that frame (the
   *  notes render at the same step, ADR 0019). Every other frame renders all-visible. */
  preview: { frame: number; step: number } | null
  /** Theme master-layout snap references (slide-space x/y, y-up) for the audience surface:
   *  a node drag snaps to the title/content region bounds and draws them (ADR 0017). */
  snapRefs?: { xs: readonly number[]; ys: readonly number[] }
  /** Slide-box width in slide units (ADR 0017 aspect ratio); the deck's coordinate box for
   *  both surfaces. Omit for 16:9 (=16). */
  slideWidth?: number
  actions: DeckActions
  /** Sizes node boxes; the DOM measurer in the browser, naive in tests. */
  measurer: BatchMeasurer
  /** Checked after async measuring: if a newer render has started, skip the paint. */
  isStale?(): boolean
  /** Fired when scrolling changes which slide is most in view. */
  onActiveChange(index: number): void
}

export interface DeckHandle {
  /** Smooth-scroll the frame at `index` into view (centred). */
  scrollToSlide(index: number): void
  /** Update selection outlines without a re-render (a drag may be in flight). */
  showSelection(selected: Selection | null): void
  /**
   * Re-measure and re-paint just one frame surface's card in place, leaving every other
   * card's DOM untouched (ADR 0016 canvas delta). Re-measuring the whole picture is what
   * keeps a content edit correct when it reflows a node's box and shifts its `below=of`
   * peers. Returns false if the card is gone (a full re-render superseded this handle).
   */
  repaintFrame(index: number, surface: Surface, frame: Frame, ctx: RepaintCtx): Promise<boolean>
  /**
   * Mount (or clear) the column grid affordance for the selected node without a
   * repaint — selection is deliberately repaint-free (a drag may be starting), so the
   * dashed bounds + divider grips are added straight to the live overlay. Pass null to
   * clear. A full render / `repaintFrame` mounts it via `paintCanvas` instead.
   */
  setColumnEditors(
    target: { frame: number; surface: Surface; name: string; content: NodeContent } | null,
  ): void
}

/** Current selection/mode a targeted repaint needs (the handle's own copy is stale). */
interface RepaintCtx {
  selected: Selection | null
  selectedConnector: ConnectorSelection | null
  selectedCurve: { frame: number; surface: Surface; anchor: number } | null
  connectMode: boolean
  /** Overlay-step preview for this frame (ADR 0018); undefined renders all-visible. */
  step?: number
  /** Theme region snap references (audience surface), threaded to the drag snapper. */
  snapRefs?: { xs: readonly number[]; ys: readonly number[] }
  /** Slide-box width in slide units (ADR 0017 aspect ratio); the deck's coordinate box. */
  slideWidth?: number
}

/** One IntersectionObserver per deck host, disconnected before each rebuild. */
const observers = new WeakMap<HTMLElement, IntersectionObserver>()

export async function paintDeck(host: HTMLElement, props: DeckProps): Promise<DeckHandle | null> {
  // Measure/resolve every slide (and any notes sidecar) first (async), so the paint below
  // stays synchronous and never shows a half-built deck.
  const layouts = await Promise.all(
    props.frames.map((frame) => resolveLayoutAsync(frame.picture, props.measurer)),
  )
  const noteLayouts = await Promise.all(
    props.frames.map((frame) =>
      frame.notes ? resolveLayoutAsync(frame.notes, props.measurer) : Promise.resolve(null),
    ),
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
  const slideCards: HTMLElement[] = []
  const noteCards: HTMLElement[] = []

  props.frames.forEach((frame, index) => {
    const row = document.createElement('div')
    row.className = 'deck-row'
    row.dataset.frame = String(index)

    const slideCard = document.createElement('div')
    slideCard.className = 'deck-slide'
    slideCard.dataset.frame = String(index)
    slideCard.dataset.surface = 'slide'
    paintSurface(slideCard, 'slide', index, frame.picture, layouts[index]!, props)
    row.append(slideCard)

    const noteCard = document.createElement('div')
    noteCard.className = 'deck-note'
    noteCard.dataset.frame = String(index)
    noteCard.dataset.surface = 'notes'
    if (frame.notes) {
      paintSurface(noteCard, 'notes', index, frame.notes, noteLayouts[index]!, props)
    } else {
      paintEmptyNotes(noteCard, index, props.actions)
    }
    row.append(noteCard)

    canvas.append(row)
    slideCards.push(slideCard)
    noteCards.push(noteCard)
  })
  host.append(canvas)

  host.scrollTop = scrollTop
  host.scrollLeft = scrollLeft
  observers.set(host, watchActive(host, slideCards, props.onActiveChange))

  const cardFor = (index: number, surface: Surface): HTMLElement | undefined =>
    (surface === 'notes' ? noteCards : slideCards)[index]

  return {
    scrollToSlide(index) {
      slideCards[index]?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    },
    showSelection(selected) {
      const apply = (cards: HTMLElement[], surface: Surface): void => {
        cards.forEach((card, i) => {
          const name = selected?.frame === i && selected.surface === surface ? selected.name : null
          card
            .querySelectorAll<HTMLElement>('.sb-handle')
            .forEach((h) => h.classList.toggle('is-selected', h.dataset.node === name))
        })
      }
      apply(slideCards, 'slide')
      apply(noteCards, 'notes')
    },
    async repaintFrame(index, surface, frame, ctx) {
      const card = cardFor(index, surface)
      if (!card) return false
      const picture = surface === 'notes' ? frame.notes : frame.picture
      // The notes sidecar was removed out from under us — repaint the empty cell.
      if (!picture) {
        paintEmptyNotes(card, index, props.actions)
        return true
      }
      const layout = await resolveLayoutAsync(picture, props.measurer)
      if (!card.isConnected) return false // a full re-render replaced the deck under us
      paintSurfaceWithCtx(card, surface, index, picture, layout, props.actions, ctx)
      return true
    },
    setColumnEditors(target) {
      ;[...slideCards, ...noteCards].forEach((card) =>
        card
          .querySelectorAll('.sb-col-edit, .sb-table-edit, .sb-table-cell-editor')
          .forEach((el) => el.remove()),
      )
      if (!target || target.content.kind !== 'text') return
      const card = cardFor(target.frame, target.surface)
      const slideEl = card?.querySelector<HTMLElement>('.sb-slide')
      const overlay = card?.querySelector<HTMLElement>('.sb-overlay')
      const contentEl = card?.querySelector<HTMLElement>(
        `.sb-node[data-node="${CSS.escape(target.name)}"]`,
      )
      if (!slideEl || !overlay || !contentEl) return
      const actions = bindFrame(props.actions, target.frame, target.surface)
      paintColumnEditors(overlay, slideEl, contentEl, target.name, target.content, actions)
      paintTableEditors(overlay, slideEl, contentEl, target.name, target.content, actions)
    },
  }
}

/** Paint one surface's card from full DeckProps (initial render). */
function paintSurface(
  card: HTMLElement,
  surface: Surface,
  index: number,
  picture: TikzPicture,
  layout: Layout,
  props: DeckProps,
): void {
  const sel = props.selected?.frame === index && props.selected.surface === surface
  const selConn =
    props.selectedConnector?.frame === index && props.selectedConnector.surface === surface
  const selCurve = props.selectedCurve?.frame === index && props.selectedCurve.surface === surface
  const auto = props.autoEdit?.frame === index && props.autoEdit.surface === surface
  const step = props.preview?.frame === index ? props.preview.step : undefined
  paintCanvas(card, {
    picture,
    layout,
    selected: sel ? props.selected!.name : null,
    selectedConnector: selConn ? props.selectedConnector!.index : null,
    selectedCurve: selCurve ? props.selectedCurve!.anchor : null,
    connectMode: props.connectMode,
    autoEdit: auto ? props.autoEdit!.name : null,
    ...(step !== undefined ? { step } : {}),
    snapRefs: surface === 'slide' ? props.snapRefs : undefined,
    slideWidth: props.slideWidth,
    actions: bindFrame(props.actions, index, surface),
  })
}

/** Paint one surface's card from a targeted RepaintCtx (canvas delta path). */
function paintSurfaceWithCtx(
  card: HTMLElement,
  surface: Surface,
  index: number,
  picture: TikzPicture,
  layout: Layout,
  actions: DeckActions,
  ctx: RepaintCtx,
): void {
  const selCurve = ctx.selectedCurve?.frame === index && ctx.selectedCurve.surface === surface
  paintCanvas(card, {
    picture,
    layout,
    selected:
      ctx.selected?.frame === index && ctx.selected.surface === surface ? ctx.selected.name : null,
    selectedConnector:
      ctx.selectedConnector?.frame === index && ctx.selectedConnector.surface === surface
        ? ctx.selectedConnector.index
        : null,
    selectedCurve: selCurve ? ctx.selectedCurve!.anchor : null,
    connectMode: ctx.connectMode,
    autoEdit: null,
    ...(ctx.step !== undefined ? { step: ctx.step } : {}),
    snapRefs: surface === 'slide' ? ctx.snapRefs : undefined,
    slideWidth: ctx.slideWidth,
    actions: bindFrame(actions, index, surface),
  })
}

/** The empty-notes cell: a placeholder with an "Add notes" button (ADR 0019). */
function paintEmptyNotes(card: HTMLElement, index: number, actions: DeckActions): void {
  card.replaceChildren()
  const empty = document.createElement('div')
  empty.className = 'deck-note-empty'
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'deck-note-add'
  button.textContent = '+ Add notes'
  button.title = 'Add a presenter-notes sidecar to this slide'
  button.addEventListener('click', () => actions.addNotes(index))
  empty.append(button)
  card.append(empty)
}

/** Wrap frame-agnostic DeckActions into the CanvasActions a single card (frame+surface) expects. */
function bindFrame(actions: DeckActions, frame: number, surface: Surface): CanvasActions {
  return {
    select: (name) => actions.select(frame, surface, name),
    move: (name, center) => actions.move(frame, surface, name, center),
    bind: (name, binding) => actions.bind(frame, surface, name, binding),
    requestCreate: (center, client) => actions.requestCreate(frame, surface, center, client),
    remove: (name) => actions.remove(frame, surface, name),
    editContent: (name, body) => actions.editContent(frame, surface, name, body),
    editContentModel: (name, content) => actions.editContentModel(frame, surface, name, content),
    resize: (name, patch) => actions.resize(frame, surface, name, patch),
    connect: (from, to) => actions.connect(frame, surface, from, to),
    selectConnector: (index) => actions.selectConnector(frame, surface, index),
    updateConnector: (index, path) => actions.updateConnector(frame, surface, index, path),
    focusConnectorCurve: (focus) => actions.focusConnectorCurve(frame, surface, focus),
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
