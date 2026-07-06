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
 * latexml is one-way, so the rendered cells carry no source. We align them to the grid
 * `parseTabular` reads from the SAME source, by position — safe only for a non-spanned
 * table whose compiled row/cell counts match the source. A spanned or mismatched table
 * gets the "</>" deep editor only. Geometry is DOM-measured, so it runs after paint.
 */
import {
  deferredTableSources,
  insertTabularRow,
  parseTabular,
  setDeferredSource,
  setTabularCell,
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
  const tableEl = wrapper.querySelector<HTMLElement>('table')
  const cells = editableCells(tableEl, grid) // null ⇒ not cell-editable (pending/spanned/mismatch)

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
  if (cells && grid) {
    // Inline cell editing: a click target over each rendered cell.
    for (const cell of cells) {
      const hot = div('sb-table-cell', layer)
      hot.title = 'Edit cell'
      hot.addEventListener('pointerdown', (event) => event.stopPropagation())
      hot.addEventListener('click', (event) => {
        event.stopPropagation()
        openCellEditor(overlay, slideEl, cell.el, grid.rows[cell.r]!.cells[cell.c]!.text, (text) =>
          commit(setTabularCell(source, cell.r, cell.c, text)),
        )
      })
      cell.hot = hot
    }
    // "+" appends a row after the last data row.
    addRow = div('sb-table-add', layer)
    addRow.textContent = '+'
    addRow.title = 'Add row'
    addRow.addEventListener('pointerdown', (event) => event.stopPropagation())
    addRow.addEventListener('click', (event) => {
      event.stopPropagation()
      commit(insertTabularRow(source, grid.rows.length - 1))
    })
  }

  // Place everything from measured rects (one pass — the render is already laid out).
  const sr = slideEl.getBoundingClientRect()
  const wr = wrapper.getBoundingClientRect()
  placeAt(sourceGrip, sr, wr.right - sr.left, wr.top - sr.top)
  if (cells) for (const cell of cells) placeRect(cell.hot!, sr, cell.el.getBoundingClientRect())
  if (addRow) placeAt(addRow, sr, wr.left + wr.width / 2 - sr.left, wr.bottom - sr.top)
}

interface CellRef {
  r: number
  c: number
  el: HTMLElement
  hot?: HTMLElement
}

/** The rendered cells zipped onto the source grid, or null when they can't be aligned. */
function editableCells(tableEl: HTMLElement | null, grid: TabularGrid | null): CellRef[] | null {
  if (!tableEl || !grid || grid.spanned) return null
  const rows = [...tableEl.querySelectorAll<HTMLElement>('tr')]
  if (rows.length !== grid.rows.length) return null
  const cells: CellRef[] = []
  for (let r = 0; r < rows.length; r++) {
    const domCells = [...rows[r]!.querySelectorAll<HTMLElement>(':scope > td, :scope > th')]
    if (domCells.length !== grid.rows[r]!.cells.length) return null
    for (let c = 0; c < domCells.length; c++) cells.push({ r, c, el: domCells[c]! })
  }
  return cells
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
