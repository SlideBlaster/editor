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
  findNode,
  placement,
  renderSlide,
  serializeBody,
  type Layout,
  type PlacedNode,
  type Point,
  type TikzPicture,
} from '@slideblaster/editor'
import { mathOptions } from './math'
import { resolveSnap, type SnapBox, type SnapLine, type SnapSize } from './snap'
import { findBinding, type BindBox, type Binding } from './binding'

const SLIDE_W = 16
const SLIDE_H = 9
const DRAG_THRESHOLD_PX = 2
const SNAP_PX = 7 // snap radius in screen pixels — converted to slide units per drag (zoom-independent)
const SNAP_GRID = 0.5 // sub-unit grid step in slide units
const BIND_ALIGN_TOL = 0.5 // perpendicular alignment tolerance for a relative binding (slide units)
const BIND_MAX_GAP = 1.2 // max edge gap that still binds; pull past this to detach (slide units)
const SVG_NS = 'http://www.w3.org/2000/svg'

export interface CanvasActions {
  /** Selection only — cheap, must not re-render (a drag may be starting). */
  select(name: string | null): void
  /** Absolute drop (E1) — also the detach path: a relative node dragged free lands here. */
  move(name: string, center: Point): void
  /** Relative drop (E2): bind the node `[side=gap of ref]`. */
  bind(name: string, binding: { side: Binding['side']; gap: number; ref: string }): void
  create(center: Point): void
  remove(name: string): void
  /** Commit an inline content edit: `body` is the edited raw node body (re-parsed by the engine). */
  editContent(name: string, body: string): void
}

export interface CanvasProps {
  picture: TikzPicture
  layout: Layout
  selected: string | null
  actions: CanvasActions
}

