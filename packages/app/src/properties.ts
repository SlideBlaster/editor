/**
 * The properties panel. Contract: see properties.md.
 *
 * A small inspector for the current selection (E5, scoped). For a selected connector it
 * edits arrow style — head direction and dashing (via `setConnectorOptions`) — plus, when a
 * curved segment is focused, that segment's cubic controls as polar angle/pull fields (via
 * `updateConnectorPath`). For a selected node it reads and edits placement — absolute
 * `at (x,y)` (`moveNode`) or relative `below=<gap> of ref` (`bindNode`). Node style classes
 * and colours are deferred. Frame-bound by the controller; this module is frame-agnostic.
 */
import {
  findNode,
  placement,
  textWidth,
  minHeight,
  connectorOptions,
  type ConnectorPath,
  type CurveControls,
  type Point,
  type TikzPicture,
} from '@slideblaster/editor'
import type { CurveFocus } from './connectorEditor'

export type PropSelection =
  { kind: 'node'; name: string } | { kind: 'connector'; index: number } | null

type Side = 'above' | 'below' | 'left' | 'right'

export interface PropertiesActions {
  moveNode(name: string, center: Point): void
  bindNode(name: string, binding: { side: Side; gap: number; ref: string }): void
  /** Set (number) or clear (null) a node's explicit size options; omit a key to leave it. */
  resizeNode(name: string, patch: { textWidth?: number | null; minHeight?: number | null }): void
  setConnectorOptions(index: number, options: string[]): void
  /** E4+: replace a connector's shape — the panel uses this to write curve angles/pulls. */
  updateConnectorPath(index: number, path: ConnectorPath): void
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
 * user selected on the canvas. It edits the tangent control arm(s) that meet at that point:
 * an **In** arm (from the incoming segment) and/or an **Out** arm (into the outgoing one),
 * each an **angle** (0° right, 90° up — slide space is y-up) and a **pull** (arm reach).
 * Editing a field rewrites only that arm's control point (the segment's other control and all
 * other segments stay byte-identical, symbolic node anchors preserved) and commits via
 * `updateConnectorPath`. A straight neighbour has no controls yet, so its arm shows the
 * chord's own direction with a default pull — set an angle and that segment bends.
 */
function paintCurve(
  host: HTMLElement,
  index: number,
  focus: CurveFocus,
  actions: PropertiesActions,
): void {
  const { point, prevPoint, nextPoint, path, anchor } = focus

  const sub = document.createElement('div')
  sub.className = 'props-title props-subtitle'
  sub.textContent = 'Curve'
  host.append(sub)

  // Commit one segment's controls, rounding to renderer precision and leaving the rest as-is.
  const writeSeg = (seg: number, controls: CurveControls): void => {
    const curves = path.curves.map((c, i) =>
      i === seg ? { c1: round4(controls.c1), c2: round4(controls.c2) } : c,
    )
    actions.updateConnectorPath(index, { anchors: path.anchors, curves })
  }

  // One control arm at `point`: an angle + pull that rewrite `control` (the `side` of segment
  // `seg`) while `keep` (its other control point) stays put. `side` names which end is edited.
  const arm = (label: string, seg: number, control: Point, keep: Point, side: 'c1' | 'c2'): void => {
    const build = (c: Point): CurveControls =>
      side === 'c2' ? { c1: keep, c2: c } : { c1: c, c2: keep }
    const angle = angleInput(degOf(point, control))
    angle.addEventListener('change', () =>
      writeSeg(seg, build(polar(point, dist(point, control), num(angle, degOf(point, control))))),
    )
    const pull = pullInput(dist(point, control))
    pull.addEventListener('change', () =>
      writeSeg(seg, build(polar(point, num(pull, dist(point, control)), degExact(point, control)))),
    )
    row(host, `${label} ∠`).append(angle)
    row(host, `${label} pull`).append(pull)
  }

  // In arm: the segment arriving at this point (its c2 sits by `point`). Out arm: the segment
  // leaving it (its c1 sits by `point`). A straight neighbour falls back to chord-thirds.
  if (prevPoint) {
    const seg = anchor - 1
    const cur = path.curves[seg]
    arm('In', seg, cur?.c2 ?? third(point, prevPoint), cur?.c1 ?? third(prevPoint, point), 'c2')
  }
  if (nextPoint) {
    const seg = anchor
    const cur = path.curves[seg]
    arm('Out', seg, cur?.c1 ?? third(point, nextPoint), cur?.c2 ?? third(nextPoint, point), 'c1')
  }
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
