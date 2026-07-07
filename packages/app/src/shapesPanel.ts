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
import { SHAPES, shapeFamilies, shapeMatches, type ShapeDef } from './shapes/catalog'

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

  // Empty query: one collapsible <details> per family, its cells rendered lazily on first open
  // (drawing all 2000+ thumbnails up front would be far too heavy). A query: a flat, capped grid
  // of matches across every family.
  const SEARCH_CAP = 300
  const renderList = (query: string): void => {
    list.replaceChildren()
    const q = query.trim()
    if (q === '') {
      for (const family of shapeFamilies()) {
        list.append(familySection(family.name, family.shapes, opts))
      }
      empty.hidden = SHAPES.length > 0
      return
    }
    const matches = SHAPES.filter((shape) => shapeMatches(shape, q))
    empty.hidden = matches.length > 0
    const grid = document.createElement('div')
    grid.className = 'shapes-grid'
    for (const shape of matches.slice(0, SEARCH_CAP)) grid.append(shapeCell(shape, opts))
    list.append(grid)
    if (matches.length > SEARCH_CAP) {
      const more = document.createElement('p')
      more.className = 'shapes-more'
      more.textContent = `Showing ${SEARCH_CAP} of ${matches.length} — refine your search to see the rest.`
      list.append(more)
    }
  }

  // Debounce: filtering is cheap, but rendering up to SEARCH_CAP thumbnails per keystroke is not.
  let timer: ReturnType<typeof setTimeout> | undefined
  search.addEventListener('input', () => {
    if (timer !== undefined) clearTimeout(timer)
    timer = setTimeout(() => renderList(search.value), 120)
  })

  host.append(head, search, list, empty, attribution())
  renderList('')
}

/** The stencil library is derived from draw.io shapes under CC BY 4.0; that license requires a
 *  visible credit + link. See packages/app/THIRD_PARTY_NOTICES.md. */
function attribution(): HTMLElement {
  const credit = document.createElement('div')
  credit.className = 'shapes-credit'
  const source = document.createElement('a')
  source.href = 'https://github.com/jgraph/drawio'
  source.target = '_blank'
  source.rel = 'noopener noreferrer'
  source.textContent = 'draw.io'
  const license = document.createElement('a')
  license.href = 'https://creativecommons.org/licenses/by/4.0/'
  license.target = '_blank'
  license.rel = 'noopener noreferrer'
  license.textContent = 'CC BY 4.0'
  credit.append('Stencils from ', source, ' · ', license)
  return credit
}

/** One family: a collapsible section whose grid of cells is rendered lazily the first time it
 *  opens. General/Flowchart start open; the big stencil families start closed so the panel
 *  mounts instantly. */
function familySection(name: string, shapes: ShapeDef[], opts: ShapesPanelOptions): HTMLElement {
  const details = document.createElement('details')
  details.className = 'shapes-family'
  details.open = name === 'General' || name === 'Flowchart'

  const summary = document.createElement('summary')
  summary.className = 'shapes-fam-summary'
  const label = document.createElement('span')
  label.className = 'shapes-fam-name'
  label.textContent = name
  const count = document.createElement('span')
  count.className = 'shapes-fam-count'
  count.textContent = String(shapes.length)
  summary.append(label, count)

  const grid = document.createElement('div')
  grid.className = 'shapes-grid'
  const populate = (): void => {
    if (grid.childElementCount > 0) return
    for (const shape of shapes) grid.append(shapeCell(shape, opts))
  }
  if (details.open) populate()
  details.addEventListener('toggle', () => {
    if (details.open) populate()
  })

  details.append(summary, grid)
  return details
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