export function paintCanvas(stage: HTMLElement, props: CanvasProps): void {
  stage.innerHTML = renderSlide(props.picture, props.layout, mathOptions)
  const slideEl = stage.querySelector<HTMLElement>('.sb-slide')
  if (!slideEl) return

  const overlay = document.createElement('div')
  overlay.className = 'sb-overlay'

  for (const node of props.layout.nodes) {
    if (!node.name) continue
    const name = node.name
    const others = props.layout.nodes.filter((other) => other !== node)
    // Snap targets: every other box (named or not). Binding targets: named boxes only
    // (a relative placement needs a ref name), minus any node that already depends on
    // this one — binding to it would form a cycle the engine op refuses (would snap back).
    const dependents = dependentsOf(props.picture, name)
    const peers: SnapBox[] = others.map((other) => ({ center: other.center, size: other.size }))
    const bindPeers: BindBox[] = others
      .filter((other) => other.name && !dependents.has(other.name))
      .map((other) => ({ name: other.name!, center: other.center, size: other.size }))
    const handle = document.createElement('div')
    handle.className = name === props.selected ? 'sb-handle is-selected' : 'sb-handle'
    handle.style.cssText = boxStyle(node)
    handle.dataset.node = name
    wireHandle(handle, node, peers, bindPeers, slideEl, stage, overlay, props.actions)
    // Double-click a node to edit its raw body in place (commits on blur / Ctrl+Enter).
    handle.addEventListener('dblclick', (event) => {
      event.stopPropagation() // don't let the empty-overlay dblclick create a node
      openInlineEditor(overlay, node, name, props.picture, props.actions)
    })
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

/**
 * Open a raw-body editor over a node (W6, whole-node granularity). Seeds a textarea
 * from the node's current source (`serializeBody`), positioned on the slide so it
 * scales with zoom. Commits on blur or Ctrl/Cmd+Enter (re-parsed by the engine);
 * Escape cancels. A no-op edit doesn't commit, avoiding a needless re-serialize.
 */
function openInlineEditor(
  overlay: HTMLElement,
  placed: PlacedNode,
  name: string,
  picture: TikzPicture,
  actions: CanvasActions,
): void {
  if (overlay.querySelector('.sb-inline-editor')) return // already editing something
  const node = findNode(picture, name)
  const seed = node ? serializeBody(node.content) : ''

  const editor = document.createElement('textarea')
  editor.className = 'sb-inline-editor'
  editor.style.cssText = boxStyle(placed)
  editor.value = seed
  editor.spellcheck = false

  let settled = false
  const close = (commit: boolean): void => {
    if (settled) return
    settled = true // guard: removing a focused textarea fires blur, which must not re-enter
    editor.remove()
    if (commit && editor.value !== seed) actions.editContent(name, editor.value)
  }

  editor.addEventListener('blur', () => close(true))
  editor.addEventListener('keydown', (event) => {
    event.stopPropagation() // keep Delete / Space / zoom shortcuts out while typing
    if (event.key === 'Escape') {
      event.preventDefault()
      close(false)
    } else if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      editor.blur() // commit via blur; plain Enter stays a newline (lists, \\)
    }
  })

  overlay.append(editor)
  editor.focus()
  editor.select()
}

/** What a drag will commit: an absolute move (E1, also the detach path) or a relative
 *  binding (E2). Carries the preview center so the live translate matches the commit. */
type DragOutcome = { kind: 'move'; center: Point } | { kind: 'bind'; binding: Binding }

function wireHandle(
  handle: HTMLElement,
  node: PlacedNode,
  peers: readonly SnapBox[],
  bindPeers: readonly BindBox[],
  slideEl: HTMLElement,
  stage: HTMLElement,
  overlay: HTMLElement,
  actions: CanvasActions,
): void {
  const name = node.name! // caller only wires named nodes
  const origin = node.center
  // The pending outcome for this drag, recomputed each move and committed on pointerup.
  let drag: { startX: number; startY: number; moved: boolean; outcome: DragOutcome } | null = null

  handle.addEventListener('pointerdown', (event) => {
    event.stopPropagation()
    actions.select(name)
    drag = {
      startX: event.clientX,
      startY: event.clientY,
      moved: false,
      outcome: { kind: 'move', center: origin },
    }
    handle.setPointerCapture(event.pointerId)
  })

  handle.addEventListener('pointermove', (event) => {
    if (!drag) return
    const dxPx = event.clientX - drag.startX
    const dyPx = event.clientY - drag.startY
    if (Math.abs(dxPx) + Math.abs(dyPx) > DRAG_THRESHOLD_PX) drag.moved = true

    const rect = slideEl.getBoundingClientRect()
    // Free (unsnapped) target the pointer is pointing at, in slide space (y-up).
    const proposed: Point = {
      x: origin.x + (dxPx / rect.width) * SLIDE_W,
      y: origin.y - (dyPx / rect.height) * SLIDE_H,
    }
    const dragged = { center: proposed, size: node.size }

    // Alt suppresses all snapping/binding for fully-free placement (positioning-snapping.md).
    // Otherwise a relative binding (E2) is preferred over an absolute snap; when no
    // binding is in range, a relative node dragged free lands here as an absolute move
    // (that IS the detach path).
    let outcome: DragOutcome = { kind: 'move', center: proposed }
    let guides: SnapLine[] = []
    if (!event.altKey) {
      const binding = findBinding(dragged, bindPeers, {
        alignTol: BIND_ALIGN_TOL,
        maxGap: BIND_MAX_GAP,
      })
      if (binding) {
        outcome = { kind: 'bind', binding }
        guides = bindGuides(node.size, binding, bindPeers)
      } else {
        const threshold = (SNAP_PX / rect.width) * SLIDE_W // px radius -> slide units (zoom-independent)
        const snapped = resolveSnap(dragged, peers, {
          threshold,
          grid: SNAP_GRID,
          slideWidth: SLIDE_W,
          slideHeight: SLIDE_H,
        })
        outcome = { kind: 'move', center: snapped.center }
        guides = snapped.guides
      }
    }
    drag.outcome = outcome
    const target = outcome.kind === 'bind' ? outcome.binding.center : outcome.center

    // Live preview: translate handle and content by the resolved delta. Zoom scales the
    // slide by width (no transform/zoom context), so a pixel translate tracks 1:1.
    const txPx = ((target.x - origin.x) / SLIDE_W) * rect.width
    const tyPx = (-(target.y - origin.y) / SLIDE_H) * rect.height
    const transform = `translate(${txPx}px, ${tyPx}px)`
    handle.style.transform = transform
    const content = stage.querySelector<HTMLElement>(`.sb-node[data-node="${CSS.escape(name)}"]`)
    if (content) content.style.transform = transform
    drawGuides(overlay, guides)
    setBindBadge(overlay, outcome.kind === 'bind' ? outcome.binding : null)
  })

  const end = (event: PointerEvent): void => {
    if (!drag) return
    const finished = drag
    drag = null
    handle.releasePointerCapture(event.pointerId)
    clearGuides(overlay)
    setBindBadge(overlay, null)
    if (!finished.moved) return // a click, not a drag; selection already happened
    // Re-render after commit resets the transform.
    if (finished.outcome.kind === 'bind') {
      const b = finished.outcome.binding
      actions.bind(name, { side: b.side, gap: b.gap, ref: b.ref })
    } else {
      actions.move(name, finished.outcome.center)
    }
  }
  handle.addEventListener('pointerup', end)
  handle.addEventListener('pointercancel', end)
}

/** The relationship affordance: a connector across the gap between the ref's facing
 *  edge and the bound node's facing edge, drawn in the guide layer as a `bind` line. */
function bindGuides(size: SnapSize, binding: Binding, bindPeers: readonly BindBox[]): SnapLine[] {
  const ref = bindPeers.find((p) => p.name === binding.ref)
  if (!ref) return []
  const c = binding.center
  const rhw = ref.size.width / 2
  const rhh = ref.size.height / 2
  const hw = size.width / 2
  const hh = size.height / 2
  switch (binding.side) {
    case 'below':
      return [{ x1: c.x, y1: ref.center.y - rhh, x2: c.x, y2: c.y + hh, kind: 'bind' }]
    case 'above':
      return [{ x1: c.x, y1: ref.center.y + rhh, x2: c.x, y2: c.y - hh, kind: 'bind' }]
    case 'right':
      return [{ x1: ref.center.x + rhw, y1: c.y, x2: c.x - hw, y2: c.y, kind: 'bind' }]
    case 'left':
      return [{ x1: ref.center.x - rhw, y1: c.y, x2: c.x + hw, y2: c.y, kind: 'bind' }]
  }
}

/** Draw the snap guides into a dedicated SVG layer over the slide (rebuilt each move).
 *  Guides are in slide space (y-up); the SVG viewBox is y-down, so y flips to SLIDE_H - y. */
function drawGuides(overlay: HTMLElement, guides: readonly SnapLine[]): void {
  let svg = overlay.querySelector<SVGSVGElement>('svg.sb-guides')
  if (guides.length === 0) {
    svg?.remove()
    return
  }
  if (!svg) {
    svg = document.createElementNS(SVG_NS, 'svg')
    svg.setAttribute('class', 'sb-guides')
    svg.setAttribute('viewBox', `0 0 ${SLIDE_W} ${SLIDE_H}`)
    svg.setAttribute('preserveAspectRatio', 'none')
    overlay.append(svg)
  }
  svg.replaceChildren()
  for (const g of guides) {
    const line = document.createElementNS(SVG_NS, 'line')
    line.setAttribute('x1', String(g.x1))
    line.setAttribute('y1', String(SLIDE_H - g.y1))
    line.setAttribute('x2', String(g.x2))
    line.setAttribute('y2', String(SLIDE_H - g.y2))
    line.setAttribute('class', `sb-guide-${g.kind}`)
    svg.append(line)
  }
}

function clearGuides(overlay: HTMLElement): void {
  overlay.querySelector('svg.sb-guides')?.remove()
}

/** Show (or clear) the relationship badge — e.g. "below 0.6" — at the bound node's
 *  resolved center while a binding is engaged. */
function setBindBadge(overlay: HTMLElement, binding: Binding | null): void {
  let badge = overlay.querySelector<HTMLElement>('.sb-bind-badge')
  if (!binding) {
    badge?.remove()
    return
  }
  if (!badge) {
    badge = document.createElement('div')
    badge.className = 'sb-bind-badge'
    overlay.append(badge)
  }
  badge.textContent = `${binding.side} ${binding.gap}`
  badge.style.left = `${(binding.center.x / SLIDE_W) * 100}%`
  badge.style.top = `${((SLIDE_H - binding.center.y) / SLIDE_H) * 100}%`
}

/** Names of nodes whose placement chain (transitively) references `name` — the nodes
 *  that would form a cycle if `name` were bound to them. */
function dependentsOf(picture: TikzPicture, name: string): Set<string> {
  const refOf = (node: string): string | undefined => {
    const found = findNode(picture, node)
    return found ? placement(found)?.ref : undefined
  }
  const deps = new Set<string>()
  for (const statement of picture.statements) {
    if (statement.kind !== 'node' || statement.name === undefined) continue
    const seen = new Set<string>()
    let current: string | undefined = statement.name
    while (current !== undefined && !seen.has(current)) {
      seen.add(current)
      current = refOf(current)
      if (current === name) {
        deps.add(statement.name)
        break
      }
    }
  }
  return deps
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
