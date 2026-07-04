/// <reference types="vite/client" />
/**
 * Web-shell entry: the reactive render controller. Contract: see main.md.
 *
 * The engine, running unchanged in a browser, with a live edit loop (W2):
 *   code pane text -> fromMarkdown -> frame.picture
 *     -> resolveLayout(_, naiveMeasurer) -> renderSlide -> DOM
 * Edit the source, the stage and filmstrip re-render. The `.slideBlaster.md` text is
 * the source of truth (A1); this pane is one editable view of it. Canvas editing
 * (W4+) will drive the same source seam once engine edit ops exist.
 */
import {
  fromMarkdown,
  getMeta,
  resolveLayout,
  naiveMeasurer,
  renderSlide,
  slideStylesheet,
  type Frame,
  type SlideDocument,
} from '@slideblaster/editor'
import initialSource from './sample.slideBlaster.md?raw'
import { createCodePane } from './codePane'
import './app.css'

interface State {
  source: string
  current: number
}

function qs<T extends HTMLElement>(selector: string): T {
  const el = document.querySelector<T>(selector)
  if (!el) throw new Error(`missing element: ${selector}`)
  return el
}

/** One frame's layered slide DOM. */
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

function main(): void {
  const state: State = { source: initialSource, current: 0 }
  const stage = qs('#stage')
  const filmstrip = qs('#filmstrip')
  const errorBanner = qs('#error')
  const docTitle = qs('#doc-title')

  const render = (): void => {
    const result = parse(state.source)
    if ('error' in result) {
      errorBanner.textContent = result.error
      errorBanner.hidden = false
      return // keep the last good stage/filmstrip
    }
    errorBanner.hidden = true

    const doc = result.doc
    docTitle.textContent = getMeta(doc.meta, 'title') ?? 'Untitled'
    state.current = Math.min(state.current, Math.max(0, doc.frames.length - 1))

    const frame = doc.frames[state.current]
    stage.innerHTML = frame ? renderFrame(frame) : ''

    filmstrip.replaceChildren(
      ...doc.frames.map((f, i) => {
        const thumb = document.createElement('button')
        thumb.className = i === state.current ? 'thumb is-current' : 'thumb'
        thumb.innerHTML = renderFrame(f)
        thumb.addEventListener('click', () => {
          state.current = i
          render()
        })
        return thumb
      }),
    )
  }

  createCodePane(qs('#code'), {
    value: state.source,
    onChange: (value) => {
      state.source = value
      render()
    },
  })

  render()
}

// Inject the engine's base stylesheet once; app.css layers the workspace chrome.
const style = document.createElement('style')
style.textContent = slideStylesheet()
document.head.append(style)

main()
