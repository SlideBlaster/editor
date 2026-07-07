/**
 * The properties panel. Contract: see properties.md.
 *
 * A small inspector for the current selection (E5, scoped). For a selected connector it
 * edits arrow style — head direction and dashing (via `setConnectorOptions`) — plus, when a
 * curved segment is focused, that segment's cubic controls as polar angle/pull fields (via
 * `updateConnectorPath`). For a selected node it reads and edits placement — absolute
 * `at (x,y)` (`moveNode`) or relative `below=<gap> of ref` (`bindNode`) — its size/reveal,
 * and (E5) its Style: fill, stroke (draw/colour/width/dash), opacities, and rounded
 * corners, each read from a `tikz/options` view and written through a `shapes/nodeStyle`
 * helper + `setNodeStyle`. Frame-bound by the controller; this module is frame-agnostic.
 */
import {
  findNode,
  placement,
  textWidth,
  minHeight,
  nodeOverlay,
  isValidSpec,
  connectorOptions,
  nodeShape,
  isDrawn,
  fillColor,
  strokeColor,
  lineWidthName,
  dashPattern,
  opacity,
  fillOpacity,
  drawOpacity,
  cornerRadiusPt,
  LINE_WIDTHS,
  DASH_PATTERNS,
  type LineWidthName,
  type DashPattern,
  type NodeStatement,
  type ConnectorPath,
  type CurveControls,
  type Point,
  type TikzPicture,
} from '@slideblaster/editor'
import type { CurveFocus } from './connectorEditor'
import {
  withFillColor,
  withStroke,
  withStrokeColor,
  withLineWidth,
  withDash,
  withOpacity,
  withFillOpacity,
  withDrawOpacity,
  withCorners,
} from './shapes/nodeStyle'

export type PropSelection =
  { kind: 'node'; name: string } | { kind: 'connector'; index: number } | null

type Side = 'above' | 'below' | 'left' | 'right'

export interface PropertiesActions {
  moveNode(name: string, center: Point): void
  bindNode(name: string, binding: { side: Side; gap: number; ref: string }): void
  /** Set (number) or clear (null) a node's explicit size options; omit a key to leave it. */
  resizeNode(name: string, patch: { textWidth?: number | null; minHeight?: number | null }): void
  /** E5: replace a node's whole option-token array — the style panel writes fill/stroke/etc.
   *  here, having rewritten one knob with the `shapes/nodeStyle` helpers. */
  setNodeStyle(name: string, options: string[]): void
  setConnectorOptions(index: number, options: string[]): void
  /** E4+: replace a connector's shape — the panel uses this to write curve angles/pulls. */
  updateConnectorPath(index: number, path: ConnectorPath): void
  /** ADR 0018: set (raw spec) or clear (null) a node's whole-node `overlay=<spec>` reveal. */
  setNodeOverlay(name: string, spec: string | null): void
}

export interface PropertiesProps {
  selection: PropSelection
  picture: TikzPicture | null
  /** The curved segment (of the selected connector) whose angles the panel edits, or null. */
  curveFocus: CurveFocus | null
  actions: PropertiesActions
}

const HEAD_TOKENS = ['->', '<-', '<->']
type Direction = 'none' | 'forward' | 'back' | 'both'

export function paintProperties(host: HTMLElement, props: PropertiesProps): void {
  host.replaceChildren()
  if (!props.selection || !props.picture) {
    host.hidden = true
    return
  }
  host.hidden = false
  if (props.selection.kind === 'connector') {
    const focus =
      props.curveFocus && props.curveFocus.index === props.selection.index ? props.curveFocus : null
    paintArrow(host, props.picture, props.selection.index, focus, props.actions)
  } else {
    paintNode(host, props.picture, props.selection.name, props.actions)
  }
}

function heading(host: HTMLElement, text: string): void {
  const h = document.createElement('div')
  h.className = 'props-title'
  h.textContent = text
  host.append(h)
}

function row(host: HTMLElement, label: string): HTMLElement {
  const r = document.createElement('label')
  r.className = 'props-row'
  const name = document.createElement('span')
  name.className = 'props-label'
  name.textContent = label
  r.append(name)
  host.append(r)
  return r
}

