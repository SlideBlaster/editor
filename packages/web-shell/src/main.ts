/// <reference types="vite/client" />
/**
 * Web-shell entry: mount the live render pipeline. Contract: see main.md.
 *
 * The whole point of W1 — the editor engine, running unchanged in a browser:
 *   source .slideBlaster.md -> fromMarkdown -> frame.picture
 *     -> resolveLayout(picture, measurer) -> renderSlide -> DOM
 * No canvas or code pane yet (W2+); this is the visible mount the roadmap's M2
 * milestone is built on top of.
 */
import {
  fromMarkdown,
  getMeta,
  resolveLayout,
  naiveMeasurer,
  renderSlide,
  slideStylesheet,
  type Frame,
} from '@slideblaster/editor'
import source from './sample.slideBlaster.md?raw'
import './app.css'

/** Render one frame's layered slide DOM into a host element. */
function renderFrame(frame: Frame): string {
  const layout = resolveLayout(frame.picture, naiveMeasurer)
  return renderSlide(frame.picture, layout)
}

function mount(): void {
  const doc = fromMarkdown(source)

  const docTitle = document.querySelector<HTMLElement>('#doc-title')
  if (docTitle) docTitle.textContent = getMeta(doc.meta, 'title') ?? 'Untitled'

  const stage = document.querySelector<HTMLElement>('#stage')
  const filmstrip = document.querySelector<HTMLElement>('#filmstrip')
  if (!stage || !filmstrip) return

  let current = 0
  const show = (i: number): void => {
    const frame = doc.frames[i]
    if (!frame) return
    current = i
    stage.innerHTML = renderFrame(frame)
    filmstrip
      .querySelectorAll('.thumb')
      .forEach((el, j) => el.classList.toggle('is-current', j === current))
  }

  // Filmstrip: one live-rendered thumbnail per frame; click to select.
  doc.frames.forEach((frame, i) => {
    const thumb = document.createElement('button')
    thumb.className = 'thumb'
    thumb.innerHTML = renderFrame(frame)
    thumb.addEventListener('click', () => show(i))
    filmstrip.append(thumb)
  })

  show(0)
}

// Inject the engine's base stylesheet once; app.css layers display styling on top.
const style = document.createElement('style')
style.textContent = slideStylesheet()
document.head.append(style)

mount()
