/// <reference types="vite/client" />
/**
 * Web-shell entry: the reactive render + edit controller. Contract: see main.md.
 *
 * The engine, running unchanged in a browser, with a two-way edit loop:
 *   - text -> render: code pane -> fromMarkdown -> resolveLayout -> renderSlide (W2)
 *   - canvas -> text: a gesture -> E1 edit op -> toMarkdown -> code pane (W4)
 * The canvas is the whole deck in one continuous vertical scroll (deck.ts); a
 * navigator rail (deckNav.ts) jumps between slides and stays synced to the scroll.
 * Both edit directions share one source of truth (the .slideBlaster.md text, A1).
 */
import {
  fromMarkdown,
  toMarkdown,
  getMeta,
  slideStylesheet,
  renderSlide,
  resolveLayoutAsync,
  moveNodeTo,
  createNode,
  deleteNode,
  type NodeContent,
  type RenderedSlide,
  type SlideDocument,
  type TikzPicture,
} from '@slideblaster/editor'
import initialSource from './sample.slideBlaster.md?raw'
import { createCodePane, type CodePane } from './codePane'
import { paintDeck, type DeckActions, type DeckHandle, type Selection } from './deck'
import { paintDeckNav, type NavHandle, type NavStyle } from './deckNav'
import { enableZoomPan } from './zoom'
import { createDomMeasurer } from './domMeasurer'
import { SLIDE_TYPE_CSS } from './slideType'
import { downloadDeckHtml, printDeck } from './export'
import './app.css'

const NAV_STYLE_KEY = 'sb.navStyle'

interface State {
  source: string
  active: number // the slide most in view; drives the navigator highlight
  selected: Selection | null
  navStyle: NavStyle
}

function qs<T extends HTMLElement>(selector: string): T {
  const el = document.querySelector<T>(selector)
  if (!el) throw new Error(`missing element: ${selector}`)
  return el
}

/** Tolerant parse: a malformed edit keeps the last good render instead of blanking. */
function parse(source: string): { doc: SlideDocument } | { error: string } {
  try {
    return { doc: fromMarkdown(source) }
  } catch (err) {
    return { error: err instanceof Error ? err.message : String(err) }
  }
}

/** A document with one frame's picture swapped — the unit of a canvas edit. */
function withFrame(doc: SlideDocument, index: number, picture: TikzPicture): SlideDocument {
  return {
    meta: doc.meta,
    frames: doc.frames.map((frame, i) => (i === index ? { ...frame, picture } : frame)),
  }
}

/** Minimal visible content for a freshly created node. */
function textContent(value: string): NodeContent {
  return { kind: 'text', runs: [{ kind: 'text', value }] }
}