function paintArrow(
  host: HTMLElement,
  picture: TikzPicture,
  index: number,
  curveFocus: CurveFocus | null,
  actions: PropertiesActions,
): void {
  const options = connectorOptions(picture, index) ?? []
  heading(host, 'Arrow')

  const direction = directionOf(options)
  const dirRow = row(host, 'Heads')
  const group = document.createElement('div')
  group.className = 'props-seg'
  const choices: { dir: Direction; label: string }[] = [
    { dir: 'none', label: '—' },
    { dir: 'forward', label: '→' },
    { dir: 'back', label: '←' },
    { dir: 'both', label: '↔' },
  ]
  for (const choice of choices) {
    const button = document.createElement('button')
    button.type = 'button'
    button.textContent = choice.label
    button.className = choice.dir === direction ? 'is-active' : ''
    button.addEventListener('click', () =>
      actions.setConnectorOptions(index, withDirection(options, choice.dir)),
    )
    group.append(button)
  }
  dirRow.append(group)

  const dashRow = row(host, 'Dashed')
  const dash = document.createElement('input')
  dash.type = 'checkbox'
  dash.checked = options.includes('dashed')
  dash.addEventListener('change', () =>
    actions.setConnectorOptions(index, withDashed(options, dash.checked)),
  )
  dashRow.append(dash)

  if (curveFocus) paintCurve(host, index, curveFocus, actions)
}

const DEG = 180 / Math.PI

/**
 * Angle editor for the focused **anchor** — the dot (endpoint or dark-blue split point) the
 * user selected on the canvas. It edits the segment(s) meeting at that point: an **In** arm
 * (arriving) and/or an **Out** arm (leaving), each with an **angle** (0° right, 90° up — slide
 * space is y-up). A **straight** segment stays straight: setting its angle pivots the free
 * point (keeps it a sharp corner), and only that — no `pull`. A **curved** segment also shows
 * a `pull` (arm reach), and its angle bends. A per-arm toggle flips straight↔curved. Every
 * edit rewrites just that segment (others byte-identical, symbolic node anchors preserved) via
 * `updateConnectorPath`.
 */
function paintCurve(
  host: HTMLElement,
  index: number,
  focus: CurveFocus,
  actions: PropertiesActions,
): void {
  const { point, prevPoint, nextPoint, path, anchor } = focus
  // A free-point dot can be moved to angle a straight segment; a node-attached one cannot.
  const movable = path.anchors[anchor]?.kind === 'point'

  const sub = document.createElement('div')
  sub.className = 'props-title props-subtitle'
  sub.textContent = 'Curve'
  host.append(sub)

  // Replace one segment: bend it (controls) or straighten it (null), leaving the rest as-is.
  const writeSeg = (seg: number, controls: CurveControls | null): void => {
    const next = controls && { c1: round4(controls.c1), c2: round4(controls.c2) }
    const curves = path.curves.map((c, i) => (i === seg ? next : c))
    actions.updateConnectorPath(index, { anchors: path.anchors, curves })
  }
  // Move the focused free point (keeps every segment's straight/curved state) — how a
  // straight segment's angle is set without curving it.
  const moveFocus = (at: Point): void => {
    const anchors = path.anchors.map((an, i) =>
      i === anchor ? { kind: 'point' as const, at: round4(at) } : an,
    )
    actions.updateConnectorPath(index, { anchors, curves: path.curves })
  }

  // One arm meeting at `point`: segment `seg` runs toward `neighbor`; its control is on `side`.
  const arm = (label: string, seg: number, neighbor: Point, side: 'c1' | 'c2'): void => {
    const cur = path.curves[seg]
    const straight = cur == null
    const control = (side === 'c2' ? cur?.c2 : cur?.c1) ?? third(point, neighbor)
    const keep = (side === 'c2' ? cur?.c1 : cur?.c2) ?? third(neighbor, point)
    const build = (c: Point): CurveControls =>
      side === 'c2' ? { c1: keep, c2: c } : { c1: c, c2: keep }
    const nowAngle = degOf(point, control)

    const angleRow = row(host, `${label} ∠`)
    const controls = document.createElement('div')
    controls.className = 'props-inline'
    const angle = angleInput(nowAngle)
    angle.addEventListener('change', () => {
      const a = num(angle, nowAngle)
      if (straight && movable) {
        // Keep it straight: pivot the free point so `point`->`neighbor` faces `a`.
        moveFocus(polar(neighbor, dist(point, neighbor), a + 180))
      } else {
        writeSeg(seg, build(polar(point, dist(point, control), a))) // bend to the angle
      }
    })
    controls.append(angle)

    // Per-segment straight<->curved toggle (auto-detected from the segment; this flips it).
    const toggle = document.createElement('button')
    toggle.type = 'button'
    toggle.className = 'props-toggle'
    toggle.textContent = straight ? 'straight' : 'curved'
    toggle.title = straight ? 'Straight — click to curve' : 'Curved — click to straighten'
    toggle.addEventListener('click', () => writeSeg(seg, straight ? build(control) : null))
    controls.append(toggle)
    angleRow.append(controls)

    // Pull (arm reach) only makes sense once the segment is curved.
    if (!straight) {
      const pull = pullInput(dist(point, control))
      pull.addEventListener('change', () =>
        writeSeg(
          seg,
          build(polar(point, num(pull, dist(point, control)), degExact(point, control))),
        ),
      )
      row(host, `${label} pull`).append(pull)
    }
  }

  // In arm: the segment arriving at this point. Out arm: the segment leaving it.
  if (prevPoint) arm('In', anchor - 1, prevPoint, 'c2')
  if (nextPoint) arm('Out', anchor, nextPoint, 'c1')
}

