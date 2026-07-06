/**
 * Node resize affordance. Contract: see resizeHandles.md.
 *
 * Over the SELECTED node's `.sb-handle`, eight drag grips (four corners + four edges) that
 * resize the node by SCALING ITS CONTENT — the rendered text, tables, and images grow with
 * the box, not just the frame (a `scale` / `xscale` / `yscale` option, applied as a CSS
 * transform by the renderer and folded into the layout box so peers still reflow). A drag
 * previews live by scaling the node's own content in place and tracking the handle to the
 * scaled box, then commits ONCE on pointerup via `actions.resize`. Holding SHIFT locks the
 * aspect ratio (both axes scale by one factor). Grips are hidden by CSS until the handle is
 * `.is-selected`, so this rides the repaint-free selection toggle (`showSelection`).
 *
 * The gesture never needs the content's natural size: the new scale is the current scale
 * times the box growth ratio (natural cancels), so it works from the placed box + current
 * scale alone. Zoom is width-scaled (no transform context), so px->unit needs no zoom fix.
 */
import type { PlacedNode, Point } from '@slideblaster/editor'

const SLIDE_W = 16
const SLIDE_H = 9
// Slide-unit floors, matching the measurer (domMeasurer.ts MIN_W / MIN_H).
const MIN_W = 1
const MIN_H = 0.6

export interface ResizeActions {
  /** Resize a node by scaling its content. `center` re-anchors an absolutely-positioned
   *  node so the dragged edge's opposite side stays put. */
  resize(name: string, patch: { scaleX?: number; scaleY?: number; center?: Point }): void
}

type Dir = 'n' | 's' | 'e' | 'w' | 'ne' | 'nw' | 'se' | 'sw'
const DIRS: readonly Dir[] = ['n', 's', 'e', 'w', 'ne', 'nw', 'se', 'sw']

/** Attach the eight resize grips to a node's handle (CSS-hidden until the handle is selected).
 *  `scale` is the node's current content scale (from its `scale`/`xscale`/`yscale` options). */
export function wireResizeGrips(
  handle: HTMLElement,
  node: PlacedNode,
  scale: { x: number; y: number },
  slideEl: HTMLElement,
  stage: HTMLElement,
  actions: ResizeActions,
): void {
  const name = node.name! // caller only wires named nodes
  for (const dir of DIRS) {
    const grip = document.createElement('div')
    grip.className = `sb-resize-grip grip-${dir}`
    handle.append(grip)
    wireGrip(grip, dir, handle, node, scale, name, slideEl, stage, actions)
  }
}

function wireGrip(
  grip: HTMLElement,
  dir: Dir,
  handle: HTMLElement,
  node: PlacedNode,
  scale: { x: number; y: number },
  name: string,
  slideEl: HTMLElement,
  stage: HTMLElement,
  actions: ResizeActions,
): void {
  const xEdge = dir.includes('e') ? 'e' : dir.includes('w') ? 'w' : null
  const yEdge = dir.includes('n') ? 'n' : dir.includes('s') ? 's' : null

  grip.addEventListener('pointerdown', (event) => {
    event.stopPropagation() // don't let the handle underneath start a node move
    event.preventDefault()
    const nodeEl = stage.querySelector<HTMLElement>(`.sb-node[data-node="${CSS.escape(name)}"]`)
    if (!nodeEl) return
    grip.setPointerCapture(event.pointerId)

    const startX = event.clientX
    const startY = event.clientY
    // Origin box (slide units, y-up) and current content scale.
    const w0 = node.size.width
    const h0 = node.size.height
    const cx0 = node.center.x
    const cy0 = node.center.y
    const L0 = cx0 - w0 / 2
    const R0 = cx0 + w0 / 2
    const B0 = cy0 - h0 / 2
    const T0 = cy0 + h0 / 2
    const csx = scale.x
    const csy = scale.y
    const handleStyle0 = handle.style.cssText
    const nodeStyle0 = nodeEl.getAttribute('style') ?? ''
    let pending: { scaleX: number; scaleY: number; center: Point } | null = null

    const onMove = (ev: PointerEvent): void => {
      const rect = slideEl.getBoundingClientRect()
      const dux = ((ev.clientX - startX) / rect.width) * SLIDE_W
      const duy = -((ev.clientY - startY) / rect.height) * SLIDE_H // slide y is up

      // Growth ratio per axis from the dragged edges (1 on an untouched axis).
      let rx = xEdge === 'e' ? (w0 + dux) / w0 : xEdge === 'w' ? (w0 - dux) / w0 : 1
      let ry = yEdge === 'n' ? (h0 + duy) / h0 : yEdge === 's' ? (h0 - duy) / h0 : 1
      // Shift locks the aspect ratio: drive both axes by the dominant ratio.
      if (ev.shiftKey) {
        const f = Math.abs(rx - 1) >= Math.abs(ry - 1) ? rx : ry
        rx = f
        ry = f
      }
      // Clamp so the scaled box keeps the slide-unit floors.
      rx = Math.max(rx, MIN_W / w0)
      ry = Math.max(ry, MIN_H / h0)
      const newW = w0 * rx
      const newH = h0 * ry
      const sx = round3(csx * rx)
      const sy = round3(csy * ry)

      // New box edges: the dragged edge moves, the opposite edge (or the center, on an
      // axis only scaled because of Shift) stays put.
      const [L, R] =
        xEdge === 'w'
          ? [R0 - newW, R0]
          : xEdge === 'e'
            ? [L0, L0 + newW]
            : [cx0 - newW / 2, cx0 + newW / 2]
      const [B, T] =
        yEdge === 's'
          ? [T0 - newH, T0]
          : yEdge === 'n'
            ? [B0, B0 + newH]
            : [cy0 - newH / 2, cy0 + newH / 2]

      pending = { scaleX: sx, scaleY: sy, center: { x: (L + R) / 2, y: (B + T) / 2 } }

      // Live preview: scale the content in place, re-anchoring its top-left corner.
      nodeEl.style.transformOrigin = 'top left'
      nodeEl.style.transform = `scale(${sx},${sy})`
      nodeEl.style.left = pctStr(L, SLIDE_W)
      nodeEl.style.top = pctStr(SLIDE_H - T, SLIDE_H)
      // Track the handle to the actual scaled content box.
      const nr = nodeEl.getBoundingClientRect()
      handle.style.left = pctStr(nr.left - rect.left, rect.width)
      handle.style.top = pctStr(nr.top - rect.top, rect.height)
      handle.style.width = pctStr(nr.width, rect.width)
      handle.style.height = pctStr(nr.height, rect.height)
    }

    const cleanup = (ev: PointerEvent): void => {
      grip.releasePointerCapture(ev.pointerId)
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onUp)
      window.removeEventListener('pointercancel', onCancel)
    }
    const onUp = (ev: PointerEvent): void => {
      cleanup(ev)
      if (pending) actions.resize(name, pending) // the re-render after commit resets the preview
    }
    const onCancel = (ev: PointerEvent): void => {
      cleanup(ev)
      handle.style.cssText = handleStyle0 // no commit: restore the pre-drag inline styles
      nodeEl.setAttribute('style', nodeStyle0)
    }
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onUp)
    window.addEventListener('pointercancel', onCancel)
  })
}

function pctStr(value: number, total: number): string {
  return `${(value / total) * 100}%`
}

/** Round a scale factor to 3 decimals for a tidy `scale` / `xscale` / `yscale` token. */
function round3(n: number): number {
  return Math.round(n * 1000) / 1000
}
