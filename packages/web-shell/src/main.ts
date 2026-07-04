/// <reference types="vite/client" />
/**
 * Web-shell entry: the reactive render + edit controller. Contract: see main.md.
 *
 * The engine, running unchanged in a browser, with a two-way edit loop:
 *   - text -> render: code pane -> fromMarkdown -> resolveLayout -> renderSlide (W2)
 *   - canvas -> text: a gesture -> E1 edit op -> toMarkdown -> code pane (W4)
 * Both directions share one source of truth (the .slideBlaster.md text, A1), so an
 * edit made either way immediately shows in the other.
 */
import {
  fromMarkdown,
  toMarkdown,
  getMeta,
  resolveLayout,
  naiveMeasurer,
  renderSlide,
  slideStylesheet,
  moveNodeTo,
  createNode,
  deleteNode,
  type Frame,
  type Point,
  type NodeContent,
  type SlideDocument,
  type TikzPicture,
} from '@slideblaster/editor'
import initialSource from './sample.slideBlaster.md?raw'
import { createCodePane, type CodePane } from './codePane'
import { paintCanvas, type CanvasActions } from './canvas'
import './app.css'

interface State {
  source: string
  current: number
  selected: string | null
}

function qs<T extends HTMLElement>(selector: string): T {
  const el = document.querySelector<T>(selector)
  if (!el) throw new Error(`missing element: ${selector}`)
  return el
}

/** One frame's layered slide DOM (used for filmstrip thumbnails). */
function renderFrame(frame: Frame): string {
  return renderSlide(frame.picture, resolveLayout(frame.picture, naiveMeasurer))
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
  const state: State = { source: initialSource, current: 0, selected: null }
  const stage = qs('#stage')
  const filmstrip = qs('#filmstrip')
  const errorBanner = qs('#error')
  const docTitle = qs('#doc-title')
  const status = qs('#status')
  let currentDoc: SlideDocument | null = null
  let codePane: CodePane

  const setStatus = (): void => {
    status.textContent = state.selected
      ? `Selected ${state.selected} — drag to move, Delete to remove`
      : 'Click a node to select — double-click canvas to add'
  }

  /** Apply an edit op result: re-serialize, sync the code pane, re-render. */
  const commit = (doc: SlideDocument): void => {
    const source = toMarkdown(doc)
    state.source = source
    codePane.setValue(source)
    render()
  }

  const actions: CanvasActions = {
    select(name) {
      state.selected = name
      stage
        .querySelectorAll<HTMLElement>('.sb-handle')
        .forEach((h) => h.classList.toggle('is-selected', h.dataset.node === name))
      setStatus()
    },
    move(name, center) {
      if (!currentDoc) return
      const frame = currentDoc.frames[state.current]
      if (!frame) return
      commit(withFrame(currentDoc, state.current, moveNodeTo(frame.picture, name, center)))
    },
    create(center: Point) {
      if (!currentDoc) return
      const frame = currentDoc.frames[state.current]
      if (!frame) return
      const { picture, name } = createNode(frame.picture, {
        at: center,
        content: textContent('Text'),
      })
      state.selected = name
      commit(withFrame(currentDoc, state.current, picture))
    },
    remove(name) {
      if (!currentDoc) return
      const frame = currentDoc.frames[state.current]
      if (!frame) return
      if (state.selected === name) state.selected = null
      commit(withFrame(currentDoc, state.current, deleteNode(frame.picture, name)))
    },
  }

  const render = (): void => {
    const result = parse(state.source)
    if ('error' in result) {
      errorBanner.textContent = result.error
      errorBanner.hidden = false
      return // keep the last good stage/filmstrip
    }
    errorBanner.hidden = true

    const doc = result.doc
    currentDoc = doc
    docTitle.textContent = getMeta(doc.meta, 'title') ?? 'Untitled'
    state.current = Math.min(state.current, Math.max(0, doc.frames.length - 1))

    const frame = doc.frames[state.current]
    if (frame) {
      const layout = resolveLayout(frame.picture, naiveMeasurer)
      paintCanvas(stage, { picture: frame.picture, layout, selected: state.selected, actions })
    } else {
      stage.innerHTML = ''
    }
    setStatus()

    filmstrip.replaceChildren(
      ...doc.frames.map((f, i) => {
        const thumb = document.createElement('button')
        thumb.className = i === state.current ? 'thumb is-current' : 'thumb'
        thumb.innerHTML = renderFrame(f)
        thumb.addEventListener('click', () => {
          state.current = i
          state.selected = null
          render()
        })
        return thumb
      }),
    )
  }

  codePane = createCodePane(qs('#code'), {
    value: state.source,
    onChange: (value) => {
      state.source = value
      render()
    },
  })

  // Delete/Backspace removes the selection — but not while typing in the code pane.
  document.addEventListener('keydown', (event) => {
    const typing = document.activeElement instanceof HTMLTextAreaElement
    if (!typing && state.selected && (event.key === 'Delete' || event.key === 'Backspace')) {
      event.preventDefault()
      actions.remove(state.selected)
    }
  })

  render()
}

// Inject the engine's base stylesheet once; app.css layers the workspace chrome.
const style = document.createElement('style')
style.textContent = slideStylesheet()
document.head.append(style)

main()