/** A third of the way from `from` to `to` — a straight cubic's control point on that chord. */
function third(from: Point, to: Point): Point {
  return { x: from.x + (to.x - from.x) / 3, y: from.y + (to.y - from.y) / 3 }
}

/** A field's numeric value, or `fallback` when it was cleared to blank. */
function num(input: HTMLInputElement, fallback: number): number {
  return input.value === '' ? fallback : Number(input.value)
}

/** Control-arm direction (degrees, y-up) of `from`->`to`, rounded for display. */
function degOf(from: Point, to: Point): number {
  return Math.round(degExact(from, to))
}

/** Exact (unrounded) control-arm direction in degrees — used when only the pull changes. */
function degExact(from: Point, to: Point): number {
  return Math.atan2(to.y - from.y, to.x - from.x) * DEG
}

/** Round a point to 4 dp (the renderer's precision) so edited controls serialize cleanly. */
function round4(p: Point): Point {
  return { x: Number(p.x.toFixed(4)), y: Number(p.y.toFixed(4)) }
}

function dist(from: Point, to: Point): number {
  return Math.hypot(to.x - from.x, to.y - from.y)
}

/** Control point at `reach` from `origin` along `deg` (y-up). Inverse of degOf/dist. */
function polar(origin: Point, reach: number, deg: number): Point {
  const r = deg / DEG
  return { x: origin.x + reach * Math.cos(r), y: origin.y + reach * Math.sin(r) }
}

function angleInput(value: number): HTMLInputElement {
  const input = document.createElement('input')
  input.type = 'number'
  input.step = '5'
  input.value = String(value)
  input.className = 'props-num'
  return input
}

function pullInput(value: number): HTMLInputElement {
  const input = document.createElement('input')
  input.type = 'number'
  input.step = '0.1'
  input.min = '0'
  input.value = String(Math.round(value * 100) / 100)
  input.className = 'props-num'
  return input
}

function paintNode(
  host: HTMLElement,
  picture: TikzPicture,
  name: string,
  actions: PropertiesActions,
): void {
  const node = findNode(picture, name)
  if (!node) {
    host.hidden = true
    return
  }
  heading(host, name)

  // Size: explicit `text width` / `minimum height` (blank = auto, i.e. content-driven).
  const widthRow = row(host, 'Width')
  const width = optionalNumberInput(textWidth(node))
  width.addEventListener('change', () =>
    actions.resizeNode(name, { textWidth: width.value === '' ? null : Number(width.value) }),
  )
  widthRow.append(width)

  const heightRow = row(host, 'Height')
  const height = optionalNumberInput(minHeight(node))
  height.addEventListener('change', () =>
    actions.resizeNode(name, { minHeight: height.value === '' ? null : Number(height.value) }),
  )
  heightRow.append(height)

  // Overlay reveal (ADR 0018): a Beamer overlay spec for the whole node; blank = always
  // visible. Committed only when valid (a malformed spec shows a red outline, no write).
  const revealRow = row(host, 'Reveal')
  const reveal = document.createElement('input')
  reveal.type = 'text'
  reveal.className = 'props-num'
  reveal.placeholder = 'always'
  reveal.value = nodeOverlay(node)?.raw ?? ''
  reveal.title = 'Steps this node appears on, e.g. 2-, 2, or 1,3 (Beamer overlay spec)'
  reveal.addEventListener('change', () => {
    const raw = reveal.value.trim()
    if (raw === '') {
      reveal.style.outline = ''
      actions.setNodeOverlay(name, null)
    } else if (isValidSpec(raw)) {
      reveal.style.outline = ''
      actions.setNodeOverlay(name, raw)
    } else {
      reveal.style.outline = '1px solid #c0392b' // malformed — keep the value, do not commit
    }
  })
  revealRow.append(reveal)

  paintNodeStyle(host, node, name, actions)

  const place = placement(node)

  if (place) {
    // Relative: side, gap, ref.
    const badge = document.createElement('div')
    badge.className = 'props-mode'
    badge.textContent = 'Relative'
    host.append(badge)

    const sideRow = row(host, 'Side')
    const side = document.createElement('select')
    for (const s of ['above', 'below', 'left', 'right'] as Side[]) {
      const opt = document.createElement('option')
      opt.value = s
      opt.textContent = s
      if (s === place.side) opt.selected = true
      side.append(opt)
    }
    side.addEventListener('change', () =>
      actions.bindNode(name, { side: side.value as Side, gap: place.gap, ref: place.ref }),
    )
    sideRow.append(side)

    const gapRow = row(host, 'Gap')
    const gap = numberInput(place.gap)
    gap.addEventListener('change', () =>
      actions.bindNode(name, { side: place.side, gap: Number(gap.value), ref: place.ref }),
    )
    gapRow.append(gap)

    const refRow = row(host, 'Of')
    const ref = document.createElement('span')
    ref.className = 'props-value'
    ref.textContent = place.ref
    refRow.append(ref)
    return
  }

  // Absolute: x, y.
  const at = node.at ?? { x: 0, y: 0 }
  const badge = document.createElement('div')
  badge.className = 'props-mode'
  badge.textContent = 'Absolute'
  host.append(badge)

  const commit = (): void => actions.moveNode(name, { x: Number(x.value), y: Number(y.value) })
  const xRow = row(host, 'X')
  const x = numberInput(at.x)
  x.addEventListener('change', commit)
  xRow.append(x)
  const yRow = row(host, 'Y')
  const y = numberInput(at.y)
  y.addEventListener('change', commit)
  yRow.append(y)
}

