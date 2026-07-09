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
  nodeScale,
  renderSlide,
  connectorsOf,
  serializeBody,
  textWidth,
  type Anchor,
  type ConnectorPath,
  type Layout,
  type NodeContent,
  type PlacedNode,
  type Point,
  type TextRun,
  type TikzPicture,
} from '@slideblaster/editor'
import {
  nearestAnchor,
  nearestAnchorOn,
  paintSnapDots,
  setActiveSnaps,
  snapKey,
  snapToAnchor,
  type Snap,
} from './connectorAnchors'
import { renderOptions } from './tableCompiler'
import { editableHtml, padIslands, readEditable, wireRichEditing } from './richText'
import { paintColumnEditors } from './columnEditor'
import { paintTableEditors } from './tableEditor'
import { wireResizeGrips, isReflowable } from './resizeHandles'
import { resolveSnap, type SnapBox, type SnapLine, type SnapSize } from './snap'
import { findBinding, type BindBox, type Binding } from './binding'
import { paintConnectorEditor, type CurveFocus } from './connectorEditor'
import { rerouteConnectors } from './liveConnectors'

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
  /** Open the creation menu: `center` is the slide-space insert point, `client` the
   *  cursor position to anchor the popover (W5). */
  requestCreate(center: Point, client: Point): void
  remove(name: string): void
  /** Commit an inline content edit: `body` is the edited raw node body (re-parsed by the engine). */
  editContent(name: string, body: string): void
  /** Commit a structured content edit (grid affordance): the new node content directly. */
  editContentModel(name: string, content: NodeContent): void
  /** Resize a node: `scaleX`/`scaleY` scale the content (drag), `textWidth`/`minHeight` set
   *  the natural box (panel). `center` re-anchors an absolute node's opposite edge. */
  resize(
    name: string,
    patch: {
      textWidth?: number | null
      minHeight?: number | null
      scaleX?: number | null
      scaleY?: number | null
      center?: Point
    },
  ): void
  /** E4: draw a connector between two endpoints (connect mode). Each endpoint is a node
   *  border anchor (`(name.north)` / centre) or a free point in space. */
  connect(from: Anchor, to: Anchor): void
  /** Select an existing connector by its index (or clear with null). */
  selectConnector(index: number | null): void
  /** E4+: replace a connector's shape (endpoints, waypoints, curves). */
  updateConnector(index: number, path: ConnectorPath): void
  /** E4+: focus a curved segment for angle editing in the properties panel (null clears). */
  focusConnectorCurve(focus: CurveFocus | null): void
}

export interface CanvasProps {
  picture: TikzPicture
  layout: Layout
  selected: string | null
  /** The selected connector's index, if any (mutually exclusive with a node selection). */
  selectedConnector: number | null
  /** Which anchor (dot) of the selected connector the panel is editing (highlighted). */
  selectedCurve: number | null
  /** When true, dragging a node draws an arrow to the node under the pointer (E4). */
  connectMode: boolean
  /** A just-created node to open in edit mode on this paint (W5), or null. */
  autoEdit: string | null
  /** Overlay step to render (ADR 0018); omit for the all-visible authoring state. */
  step?: number
  /** Theme master-layout snap references (slide-space x/y edges + centres, y-up): a drag
   *  snaps to the title/content region bounds and draws them as guides (ADR 0017). */
  snapRefs?: { xs: readonly number[]; ys: readonly number[] }
  /** Slide-box width in slide units (ADR 0017 aspect ratio; height fixed at 9). Drives the
   *  render viewBox/shape and every px<->unit map on this surface. Omit for 16:9 (=16). */
  slideWidth?: number
  actions: CanvasActions
}

