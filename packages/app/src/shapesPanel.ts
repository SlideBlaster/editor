/**
 * The shapes panel: a docked right rail — the draw.io-style shape library. Contract: see
 * shapesPanel.md.
 *
 * Presents the `shapes/catalog` as a searchable grid of thumbnails grouped by category.
 * Each thumbnail is drawn by the engine's `shapeGeometrySvg` — the SAME function the canvas
 * renders a node box with — so a shape's preview always matches what dropping it produces.
 *
 * Two ways to add a shape, both ending in the controller's shape insert:
 *  - Click a cell -> `onInsert(id)` (drops at the active slide's centre; always works).
 *  - Drag a cell onto the canvas -> the deck's drop handler reads `SHAPE_DRAG_MIME` and
 *    inserts at the cursor point (wired in createApp; this module only sets the payload).
 */
import { shapeGeometrySvg, type NodeStatement } from '@slideblaster/editor'
import { shapeCategories, shapeMatches, type ShapeDef } from './shapes/catalog'

/** The dataTransfer type carrying a dragged shape's id from a panel cell to the canvas. */
export const SHAPE_DRAG_MIME = 'application/x-slideblaster-shape'

export interface ShapesPanelOptions {
  /** Insert the shape with this id (click, or the drop handler's fallback). */
  onInsert(shapeId: string): void
}

/** Render the shape library into `host` (the `#shapes-panel` aside). Idempotent: re-render
 *  replaces prior content. */
export function renderShapesPanel(host: HTMLElement, opts: ShapesPanelOptions): void {
  host.replaceChildren()

  const head = document.createElement('div')
  head.className = 'shapes-head'
  head.textContent = 'Shapes'

  const search = document.createElement('input')
  search.className = 'shapes-search'
  search.type = 'search'
  search.placeholder = 'Search shapes…'
  search.spellcheck = false
  search.setAttribute('aria-label', 'Search shapes')

  const list = document.createElement('div')
  list.className = 'shapes-list'

  const empty = document.createElement('div')
  empty.className = 'shapes-empty'
  empty.textContent = 'No shapes match.'
  empty.hidden = true

  const renderList = (query: string): void => {
    list.replaceChildren()
    let any = false
    for (const category of shapeCategories()) {
      const shapes = category.shapes.filter((shape) => shapeMatches(shape, query))
      if (shapes.length === 0) continue
      any = true
      list.append(categorySection(category.name, shapes, opts))
    }
    empty.hidden = any
  }

  search.addEventListener('input', () => renderList(search.value))

  host.append(head, search, list, empty)
  renderList('')
}

/** One category: a heading and a grid of its shape cells. */
function categorySection(name: string, shapes: ShapeDef[], opts: ShapesPanelOptions): HTMLElement {
  const section = document.createElement('section')
  section.className = 'shapes-category'

  const heading = document.createElement('h3')
  heading.className = 'shapes-cat-name'
  heading.textContent = name

  const grid = document.createElement('div')
  grid.className = 'shapes-grid'
  for (const shape of shapes) grid.append(shapeCell(shape, opts))

  section.append(heading, grid)
  return section
}

/** One draggable, clickable shape cell: its thumbnail over its label. */
function shapeCell(shape: ShapeDef, opts: ShapesPanelOptions): HTMLElement {
  const cell = document.createElement('button')
  cell.type = 'button'
  cell.className = 'sb-shape-cell'
  cell.dataset.shape = shape.id
  cell.title = shape.label
  cell.draggable = true
  cell.innerHTML = previewSvg(shape)

  const label = document.createElement('span')
  label.className = 'sb-shape-label'
  label.textContent = shape.label
  cell.append(label)

  cell.addEventListener('click', () => opts.onInsert(shape.id))
  cell.addEventListener('dragstart', (event) => {
    event.dataTransfer?.setData(SHAPE_DRAG_MIME, shape.id)
    event.dataTransfer?.setData('text/plain', shape.label) // harmless fallback for non-drop targets
    if (event.dataTransfer) event.dataTransfer.effectAllowed = 'copy'
  })

  return cell
}

/** The thumbnail: a tiny SVG of the shape, drawn by the engine's `shapeGeometrySvg` (so it
 *  matches the canvas) in the shape's own slide units, centred with padding. */
function previewSvg(shape: ShapeDef): string {
  const pad = 0.5
  const { width, height } = shape.size
  const node: NodeStatement = { kind: 'node', options: shape.options, content: { kind: 'empty' } }
  const geometry = shapeGeometrySvg(node, { x: pad, y: pad, width, height })
  return (
    `<svg class="sb-shape-preview" viewBox="0 0 ${width + pad * 2} ${height + pad * 2}" ` +
    `preserveAspectRatio="xMidYMid meet" aria-hidden="true">${geometry}</svg>`
  )
}
