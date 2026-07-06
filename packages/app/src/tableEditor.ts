/**
 * Table grid affordance. Contract: see tableEditor.md.
 *
 * The view half of shallow (cell/row) table editing (see engine `tabular.ts`). Over the
 * SELECTED node it decorates every compiled `deferred` table with: a click target on
 * each rendered cell that opens an inline editor seeded from the cell's SOURCE text, a
 * "+" to append a row, and a "</>" toggle that opens the raw `tabular` source in a popup
 * (the deep-edit level). Every gesture becomes one source-string edit (`setTabularCell`
 * / `insertTabularRow`) spliced into the `deferred` run via `setDeferredSource`, which
 * the controller commits with `editContentModel`; latexml then re-compiles the source.
 *
 * latexml is one-way, so a rendered cell carries no source of its own. The annotation
 * binding (see adapters-shared `tableAnnotation.ts`) stamps every compiled cell with its
 * physical grid position as `data-sbx`/`data-sby`; we read that back and resolve it to a
 * source cell with `resolveTabularCell` — exact even across `\multicolumn`/`\multirow`,
 * and never trusting the HTML structure. A table whose cells lack coordinates (annotation
 * off, or a cache entry compiled before it) gets the "</>" deep editor only. Geometry is
 * DOM-measured, so this runs after paint.
 */
import {
  deferredTableSources,
  insertTabularColumn,
  insertTabularRow,
  parseTabular,
  resolveTabularCell,
  setDeferredSource,
  setTabularCell,
  EMPTY_CELL,
  type NodeContent,
  type TabularGrid,
} from '@slideblaster/editor'

export interface TableActions {
  editContentModel(name: string, content: NodeContent): void
}

/** Decorate every compiled `deferred` table in the selected node's content subtree. */
export function paintTableEditors(
  overlay: HTMLElement,
  slideEl: HTMLElement,
  contentEl: HTMLElement,
  name: string,
  content: NodeContent,
  actions: TableActions,
): void {
  const sources = deferredTableSources(content)
  const wrappers = [...contentEl.querySelectorAll<HTMLElement>('[data-feature="table"]')]
  wrappers.forEach((wrapper, tableIndex) => {
    const source = sources[tableIndex]
    if (source === undefined) return
    mountTable(overlay, slideEl, wrapper, tableIndex, source, name, content, actions)
  })
}

/** A rendered cell resolved to its source (row, col) via the compiled `data-sbx/y`. */
interface CellHot {
  el: HTMLElement
  row: number
  col: number
}

function mountTable(
  overlay: HTMLElement,
  slideEl: HTMLElement,
  wrapper: HTMLElement,
  tableIndex: number,
  source: string,
  name: string,
  content: NodeContent,
  actions: TableActions,
): void {
  const layer = div('sb-table-edit', overlay)
  const commit = (nextSource: string): void => {
    if (nextSource === source) return
    actions.editContentModel(name, setDeferredSource(content, tableIndex, nextSource))
  }

  const grid = parseTabular(source)
  const table = wrapper.querySelector<HTMLElement>('table')
  const hots = grid && table ? resolveCells(table, grid) : null

  // "</>" deep-edit toggle — always available, in the wrapper's top-right corner.
  const sourceGrip = div('sb-table-source', layer)
  sourceGrip.textContent = '</>'
  sourceGrip.title = 'Edit table source'
  sourceGrip.addEventListener('pointerdown', (event) => event.stopPropagation())
  sourceGrip.addEventListener('click', (event) => {
    event.stopPropagation()
    openSourcePopup(source, commit)
  })

  let addRow: HTMLElement | null = null
  let addCol: HTMLElement | null = null
  if (grid && hots) {
    // Inline cell editing: a click target over each rendered cell.
    for (const hot of hots) {
      const raw = grid.rows[hot.row]?.cells[hot.col]?.content.text ?? ''
      const seed = raw === EMPTY_CELL ? '' : raw // a fresh cell's placeholder reads as empty
      const cell = div('sb-table-cell', layer)
      cell.title = 'Edit cell'
      cell.addEventListener('pointerdown', (event) => event.stopPropagation())
      cell.addEventListener('click', (event) => {
        event.stopPropagation()
        openCellEditor(overlay, slideEl, hot.el, seed, (text) =>
          commit(setTabularCell(source, hot.row, hot.col, text)),
        )
      })
      placeRect(cell, slideEl.getBoundingClientRect(), hot.el.getBoundingClientRect())
    }
    // "+" grips append a row (below) and a column (right).
    addRow = grip(layer, '+', 'Add row', () =>
      commit(insertTabularRow(source, grid.rows.length - 1)),
    )
    addCol = grip(layer, '+', 'Add column', () => commit(insertTabularColumn(source)))
  }

  // Place the wrapper-anchored grips from measured rects (one pass — already laid out).
  const sr = slideEl.getBoundingClientRect()
  const wr = wrapper.getBoundingClientRect()
  placeAt(sourceGrip, sr, wr.right - sr.left, wr.top - sr.top)
  if (addRow) placeAt(addRow, sr, wr.left + wr.width / 2 - sr.left, wr.bottom - sr.top)
  if (addCol) placeAt(addCol, sr, wr.right - sr.left, wr.top + wr.height / 2 - sr.top)
}