export function paintCanvas(stage: HTMLElement, props: CanvasProps): void {
  const slideWidth = props.slideWidth ?? SLIDE_W
  const options = {
    ...renderOptions,
    ...(props.step !== undefined ? { step: props.step } : {}),
    slideWidth,
  }
  stage.innerHTML = renderSlide(props.picture, props.layout, options)
  const slideEl = stage.querySelector<HTMLElement>('.sb-slide')
  if (!slideEl) return

  const overlay = document.createElement('div')
  overlay.className = props.connectMode ? 'sb-overlay is-connect' : 'sb-overlay'

  // Connector hit-lines (under the handles): a clickable stroke along each arrow so it
  // can be selected and deleted. The visible arrow itself lives in the render's SVG.
  const connectors = connectorsOf(props.picture, props.layout)
  paintConnectors(overlay, connectors, props.selectedConnector, props.actions, slideWidth)

  // Reshape the selected connector (endpoints, waypoints, curves) if it is editable.
  const selected = connectors.find((c) => c.index === props.selectedConnector)
  if (selected?.editable) {
    paintConnectorEditor(
      overlay,
      slideEl,
      selected.index,
      selected.editable,
      props.layout,
      {
        update: (index, path) => props.actions.updateConnector(index, path),
        focusCurve: (focus) => props.actions.focusConnectorCurve(focus),
      },
      props.selectedCurve,
      slideWidth,
    )
  }

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
    handle.style.cssText = boxStyle(node, slideWidth)
    handle.dataset.node = name
    if (props.connectMode) {
      wireConnect(handle, node, props.layout.nodes, slideEl, overlay, props.actions, slideWidth)
    } else {
      wireHandle(
        handle,
        node,
        peers,
        bindPeers,
        slideEl,
        stage,
        overlay,
        props.actions,
        props.picture,
        props.layout,
        props.snapRefs,
        slideWidth,
      )
      // Resize grips (corners + edges), hidden by CSS until this handle is selected. A text
      // node reflows (rewraps at a constant font size); every other node scales its content,
      // for which the grips need the node's current scale (from its options).
      const src = findNode(props.picture, name)
      wireResizeGrips(
        handle,
        node,
        src ? nodeScale(src) : { x: 1, y: 1 },
        src ? isReflowable(src.content) : true,
        slideEl,
        stage,
        props.actions,
        props.picture,
        props.layout,
        overlay,
        slideWidth,
      )
      // Double-click a node to edit its raw body in place (commits on blur / Ctrl+Enter).
      handle.addEventListener('dblclick', (event) => {
        event.stopPropagation() // don't let the empty-overlay dblclick create a node
        openInlineEditor(overlay, slideEl, node, name, props.picture, props.actions)
      })
    }
    overlay.append(handle)
  }

  // Empty-canvas gestures: click to deselect, double-click to open the creation menu
  // at the cursor (W5). The menu anchors at the client point; insertion at the slide point.
  overlay.addEventListener('pointerdown', (event) => {
    if (event.target === overlay) props.actions.select(null)
  })
  overlay.addEventListener('dblclick', (event) => {
    if (event.target === overlay)
      props.actions.requestCreate(pointToUnits(slideEl, event.clientX, event.clientY, slideWidth), {
        x: event.clientX,
        y: event.clientY,
      })
  })

  stage.append(overlay)

  // Sub-node grid affordance (ADR 0016): on the selected node, overlay column bounds +
  // divider grips + an add-column "+". Geometry is DOM-measured, so it runs after paint.
  if (props.selected) {
    const node = findNode(props.picture, props.selected)
    const contentEl = stage.querySelector<HTMLElement>(
      `.sb-node[data-node="${CSS.escape(props.selected)}"]`,
    )
    if (node && contentEl && node.content.kind === 'text') {
      paintColumnEditors(overlay, slideEl, contentEl, props.selected, node.content, props.actions)
      paintTableEditors(overlay, slideEl, contentEl, props.selected, node.content, props.actions)
    }
  }

  // A just-created node opens straight in edit mode with an empty caret (W5). An edit
  // abandoned while still empty removes the node again — no orphaned invisible boxes.
  if (props.autoEdit) {
    const placed = props.layout.nodes.find((n) => n.name === props.autoEdit)
    if (placed?.name)
      openInlineEditor(overlay, slideEl, placed, placed.name, props.picture, props.actions, {
        discardIfEmpty: true,
      })
  }
}