function main(): void {
  const savedStyle = localStorage.getItem(NAV_STYLE_KEY)
  const state: State = {
    source: initialSource,
    active: 0,
    selected: null,
    navStyle: savedStyle === 'carousel' ? 'carousel' : 'filmstrip',
  }
  const deck = qs('#deck')
  const deckRail = qs('#deck-rail') // carousel: vertical strip between editor and canvas
  const deckStrip = qs('#deck-strip') // filmstrip: horizontal rail below the canvas
  const navToggle = qs('#nav-toggle')
  const errorBanner = qs('#error')
  const docTitle = qs('#doc-title')
  const status = qs('#status')
  let currentDoc: SlideDocument | null = null
  let codePane: CodePane
  let deckHandle: DeckHandle | null = null
  let navHandle: NavHandle | null = null
  const measurer = createDomMeasurer()
  // Monotonic render token: a slow async paint that finishes after a newer edit is dropped.
  let renderSeq = 0

  /** The navigator host for the active style; the other stays hidden. */
  const navHost = (): HTMLElement => (state.navStyle === 'carousel' ? deckRail : deckStrip)

  /** Show the active navigator in its place, hide the other. */
  const applyNavPlacement = (): void => {
    deckRail.hidden = state.navStyle !== 'carousel'
    deckStrip.hidden = state.navStyle === 'carousel'
  }

  const markToggle = (): void => {
    navToggle
      .querySelectorAll<HTMLButtonElement>('button')
      .forEach((b) => b.classList.toggle('is-active', b.dataset.view === state.navStyle))
  }

  const setStatus = (): void => {
    status.textContent = state.selected
      ? `Selected ${state.selected.name} on slide ${state.selected.frame + 1} — drag to move, Delete to remove`
      : 'Scroll the canvas to move through slides · click a node to select · double-click to add'
  }

  /** Apply an edit op result: re-serialize, sync the code pane, re-render. */
  const commit = (doc: SlideDocument): void => {
    state.source = toMarkdown(doc)
    codePane.setValue(state.source)
    void render()
  }

  /** Render every frame to self-contained HTML for export — same measurements as the canvas. */
  const collectSlides = (doc: SlideDocument): Promise<RenderedSlide[]> =>
    Promise.all(
      doc.frames.map(async (frame, index) => ({
        index,
        html: renderSlide(frame.picture, await resolveLayoutAsync(frame.picture, measurer)),
      })),
    )

  const actions: DeckActions = {
    select(frame, name) {
      state.selected = name === null ? null : { frame, name }
      deckHandle?.showSelection(state.selected)
      setStatus()
    },
    move(frame, name, center) {
      const target = currentDoc?.frames[frame]
      if (!currentDoc || !target) return
      commit(withFrame(currentDoc, frame, moveNodeTo(target.picture, name, center)))
    },
    create(frame, center) {
      const target = currentDoc?.frames[frame]
      if (!currentDoc || !target) return
      const { picture, name } = createNode(target.picture, {
        at: center,
        content: textContent('Text'),
      })
      state.selected = { frame, name }
      commit(withFrame(currentDoc, frame, picture))
    },
    remove(frame, name) {
      const target = currentDoc?.frames[frame]
      if (!currentDoc || !target) return
      if (state.selected?.frame === frame && state.selected.name === name) state.selected = null
      commit(withFrame(currentDoc, frame, deleteNode(target.picture, name)))
    },
  }

  const render = async (): Promise<void> => {
    const result = parse(state.source)
    if ('error' in result) {
      errorBanner.textContent = result.error
      errorBanner.hidden = false
      return // keep the last good canvas/navigator
    }
    errorBanner.hidden = true

    const doc = result.doc
    currentDoc = doc
    docTitle.textContent = getMeta(doc.meta, 'title') ?? 'Untitled'
    const maxIndex = Math.max(0, doc.frames.length - 1)
    state.active = Math.min(state.active, maxIndex)
    if (state.selected && state.selected.frame > maxIndex) state.selected = null

    const seq = ++renderSeq
    const handle = await paintDeck(deck, {
      frames: doc.frames,
      selected: state.selected,
      actions,
      measurer,
      isStale: () => seq !== renderSeq,
      onActiveChange: (index) => {
        state.active = index
        navHandle?.setActive(index)
      },
    })
    if (handle === null) return // a newer render superseded this one
    deckHandle = handle
    applyNavPlacement()
    navHandle = paintDeckNav(navHost(), {
      frames: doc.frames,
      active: state.active,
      style: state.navStyle,
      onSelect: (index) => deckHandle?.scrollToSlide(index),
    })
    setStatus()
  }

  codePane = createCodePane(qs('#code'), {
    value: state.source,
    onChange: (value) => {
      state.source = value
      void render()
    },
  })

  // Delete/Backspace removes the selection — but not while typing in the code pane.
  document.addEventListener('keydown', (event) => {
    const typing = document.activeElement instanceof HTMLTextAreaElement
    if (!typing && state.selected && (event.key === 'Delete' || event.key === 'Backspace')) {
      event.preventDefault()
      actions.remove(state.selected.frame, state.selected.name)
    }
  })

  // Navigator-style toggle: move the navigator to its slot; the canvas is untouched.
  navToggle.querySelectorAll<HTMLButtonElement>('button').forEach((button) => {
    button.addEventListener('click', () => {
      const next: NavStyle = button.dataset.view === 'carousel' ? 'carousel' : 'filmstrip'
      if (next === state.navStyle) return
      state.navStyle = next
      localStorage.setItem(NAV_STYLE_KEY, next)
      markToggle()
      applyNavPlacement()
      navHandle = paintDeckNav(navHost(), {
        frames: currentDoc?.frames ?? [],
        active: state.active,
        style: next,
        onSelect: (index) => deckHandle?.scrollToSlide(index),
      })
    })
  })

  // Zoom & pan the deck canvas (Ctrl/pinch to zoom, middle/Space-drag to pan).
  const zoomReadout = qs('#zoom-readout')
  const zoom = enableZoomPan(deck, {
    onChange: (value) => {
      zoomReadout.textContent = `${Math.round(value * 100)}%`
    },
  })
  qs('#zoom-control')
    .querySelectorAll<HTMLButtonElement>('button')
    .forEach((button) => {
      button.addEventListener('click', () => {
        if (button.dataset.zoom === 'in') zoom.zoomIn()
        else if (button.dataset.zoom === 'out') zoom.zoomOut()
        else zoom.reset()
      })
    })

  // Export: render the whole deck to a self-contained document, then print (Save as
  // PDF) or download the .html. Both use the DOM-measured layout, so exports are faithful.
  qs('#export-actions')
    .querySelectorAll<HTMLButtonElement>('button')
    .forEach((button) => {
      button.addEventListener('click', async () => {
        if (!currentDoc) return
        const title = getMeta(currentDoc.meta, 'title') ?? 'Slides'
        button.disabled = true
        try {
          const slides = await collectSlides(currentDoc)
          if (button.dataset.export === 'print') await printDeck(slides, { title })
          else await downloadDeckHtml(slides, { title })
        } catch (err) {
          status.textContent = `Export failed: ${err instanceof Error ? err.message : String(err)}`
        } finally {
          button.disabled = false
        }
      })
    })

  markToggle()
  void render()
}

// Inject the engine's base stylesheet + the shared slide type scale once; app.css
// layers the workspace chrome. SLIDE_TYPE_CSS is keyed on .sb-slide so the deck,
// thumbnails, the measurer, and the export all render identical proportions.
const style = document.createElement('style')
style.textContent = `${slideStylesheet()}\n${SLIDE_TYPE_CSS}`
document.head.append(style)

main()
