/**
 * Node resize affordance. Contract: see resizeHandles.md.
 *
 * Over the SELECTED node's `.sb-handle`, eight drag grips (four corners + four edges). What a
 * drag does depends on the node kind:
 *  - A TEXT node REFLOWS: the drag sets the box's `text width` / `minimum height`, so the text
 *    rewraps at a CONSTANT font size (the Google-Docs feel) — the glyphs never stretch. Any
 *    stale content `scale` is cleared, so a previously-stretched text box snaps back to natural.
 *  - Every other node (image, table, …) SCALES: the drag grows the rendered content with the box
 *    via a `scale` / `xscale` / `yscale` option (a CSS transform), so a picture keeps its aspect
 *    and a table its typography. `isReflowable` picks the mode from the node's content.
 * A drag previews live — reflow by resizing the content box and letting the browser rewrap it,
 * scale by transforming the content in place — tracking the handle to the resulting box, then
 * commits ONCE on pointerup via `actions.resize`. Holding SHIFT locks the aspect ratio of a
 * SCALE drag (both axes by one factor); a reflow drag has no aspect to lock, so Shift is inert.
 *
 * The gesture never needs the content's natural size: a scale drag's new scale is the current
 * scale times the box growth ratio (natural cancels); a reflow drag reads the box straight off
 * the placed geometry. Zoom is width-scaled (no transform context), so px->unit needs no zoom fix.
 */
import type {
  Layout,
  NodeContent,
  PlacedNode,
  Point,
  TextRun,
  TikzPicture,
} from '@slideblaster/editor'
import { rerouteConnectors } from './liveConnectors'

const SLIDE_W = 16
const SLIDE_H = 9
// Slide-unit floors, matching the measurer (domMeasurer.ts MIN_W / MIN_H).
const MIN_W = 1
const MIN_H = 0.6

export interface ResizeActions {
  /** Resize a node. A SCALE drag sends `scaleX`/`scaleY`; a REFLOW drag sends `textWidth` and/or
   *  `minHeight` (plus `scaleX`/`scaleY` = 1 to clear any stale stretch). `center` re-anchors an
   *  absolutely-positioned node so the dragged edge's opposite side stays put. */
  resize(
    name: string,
    patch: {
      scaleX?: number
      scaleY?: number
      textWidth?: number
      minHeight?: number
      center?: Point
    },
  ): void
}

type Dir = 'n' | 's' | 'e' | 'w' | 'ne' | 'nw' | 'se' | 'sw'
const DIRS: readonly Dir[] = ['n', 's', 'e', 'w', 'ne', 'nw', 'se', 'sw']

// Runs with an intrinsic 2-D size — a resize should SCALE the node they sit in (grow the picture
// / table with the box), never rewrap it. Everything else is text flow, which reflows.
const BLOCK_RUNS: ReadonlySet<TextRun['kind']> = new Set([
  'image',
  'matrix',
  'columns',
  'deferred',
  'include',
  'printbibliography',
])

/** Whether a node resizes by REFLOWING its text (vs SCALING its content). True for prose (and an
 *  empty text box); false for a node built around an image, table, or column group. */
export function isReflowable(content: NodeContent): boolean {
  if (content.kind === 'empty') return true
  if (content.kind !== 'text') return false // error content: leave it on the scale path
  return !content.runs.some((run) => BLOCK_RUNS.has(run.kind))
}

/** Attach the eight resize grips to a node's handle (CSS-hidden until the handle is selected).
 *  `reflow` picks the gesture (text rewraps vs content scales); `scale` is the node's current
 *  content scale (from its `scale`/`xscale`/`yscale` options), used by the scale path. */
export function wireResizeGrips(
  handle: HTMLElement,
  node: PlacedNode,
  scale: { x: number; y: number },
  reflow: boolean,
  slideEl: HTMLElement,
  stage: HTMLElement,
  actions: ResizeActions,
  picture: TikzPicture,
  layout: Layout,
  overlay: HTMLElement,
  slideWidth: number = SLIDE_W,
): void {
  const name = node.name! // caller only wires named nodes
  for (const dir of DIRS) {
    const grip = document.createElement('div')
    grip.className = `sb-resize-grip grip-${dir}`
    handle.append(grip)
    wireGrip(
      grip,
      dir,
      handle,
      node,
      scale,
      reflow,
      name,
      slideEl,
      stage,
      actions,
      picture,
      layout,
      overlay,
      slideWidth,
    )
  }
}