/**
 * Open an editor in a node's place (W6, whole-node granularity). The editor is a
 * contenteditable div mounted in the slide's own content layer, carrying the node's
 * classes and the rendered node's inline geometry — so it inherits the exact type the
 * node renders with (family, cqw size, line-height, color, align) and editing reads as
 * in-place, not as a box over the slide. The rendered node hides for the duration; the
 * overlay's pointer events are suspended so clicks reach the editor (the slide is a
 * stacking context, so the overlay always sits above it).
 *
 * Renderable content edits WYSIWYG (style-in-place): the editor holds the *rendered*
 * runs via `editableHtml` (provenance-stamped styles, KaTeX math islands, indexed atom
 * islands), live conversion is wired (`wireRichEditing`), and the commit reads the DOM
 * back into one NodeContent transform (`readEditable` -> `editContentModel`, ADR 0016).
 * Out-of-subset (`error`) content has no render to edit, so it falls back to the raw
 * source editor (plaintext, `editContent`). Both modes: commit on blur or
 * Ctrl/Cmd+Enter, Escape cancels, a no-op edit never commits, and `discardIfEmpty`
 * (the just-created path) removes a node whose edit ends still empty.
 */
function openInlineEditor(
  overlay: HTMLElement,
  slideEl: HTMLElement,
  placed: PlacedNode,
  name: string,
  picture: TikzPicture,
  actions: CanvasActions,
  opts: { discardIfEmpty?: boolean } = {},
): void {
  if (slideEl.querySelector('.sb-inline-editor')) return // already editing something
  const node = findNode(picture, name)
  const content: NodeContent = node?.content ?? { kind: 'empty' }
  // WYSIWYG (style-in-place) for renderable content; an out-of-subset body has no
  // render to edit, so error content falls back to the raw source editor.
  const rich = content.kind !== 'error'
  const atoms: TextRun[] = []
  const seed = serializeBody(content)

  const contentLayer = slideEl.querySelector<HTMLElement>('.sb-content')
  const contentEl = slideEl.querySelector<HTMLElement>(`.sb-node[data-node="${CSS.escape(name)}"]`)
  const handle = overlay.querySelector<HTMLElement>(`.sb-handle[data-node="${CSS.escape(name)}"]`)

  const editor = document.createElement('div')
  editor.className = [
    'sb-node',
    ...placed.styleClasses.map((c) => `sb-style-${c}`),
    'sb-inline-editor',
  ].join(' ')
  // Same box as the rendered content (left/top/width/min-height/transform), so the
  // glyphs don't shift when the editor swaps in.
  editor.style.cssText = contentEl?.style.cssText ?? boxStyle(placed)
  // Growth: a `text width` node keeps its fixed width and wraps exactly as rendered; a
  // natural-width node extends rightward as it's typed into (matching its natural-width
  // render), wrapping only at the slide edge. The 18cqw floor gives a fresh empty box a
  // comfortable landing size instead of a near-zero caret trap.
  if (node === undefined || textWidth(node) === undefined) {
    const width = editor.style.width || '0%'
    const left = editor.style.left || '0%'
    editor.style.width = 'auto'
    editor.style.minWidth = `max(${width}, 18cqw)`
    editor.style.maxWidth = `calc(100% - ${left})`
  }
  if (rich) {
    editor.setAttribute('contenteditable', 'true')
    editor.dataset.rich = ''
    editor.innerHTML = editableHtml(content, atoms)
    padIslands(editor)
    wireRichEditing(editor)
  } else {
    editor.setAttribute('contenteditable', 'plaintext-only')
    if (!editor.isContentEditable) editor.setAttribute('contenteditable', 'true')
    editor.textContent = seed
  }
  editor.spellcheck = false

  // Seamless swap: hide the rendered node (same text, same place, now with a caret) and
  // route pointer events past the overlay to the editor for the duration of the edit.
  if (contentEl) contentEl.style.visibility = 'hidden'
  overlay.style.pointerEvents = 'none'
  handle?.classList.add('is-editing')

  let settled = false
  const close = (commit: boolean): void => {
    if (settled) return
    settled = true // guard: removing a focused editor fires blur, which must not re-enter
    // Read before detaching: the rich walk resolves islands against `atoms`; the raw
    // read needs layout for innerText (normalize its trailing placeholder newline).
    const edited = rich ? readEditable(editor, atoms) : null
    const text = rich ? null : editor.innerText.replace(/\n$/, '')
    editor.remove()
    overlay.style.pointerEvents = ''
    handle?.classList.remove('is-editing')
    if (contentEl) contentEl.style.visibility = ''
    if (rich) {
      if (opts.discardIfEmpty && edited!.kind === 'empty') {
        actions.remove(name)
        return
      }
      // One NodeContent transform per gesture (ADR 0016); a no-op edit (same
      // serialized body) never commits, so open-and-close never reformats source.
      if (commit && serializeBody(edited!) !== seed) actions.editContentModel(name, edited!)
      return
    }
    if (opts.discardIfEmpty && text!.trim() === '') {
      actions.remove(name)
      return
    }
    if (commit && text !== seed) actions.editContent(name, text!)
  }

  editor.addEventListener('blur', () => close(true))
  editor.addEventListener('pointerdown', (event) => event.stopPropagation())
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

  ;(contentLayer ?? slideEl).append(editor)
  const focusEditor = (): void => {
    editor.focus()
    // Replace-on-type: select the whole seed (an empty node yields a collapsed caret).
    const selection = window.getSelection()
    if (selection) {
      const range = document.createRange()
      range.selectNodeContents(editor)
      selection.removeAllRanges()
      selection.addRange(range)
    }
  }
  // The auto-edit paint (W5) runs while the deck builds its cards detached; focus is a
  // no-op off-document, so defer it a frame until the card is mounted.
  if (editor.isConnected) focusEditor()
  else requestAnimationFrame(focusEditor)
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
  picture: TikzPicture,
  layout: Layout,
  snapRefs?: { xs: readonly number[]; ys: readonly number[] },
  slideWidth: number = SLIDE_W,
): void {
  const name = node.name! // caller only wires named nodes
  const origin = node.center
  // The pending outcome for this drag, recomputed each move and committed on pointerup.
  // `contentScale` is the node's own `scale(...)` transform (if any), preserved so the move
  // preview composes translate WITH it — otherwise a scaled node would flash to natural size.
  let drag: {
    startX: number
    startY: number
    moved: boolean
    outcome: DragOutcome
    contentScale: string
  } | null = null

  handle.addEventListener('pointerdown', (event) => {
    event.stopPropagation()
    actions.select(name)
    const content = stage.querySelector<HTMLElement>(`.sb-node[data-node="${CSS.escape(name)}"]`)
    drag = {
      startX: event.clientX,
      startY: event.clientY,
      moved: false,
      outcome: { kind: 'move', center: origin },
      contentScale: content?.style.transform ?? '',
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
      x: origin.x + (dxPx / rect.width) * slideWidth,
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
        const threshold = (SNAP_PX / rect.width) * slideWidth // px radius -> slide units (zoom-independent)
        const snapped = resolveSnap(dragged, peers, {
          threshold,
          grid: SNAP_GRID,
          slideWidth,
          slideHeight: SLIDE_H,
          refXs: snapRefs?.xs,
          refYs: snapRefs?.ys,
        })
        outcome = { kind: 'move', center: snapped.center }
        guides = snapped.guides
      }
    }
    drag.outcome = outcome
    const target = outcome.kind === 'bind' ? outcome.binding.center : outcome.center

    // Live preview: translate handle and content by the resolved delta. Zoom scales the
    // slide by width (no transform/zoom context), so a pixel translate tracks 1:1.
    const txPx = ((target.x - origin.x) / slideWidth) * rect.width
    const tyPx = (-(target.y - origin.y) / SLIDE_H) * rect.height
    const transform = `translate(${txPx}px, ${tyPx}px)`
    handle.style.transform = transform
    const content = stage.querySelector<HTMLElement>(`.sb-node[data-node="${CSS.escape(name)}"]`)
    // Compose with the node's own scale so a scaled node (table/image) stays scaled while it
    // moves, instead of snapping to natural size for the duration of the drag.
    if (content) content.style.transform = `${transform} ${drag.contentScale}`.trim()
    // Arrows attached to this node re-route live to its resolved position, instead of staying
    // frozen and only jumping to the new endpoints on drop.
    if (drag.moved)
      rerouteConnectors(
        picture,
        layout,
        node,
        { center: target, size: node.size },
        slideEl,
        overlay,
      )
    drawGuides(overlay, guides, slideWidth)
    setBindBadge(overlay, outcome.kind === 'bind' ? outcome.binding : null, slideWidth)
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
function drawGuides(overlay: HTMLElement, guides: readonly SnapLine[], slideWidth = SLIDE_W): void {
  let svg = overlay.querySelector<SVGSVGElement>('svg.sb-guides')
  if (guides.length === 0) {
    svg?.remove()
    return
  }
  if (!svg) {
    svg = document.createElementNS(SVG_NS, 'svg')
    svg.setAttribute('class', 'sb-guides')
    svg.setAttribute('viewBox', `0 0 ${slideWidth} ${SLIDE_H}`)
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

/** Render a clickable hit-line along each connector so arrows can be selected/deleted.
 *  The stroke traces the arrow's *actual* path (`pathData`, curves and all), so a curved
 *  arrow is grabbed on the curve you see — not on a phantom straight baseline. The visible
 *  arrow is drawn by the engine's SVG; this is only the interaction target. */
function paintConnectors(
  overlay: HTMLElement,
  connectors: readonly ReturnType<typeof connectorsOf>[number][],
  selectedConnector: number | null,
  actions: CanvasActions,
  slideWidth = SLIDE_W,
): void {
  if (connectors.length === 0) return
  const svg = document.createElementNS(SVG_NS, 'svg')
  svg.setAttribute('class', 'sb-connectors')
  svg.setAttribute('viewBox', `0 0 ${slideWidth} ${SLIDE_H}`)
  svg.setAttribute('preserveAspectRatio', 'none')
  for (const connector of connectors) {
    const hit = document.createElementNS(SVG_NS, 'path')
    hit.setAttribute('d', connector.pathData)
    hit.dataset.connector = String(connector.index)
    hit.setAttribute(
      'class',
      connector.index === selectedConnector ? 'sb-hit is-selected' : 'sb-hit',
    )
    hit.addEventListener('pointerdown', (event) => {
      event.stopPropagation()
      actions.selectConnector(connector.index)
    })
    svg.append(hit)
  }
  overlay.append(svg)
}

/**
 * Connect-mode gesture (E4): drag from a node to draw an arrow. Reuses the connector editor's
 * anchor-point view — the snap dots (`connectorAnchors`) and the same nearest-port snapping — so
 * a new arrow attaches exactly the way a reshaped one does: the source end binds to the pressed
 * node's border anchor nearest the press; the destination snaps to the anchor of whatever node
 * the pointer releases over, or lands in free space as a bare point when released over none.
 */
function wireConnect(
  handle: HTMLElement,
  node: PlacedNode,
  nodes: readonly PlacedNode[],
  slideEl: HTMLElement,
  overlay: HTMLElement,
  actions: CanvasActions,
  slideWidth = SLIDE_W,
): void {
  const name = node.name!
  const others = nodes.filter((n) => n.name && n.name !== name) // never self-connect
  let source: Snap | null = null
  let origin: Point | null = null // press point — a barely-moved click shouldn't drop an arrow

  const toSlide = (clientX: number, clientY: number): Point => {
    const rect = slideEl.getBoundingClientRect()
    return {
      x: ((clientX - rect.left) / rect.width) * slideWidth,
      y: SLIDE_H - ((clientY - rect.top) / rect.height) * SLIDE_H,
    }
  }

  handle.addEventListener('pointerdown', (event) => {
    event.stopPropagation()
    actions.selectConnector(null)
    handle.setPointerCapture(event.pointerId)
    origin = toSlide(event.clientX, event.clientY)
    source = nearestAnchorOn(origin, node)
    const layer = ensureSnapLayer(overlay, slideWidth)
    paintSnapDots(layer, nodes)
    setActiveSnaps(layer, [snapKey(source.name, source.port)])
    drawRubberBand(overlay, source.point, source.point, slideWidth)
  })

  handle.addEventListener('pointermove', (event) => {
    if (!source) return
    const to = toSlide(event.clientX, event.clientY)
    const target = nearestAnchor(to, others)
    drawRubberBand(overlay, source.point, target ? target.point : to, slideWidth)
    const layer = overlay.querySelector<SVGElement>('svg.sb-snap-layer')
    if (layer) {
      const keys = [snapKey(source.name, source.port)]
      if (target) keys.push(snapKey(target.name, target.port))
      setActiveSnaps(layer, keys)
    }
  })

  const end = (event: PointerEvent): void => {
    if (!source || !origin) return
    const src = source
    const from = origin
    source = null
    origin = null
    handle.releasePointerCapture(event.pointerId)
    clearRubberBand(overlay)
    clearSnapLayer(overlay)
    const to = toSlide(event.clientX, event.clientY)
    const target = nearestAnchor(to, others)
    // A stray click (no target node, barely moved) shouldn't spawn a degenerate free-space arrow.
    if (!target && Math.hypot(to.x - from.x, to.y - from.y) < 0.5) return
    actions.connect(snapToAnchor(src), target ? snapToAnchor(target) : { kind: 'point', at: to })
  }
  handle.addEventListener('pointerup', end)
  handle.addEventListener('pointercancel', end)
}

/** The overlay's persistent snap-dot layer (kept across pointermoves, unlike the rubber band's
 *  own svg which is redrawn each move). Created lazily on drag start. */
function ensureSnapLayer(overlay: HTMLElement, slideWidth: number): SVGSVGElement {
  let svg = overlay.querySelector<SVGSVGElement>('svg.sb-snap-layer')
  if (!svg) {
    svg = document.createElementNS(SVG_NS, 'svg')
    svg.setAttribute('class', 'sb-snap-layer')
    svg.setAttribute('viewBox', `0 0 ${slideWidth} ${SLIDE_H}`)
    svg.setAttribute('preserveAspectRatio', 'none')
    overlay.append(svg)
  }
  return svg
}

function clearSnapLayer(overlay: HTMLElement): void {
  overlay.querySelector('svg.sb-snap-layer')?.remove()
}

/** Draw/update the connect-mode rubber band from a node center to the pointer. */
function drawRubberBand(overlay: HTMLElement, from: Point, to: Point, slideWidth = SLIDE_W): void {
  let svg = overlay.querySelector<SVGSVGElement>('svg.sb-rubber')
  if (!svg) {
    svg = document.createElementNS(SVG_NS, 'svg')
    svg.setAttribute('class', 'sb-rubber')
    svg.setAttribute('viewBox', `0 0 ${slideWidth} ${SLIDE_H}`)
    svg.setAttribute('preserveAspectRatio', 'none')
    overlay.append(svg)
  }
  svg.replaceChildren()
  const line = document.createElementNS(SVG_NS, 'line')
  line.setAttribute('x1', String(from.x))
  line.setAttribute('y1', String(SLIDE_H - from.y))
  line.setAttribute('x2', String(to.x))
  line.setAttribute('y2', String(SLIDE_H - to.y))
  line.setAttribute('class', 'sb-rubber-line')
  svg.append(line)
}

function clearRubberBand(overlay: HTMLElement): void {
  overlay.querySelector('svg.sb-rubber')?.remove()
}

/** Show (or clear) the relationship badge — e.g. "below 0.6" — at the bound node's
 *  resolved center while a binding is engaged. */
function setBindBadge(overlay: HTMLElement, binding: Binding | null, slideWidth = SLIDE_W): void {
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
  badge.style.left = `${(binding.center.x / slideWidth) * 100}%`
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
function boxStyle(node: PlacedNode, slideWidth = SLIDE_W): string {
  const left = ((node.center.x - node.size.width / 2) / slideWidth) * 100
  const top = ((SLIDE_H - node.center.y - node.size.height / 2) / SLIDE_H) * 100
  const width = (node.size.width / slideWidth) * 100
  const height = (node.size.height / SLIDE_H) * 100
  return `left:${left}%;top:${top}%;width:${width}%;height:${height}%`
}

/** Client pixel point -> slide-space coordinates (y-up). */
function pointToUnits(
  slideEl: HTMLElement,
  clientX: number,
  clientY: number,
  slideWidth = SLIDE_W,
): Point {
  const rect = slideEl.getBoundingClientRect()
  return {
    x: ((clientX - rect.left) / rect.width) * slideWidth,
    y: SLIDE_H - ((clientY - rect.top) / rect.height) * SLIDE_H,
  }
}
