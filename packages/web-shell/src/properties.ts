/**
 * The properties panel. Contract: see properties.md.
 *
 * A small inspector for the current selection (E5, scoped). For a selected connector it
 * edits arrow style — head direction and dashing (via `setConnectorOptions`). For a
 * selected node it reads and edits placement — absolute `at (x,y)` (`moveNode`) or
 * relative `below=<gap> of ref` (`bindNode`). Node style classes and colours are deferred.
 * Frame-bound by the controller; this module is frame-agnostic.
 */
import {
  findNode,
  placement,
  connectorOptions,
  type Point,
  type TikzPicture,
} from '@slideblaster/editor'

export type PropSelection =
  { kind: 'node'; name: string } | { kind: 'connector'; index: number } | null

type Side = 'above' | 'below' | 'left' | 'right'

export interface PropertiesActions {
  moveNode(name: string, center: Point): void
  bindNode(name: string, binding: { side: Side; gap: number; ref: string }): void
  setConnectorOptions(index: number, options: string[]): void
}

export interface PropertiesProps {
  selection: PropSelection
  picture: TikzPicture | null
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
    paintArrow(host, props.picture, props.selection.index, props.actions)
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