/** A round "+" grip on the inert layer that runs `onClick` without dragging the node. */
function grip(layer: HTMLElement, label: string, title: string, onClick: () => void): HTMLElement {
  const el = div('sb-table-add', layer)
  el.textContent = label
  el.title = title
  el.addEventListener('pointerdown', (event) => event.stopPropagation())
  el.addEventListener('click', (event) => {
    event.stopPropagation()
    onClick()
  })
  return el
}

/** Zip the compiled cells (those the annotation binding coordinated) onto the source
 *  grid. Cells are scoped to the outermost table so a nested tabular's own coordinates
 *  never mis-resolve against this grid. Null when no cell carries coordinates. */
function resolveCells(table: HTMLElement, grid: TabularGrid): CellHot[] | null {
  const cells = [...table.querySelectorAll<HTMLElement>('td[data-sbx], th[data-sbx]')]
  const hots: CellHot[] = []
  for (const el of cells) {
    if (el.closest('table') !== table) continue // belongs to a nested tabular
    const x = Number(el.getAttribute('data-sbx'))
    const y = Number(el.getAttribute('data-sby'))
    if (!Number.isInteger(x) || !Number.isInteger(y)) continue
    const at = resolveTabularCell(grid, x, y)
    if (at) hots.push({ el, row: at.row, col: at.col })
  }
  return hots.length ? hots : null
}

/** Open an inline editor over a cell, seeded with its source text; commit on blur/Enter. */
function openCellEditor(
  overlay: HTMLElement,
  slideEl: HTMLElement,
  cellEl: HTMLElement,
  seed: string,
  onCommit: (text: string) => void,
): void {
  if (overlay.querySelector('.sb-table-cell-editor')) return
  const editor = document.createElement('textarea')
  editor.className = 'sb-table-cell-editor'
  editor.value = seed
  editor.spellcheck = false
  placeRect(editor, slideEl.getBoundingClientRect(), cellEl.getBoundingClientRect())

  let settled = false
  const close = (commit: boolean): void => {
    if (settled) return
    settled = true // removing a focused textarea fires blur, which must not re-enter
    editor.remove()
    if (commit && editor.value !== seed) onCommit(editor.value)
  }
  editor.addEventListener('blur', () => close(true))
  editor.addEventListener('keydown', (event) => {
    event.stopPropagation() // keep Delete / zoom shortcuts out while typing
    if (event.key === 'Escape') {
      event.preventDefault()
      close(false)
    } else if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      editor.blur() // commit; Shift+Enter keeps a literal newline in the cell
    }
  })
  overlay.append(editor)
  editor.focus()
  editor.select()
}

/** The deep-edit level: the whole `tabular` source in a modal textarea (popup for a small
 *  table whose source dwarfs its rendered box). Save commits; Cancel/Escape discards. */
function openSourcePopup(source: string, onCommit: (next: string) => void): void {
  const dialog = document.createElement('dialog')
  dialog.className = 'sb-dialog sb-table-source-dialog'

  const form = document.createElement('form')
  form.method = 'dialog'
  form.className = 'sb-dialog-form'

  const title = document.createElement('h2')
  title.className = 'sb-dialog-title'
  title.textContent = 'Table source'
  form.append(title)

  const area = document.createElement('textarea')
  area.className = 'sb-table-source-input'
  area.value = source
  area.spellcheck = false
  area.rows = Math.min(20, Math.max(4, source.split('\n').length + 1))
  form.append(area)

  const actions = document.createElement('div')
  actions.className = 'sb-dialog-actions'
  const cancel = document.createElement('button')
  cancel.type = 'button'
  cancel.className = 'sb-dialog-button sb-dialog-cancel'
  cancel.textContent = 'Cancel'
  cancel.addEventListener('click', () => dialog.close())
  const save = document.createElement('button')
  save.type = 'submit'
  save.className = 'sb-dialog-button sb-dialog-confirm'
  save.textContent = 'Save'
  actions.append(cancel, save)
  form.append(actions)
  dialog.append(form)
  document.body.append(dialog)

  let confirmed = false
  form.addEventListener('submit', () => {
    confirmed = true
  })
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) dialog.close()
  })
  dialog.addEventListener('keydown', (event) => {
    // Ctrl/Cmd+Enter submits from inside the textarea (plain Enter is a newline).
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      confirmed = true
      dialog.close()
    }
  })
  dialog.addEventListener('close', () => {
    const value = area.value
    dialog.remove()
    if (confirmed && value !== source) onCommit(value)
  })

  dialog.showModal()
  area.focus()
}

/** Position an element to cover `rect`, as percentages of the slide box (zoom-independent). */
function placeRect(el: HTMLElement, slideRect: DOMRect, rect: DOMRect): void {
  el.style.left = pct(rect.left - slideRect.left, slideRect.width)
  el.style.top = pct(rect.top - slideRect.top, slideRect.height)
  el.style.width = pct(rect.width, slideRect.width)
  el.style.height = pct(rect.height, slideRect.height)
}

/** Position an element's center at slide-space pixel point (x, y) offset within the slide. */
function placeAt(el: HTMLElement, slideRect: DOMRect, x: number, y: number): void {
  el.style.left = pct(x, slideRect.width)
  el.style.top = pct(y, slideRect.height)
}

function pct(px: number, total: number): string {
  return `${(px / total) * 100}%`
}

function div(cls: string, parent: HTMLElement): HTMLElement {
  const el = document.createElement('div')
  el.className = cls
  parent.append(el)
  return el
}