function wireGrip(
  grip: HTMLElement,
  dir: Dir,
  handle: HTMLElement,
  node: PlacedNode,
  scale: { x: number; y: number },
  reflow: boolean,
  name: string,
  slideEl: HTMLElement,
  stage: HTMLElement,
  actions: ResizeActions,
  picture: TikzPicture,
  layout: Layout,
  overlay: HTMLElement,
  slideWidth: number = SLIDE_W,
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
    type Pending = {
      scaleX?: number
      scaleY?: number
      textWidth?: number
      minHeight?: number
      center: Point
    }
    let pending: Pending | null = null

    // Track the handle to the node's current on-screen box (both modes end a move here).
    const trackHandle = (rect: DOMRect): void => {
      const nr = nodeEl.getBoundingClientRect()
      handle.style.left = pctStr(nr.left - rect.left, rect.width)
      handle.style.top = pctStr(nr.top - rect.top, rect.height)
      handle.style.width = pctStr(nr.width, rect.width)
      handle.style.height = pctStr(nr.height, rect.height)
    }

    // REFLOW: resize the content box and let the browser rewrap the text (constant font size).
    const onMoveReflow = (rect: DOMRect, dux: number, duy: number): void => {
      // Target box from the dragged edges (an untouched axis keeps its size).
      const newW = Math.max(MIN_W, xEdge === 'e' ? w0 + dux : xEdge === 'w' ? w0 - dux : w0)
      const newH = Math.max(MIN_H, yEdge === 'n' ? h0 + duy : yEdge === 's' ? h0 - duy : h0)

      // Drop any stretch transform and set the touched dimensions so the text reflows live.
      nodeEl.style.transform = 'none'
      if (xEdge) nodeEl.style.width = pctStr(newW, slideWidth)
      if (yEdge) nodeEl.style.minHeight = pctStr(newH, SLIDE_H)

      // Measure the actually reflowed box: narrowing wraps the text and grows its height.
      const nr = nodeEl.getBoundingClientRect()
      const mW = (nr.width / rect.width) * slideWidth
      const mH = (nr.height / rect.height) * SLIDE_H

      // Anchor the edge the user is NOT dragging; a pure width drag keeps the TOP put (the box
      // grows downward as the text rewraps taller), matching a document text box.
      const [L, R] =
        xEdge === 'w' ? [R0 - mW, R0] : xEdge === 'e' ? [L0, L0 + mW] : [cx0 - mW / 2, cx0 + mW / 2]
      const [B, T] = yEdge === 's' ? [T0 - mH, T0] : yEdge === 'n' ? [B0, B0 + mH] : [T0 - mH, T0]

      nodeEl.style.left = pctStr(L, slideWidth)
      nodeEl.style.top = pctStr(SLIDE_H - T, SLIDE_H)

      // Commit the box the user dragged to (not the measured reflow height), clearing any stale
      // scale so the glyphs stop stretching.
      pending = {
        center: { x: (L + R) / 2, y: (B + T) / 2 },
        scaleX: 1,
        scaleY: 1,
        ...(xEdge ? { textWidth: round3(newW) } : {}),
        ...(yEdge ? { minHeight: round3(newH) } : {}),
      }
      // Attached arrows re-route to the live (reflowed) box instead of jumping on drop.
      rerouteConnectors(
        picture,
        layout,
        node,
        { center: pending.center, size: { width: R - L, height: T - B } },
        slideEl,
        overlay,
      )
      trackHandle(rect)
    }

    // SCALE: grow the rendered content with the box via a CSS transform (aspect-preserving).
    const onMoveScale = (ev: PointerEvent, rect: DOMRect, dux: number, duy: number): void => {
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
      nodeEl.style.left = pctStr(L, slideWidth)
      nodeEl.style.top = pctStr(SLIDE_H - T, SLIDE_H)
      // Attached arrows re-route to the live (scaled) box instead of jumping on drop.
      rerouteConnectors(
        picture,
        layout,
        node,
        { center: pending.center, size: { width: newW, height: newH } },
        slideEl,
        overlay,
      )
      trackHandle(rect)
    }

    const onMove = (ev: PointerEvent): void => {
      const rect = slideEl.getBoundingClientRect()
      const dux = ((ev.clientX - startX) / rect.width) * slideWidth
      const duy = -((ev.clientY - startY) / rect.height) * SLIDE_H // slide y is up
      if (reflow) onMoveReflow(rect, dux, duy)
      else onMoveScale(ev, rect, dux, duy)
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
      // No commit means no re-render, so re-route any previewed arrows back to the origin box.
      rerouteConnectors(
        picture,
        layout,
        node,
        { center: { x: cx0, y: cy0 }, size: { width: w0, height: h0 } },
        slideEl,
        overlay,
      )
    }
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onUp)
    window.addEventListener('pointercancel', onCancel)
  })
}

function pctStr(value: number, total: number): string {
  return `${(value / total) * 100}%`
}

/** Round a scale factor / size to 3 decimals for a tidy option token. */
function round3(n: number): number {
  return Math.round(n * 1000) / 1000
}