/**
 * The Style section: the paint knobs of the selected node, each reading a `tikz/options`
 * derived view and writing through a `shapes/nodeStyle` helper + `setNodeStyle`. Every control
 * recomputes its edit from the node's CURRENT `options`, so it only rewrites its own knob and
 * leaves the role class, placement, and size intact. Stroke sub-controls disable while the box
 * is undrawn; corners show only for rectangles.
 */
function paintNodeStyle(
  host: HTMLElement,
  node: NodeStatement,
  name: string,
  actions: PropertiesActions,
): void {
  const apply = (options: string[]): void => actions.setNodeStyle(name, options)

  const sub = document.createElement('div')
  sub.className = 'props-title props-subtitle'
  sub.textContent = 'Style'
  host.append(sub)

  // The shape itself is chosen from the shapes panel (drag/drop), not here; the Style
  // section edits only paint knobs. `shape` still gates the rectangle-only corners control.
  const shape = nodeShape(node)

  // Fill: a toggle plus a colour swatch (disabled when unfilled).
  const fill = fillColor(node)
  const fillRow = row(host, 'Fill')
  const fillControls = document.createElement('div')
  fillControls.className = 'props-inline'
  fillControls.append(
    checkbox(fill !== undefined, (on) =>
      apply(withFillColor(node.options, on ? (fill ?? '#cccccc') : null)),
    ),
    colorInput(fill, '#cccccc', fill === undefined, (c) => apply(withFillColor(node.options, c))),
  )
  fillRow.append(fillControls)

  // Stroke: draw toggle plus colour; width and dash below (all inert while undrawn).
  const drawn = isDrawn(node)
  const strokeRow = row(host, 'Stroke')
  const strokeControls = document.createElement('div')
  strokeControls.className = 'props-inline'
  strokeControls.append(
    checkbox(drawn, (on) => apply(withStroke(node.options, on))),
    colorInput(strokeColor(node), '#333333', !drawn, (c) =>
      apply(withStrokeColor(node.options, c)),
    ),
  )
  strokeRow.append(strokeControls)

  const widthSel = styleSelect(['default', ...LINE_WIDTHS], lineWidthName(node) ?? 'default', (v) =>
    apply(withLineWidth(node.options, v === 'default' ? null : (v as LineWidthName))),
  )
  widthSel.disabled = !drawn
  row(host, 'Line').append(widthSel)

  const dashSel = styleSelect(['solid', ...DASH_PATTERNS], dashPattern(node) ?? 'solid', (v) =>
    apply(withDash(node.options, v === 'solid' ? null : (v as DashPattern))),
  )
  dashSel.disabled = !drawn
  row(host, 'Dash').append(dashSel)

  // Rounded corners are a rectangle-only knob (an ellipse has none).
  if (shape === 'rectangle') {
    const corners = optionalNumberInput(cornerRadiusPt(node))
    corners.title = 'Corner radius in pt (blank = square)'
    corners.addEventListener('change', () =>
      apply(withCorners(node.options, corners.value === '' ? null : Number(corners.value))),
    )
    row(host, 'Corners').append(corners)
  }

  // Opacities: whole-node, fill-only, stroke-only (blank = fully opaque).
  opacityRow(host, 'Opacity', opacity(node), (v) => apply(withOpacity(node.options, v)))
  opacityRow(host, 'Fill α', fillOpacity(node), (v) => apply(withFillOpacity(node.options, v)))
  opacityRow(host, 'Stroke α', drawOpacity(node), (v) => apply(withDrawOpacity(node.options, v)))
}

