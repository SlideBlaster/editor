/**
 * Interactive canvas layer. Contract: see canvas.md.
 *
 * Paints the rendered slide (engine `renderSlide`) and, over it, a transparent
 * interaction overlay built from the same `Layout` — one handle per named node.
 * Handles turn pointer gestures into intent (`select` / `move` / `create` /
 * `remove`); the controller applies the matching engine edit op and re-serializes.
 * The overlay reuses the layout the controller already computed, so it never
 * re-implements the render — only the ADR-0014 slide(0..16 x 0..9, y-up) -> box map.
 */
import {
  renderSlide,
  type Layout,
  type PlacedNode,
  type Point,
  type TikzPicture,
} from '@slideblaster/editor'

const SLIDE_W = 16
const SLIDE_H = 9
const DRAG_THRESHOLD_PX = 2

export interface CanvasActions {
  /** Selection only — cheap, must not re-render (a drag may be starting). */
  select(name: string | null): void
  move(name: string, center: Point): void
  create(center: Point): void
  remove(name: string): void
}

export interface CanvasProps {
  picture: TikzPicture
  layout: Layout
  selected: string | null
  actions: CanvasActions
}

export function paintCanvas(stage: HTMLElement, props: CanvasProps): void {
  stage.innerHTML = renderSlide(props.picture, props.layout)
  const slideEl = stage.querySelector<HTMLElement>('.sb-slide')
  if (!slideEl) return

  const overlay = document.createElement('div')
  overlay.className = 'sb-overlay'

  for (const node of props.layout.nodes) {
    if (!node.name) continue
    const handle = document.createElement('div')
    handle.className = node.name === props.selected ? 'sb-handle is-selected' : 'sb-handle'
    handle.style.cssText = boxStyle(node)
    handle.dataset.node = node.name
    wireHandle(handle, node.name, node.center, slideEl, stage, props.actions)
    overlay.append(handle)
  }

  // Empty-canvas gestures: click to deselect, double-click to create a node there.
  overlay.addEventListener('pointerdown', (event) => {
    if (event.target === overlay) props.actions.select(null)
  })
  overlay.addEventListener('dblclick', (event) => {
    if (event.target === overlay)
      props.actions.create(pointToUnits(slideEl, event.clientX, event.clientY))
  })

  stage.append(overlay)
}

function wireHandle(
  handle: HTMLElement,
  name: string,
  center: Point,
  slideEl: HTMLElement,
  stage: HTMLElement,
  actions: CanvasActions,
): void {
  let drag: { startX: number; startY: number; moved: boolean } | null = null

  handle.addEventListener('pointerdown', (event) => {
    event.stopPropagation()
    actions.select(name)
    drag = { startX: event.clientX, startY: event.clientY, moved: false }
    handle.setPointerCapture(event.pointerId)
  })

  handle.addEventListener('pointermove', (event) => {
    if (!drag) return
    const dx = event.clientX - drag.startX
    const dy = event.clientY - drag.startY
    if (Math.abs(dx) + Math.abs(dy) > DRAG_THRESHOLD_PX) drag.moved = true
    // Live preview: translate handle and content together. Zoom scales the slide by
    // width (no transform/zoom context), so a pixel translate already tracks the
    // pointer 1:1; the committed position uses the zoomed rect and stays exact.
    const transform = `translate(${dx}px, ${dy}px)`
    handle.style.transform = transform
    const content = stage.querySelector<HTMLElement>(`.sb-node[data-node="${CSS.escape(name)}"]`)
    if (content) content.style.transform = transform
  })

  handle.addEventListener('pointerup', (event) => {
    if (!drag) return
    const finished = drag
    drag = null
    handle.releasePointerCapture(event.pointerId)
    if (!finished.moved) return // a click, not a drag; selection already happened
    const delta = pixelsToUnits(
      slideEl,
      event.clientX - finished.startX,
      event.clientY - finished.startY,
    )
    actions.move(name, { x: center.x + delta.x, y: center.y + delta.y })
  })
}

/** Node box as CSS percentages of the slide, mirroring renderSlide's mapping (y-up). */
function boxStyle(node: PlacedNode): string {
  const left = ((node.center.x - node.size.width / 2) / SLIDE_W) * 100
  const top = ((SLIDE_H - node.center.y - node.size.height / 2) / SLIDE_H) * 100
  const width = (node.size.width / SLIDE_W) * 100
  const height = (node.size.height / SLIDE_H) * 100
  return `left:${left}%;top:${top}%;width:${width}%;height:${height}%`
}

/** Client pixel point -> slide-space coordinates (y-up). */
function pointToUnits(slideEl: HTMLElement, clientX: number, clientY: number): Point {
  const rect = slideEl.getBoundingClientRect()
  return {
    x: ((clientX - rect.left) / rect.width) * SLIDE_W,
    y: SLIDE_H - ((clientY - rect.top) / rect.height) * SLIDE_H,
  }
}

/** Client pixel delta -> slide-space delta (y flips: screen y-down, slide y-up). */
function pixelsToUnits(slideEl: HTMLElement, dxPx: number, dyPx: number): Point {
  const rect = slideEl.getBoundingClientRect()
  return { x: (dxPx / rect.width) * SLIDE_W, y: -(dyPx / rect.height) * SLIDE_H }
}