/** A segmented single-choice control (like the arrow Heads picker); highlights `current`. */
function segmented(
  choices: { value: string; label: string }[],
  current: string,
  onPick: (value: string) => void,
): HTMLElement {
  const group = document.createElement('div')
  group.className = 'props-seg'
  for (const choice of choices) {
    const button = document.createElement('button')
    button.type = 'button'
    button.textContent = choice.label
    button.title = choice.value
    button.className = choice.value === current ? 'is-active' : ''
    button.addEventListener('click', () => onPick(choice.value))
    group.append(button)
  }
  return group
}

function checkbox(checked: boolean, onChange: (on: boolean) => void): HTMLInputElement {
  const input = document.createElement('input')
  input.type = 'checkbox'
  input.checked = checked
  input.addEventListener('change', () => onChange(input.checked))
  return input
}

/** A colour swatch. `<input type=color>` only shows `#rrggbb`, so a named/expression colour
 *  (e.g. `red`, `blue!50`) renders as black until changed — but is left untouched until then. */
function colorInput(
  value: string | undefined,
  fallback: string,
  disabled: boolean,
  onChange: (color: string) => void,
): HTMLInputElement {
  const input = document.createElement('input')
  input.type = 'color'
  input.className = 'props-color'
  input.disabled = disabled
  input.value = /^#[0-9a-fA-F]{6}$/.test(value ?? '') ? value! : fallback
  input.addEventListener('change', () => onChange(input.value))
  return input
}

function styleSelect(
  values: readonly string[],
  current: string,
  onChange: (value: string) => void,
): HTMLSelectElement {
  const select = document.createElement('select')
  for (const value of values) {
    const option = document.createElement('option')
    option.value = value
    option.textContent = value
    if (value === current) option.selected = true
    select.append(option)
  }
  select.addEventListener('change', () => onChange(select.value))
  return select
}

/** A 0..1 alpha field, blank when unset (fully opaque); clearing it resets to opaque. */
function opacityRow(
  host: HTMLElement,
  label: string,
  value: number | undefined,
  onChange: (value: number | null) => void,
): void {
  const input = document.createElement('input')
  input.type = 'number'
  input.step = '0.1'
  input.min = '0'
  input.max = '1'
  input.placeholder = '1'
  input.className = 'props-num'
  input.value = value === undefined ? '' : String(value)
  input.addEventListener('change', () => onChange(input.value === '' ? null : Number(input.value)))
  row(host, label).append(input)
}

function numberInput(value: number): HTMLInputElement {
  const input = document.createElement('input')
  input.type = 'number'
  input.step = '0.1'
  input.value = String(value)
  input.className = 'props-num'
  return input
}

/** A numeric input that is blank when the value is unset (auto): clearing it resets to auto. */
function optionalNumberInput(value: number | undefined): HTMLInputElement {
  const input = document.createElement('input')
  input.type = 'number'
  input.step = '0.1'
  input.min = '0'
  input.value = value === undefined ? '' : String(value)
  input.placeholder = 'auto'
  input.className = 'props-num'
  return input
}

function directionOf(options: string[]): Direction {
  if (options.includes('<->')) return 'both'
  const forward = options.includes('->')
  const back = options.includes('<-')
  return forward && back ? 'both' : forward ? 'forward' : back ? 'back' : 'none'
}

/** New option tokens with the head direction set, keeping every other token. */
function withDirection(options: string[], direction: Direction): string[] {
  const rest = options.filter((t) => !HEAD_TOKENS.includes(t))
  const token =
    direction === 'forward'
      ? '->'
      : direction === 'back'
        ? '<-'
        : direction === 'both'
          ? '<->'
          : null
  return token ? [token, ...rest] : rest // head token leads, TikZ-style
}

function withDashed(options: string[], on: boolean): string[] {
  const rest = options.filter((t) => t !== 'dashed')
  return on ? [...rest, 'dashed'] : rest
}
