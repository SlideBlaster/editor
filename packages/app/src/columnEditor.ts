/**
 * Column grid affordance. Contract: see columnEditor.md.
 *
 * The view half of the columns editor (ADR 0016). Over the SELECTED node it overlays,
 * per top-level `columns` group: a dashed bound on each column, a draggable divider
 * between neighbours, and a "+" to append a column. Geometry is DOM-measured
 * (`getBoundingClientRect`) because the engine never lays out inside a node. A divider
 * drag previews with pure CSS (`flex-grow`) and commits ONCE on pointerup via a single
 * `NodeContent` transform (`setColumnWidths` / `insertColumn`); the controller turns
 * that into node-scoped source + canvas deltas.
 */
import { insertColumn, setColumnWidths, type NodeContent } from '@slideblaster/editor'

/** A column keeps at least this share of its neighbour pair while dragging. */
const MIN_FRAC = 0.08

export interface ColumnActions {
  editContentModel(name: string, content: NodeContent): void
}

/**
 * Decorate every top-level `columns` group in the selected node's content subtree.
 * `groupIndex` is the group's document (pre-order) position — the same index
 * `setColumnWidths`/`insertColumn` address by, because the renderer emits `.sb-columns`
 * in that order.
 */
export function paintColumnEditors(
  overlay: HTMLElement,
  slideEl: HTMLElement,
  contentEl: HTMLElement,
  name: string,
  content: NodeContent,
  actions: ColumnActions,
): void {
  const groups = [...contentEl.querySelectorAll<HTMLElement>('.sb-columns')]
  groups.forEach((groupEl, groupIndex) => {
    if (groupEl.parentElement?.closest('.sb-columns')) return // top-level groups only
    const cols = [...groupEl.querySelectorAll<HTMLElement>(':scope > .sb-column')]
    if (cols.length === 0) return
    mountGroup(overlay, slideEl, groupEl, cols, groupIndex, name, content, actions)
  })
}

function mountGroup(
  overlay: HTMLElement,
  slideEl: HTMLElement,
  groupEl: HTMLElement,
  cols: readonly HTMLElement[],
  groupIndex: number,
  name: string,
  content: NodeContent,
  actions: ColumnActions,
): void {
  const layer = div('sb-col-edit', overlay)
  const bounds = cols.map(() => div('sb-col-bound', layer))
  const dividers = cols.slice(0, -1).map((_, i) => makeDivider(i))
  const addGrip = div('sb-col-add', layer)
  addGrip.textContent = '+'
  addGrip.title = 'Add column'

  /** Re-place bounds, dividers, and the add grip from current rects (after any reflow). */
  function relayout(): void {
    const sr = slideEl.getBoundingClientRect()
    const gr = groupEl.getBoundingClientRect()
    cols.forEach((col, k) => placeRect(bounds[k]!, sr, col.getBoundingClientRect()))
    dividers.forEach(({ el, i }) => {
      const a = cols[i]!.getBoundingClientRect()
      const b = cols[i + 1]!.getBoundingClientRect()
      el.style.left = pct((a.right + b.left) / 2 - sr.left, sr.width)
      el.style.top = pct(gr.top - sr.top, sr.height)
      el.style.height = pct(gr.height, sr.height)
    })
    addGrip.style.left = pct(gr.right - sr.left, sr.width)
    addGrip.style.top = pct(gr.top + gr.height / 2 - sr.top, sr.height)
  }

  function makeDivider(i: number): { el: HTMLElement; i: number } {
    const el = div('sb-col-divider', layer)
    el.addEventListener('pointerdown', (event) => {
      event.stopPropagation() // don't let the node handle underneath start a node drag
      event.preventDefault()
      el.setPointerCapture(event.pointerId)
      const a = cols[i]!
      const b = cols[i + 1]!
      const combined = flexOf(a) + flexOf(b)
      // The pair's outer span is fixed while dragging — only the internal boundary moves.
      const spanLeft = a.getBoundingClientRect().left
      const spanWidth = b.getBoundingClientRect().right - spanLeft

      const onMove = (ev: PointerEvent): void => {
        const frac = clamp((ev.clientX - spanLeft) / spanWidth, MIN_FRAC, 1 - MIN_FRAC)
        a.style.flexGrow = String(combined * frac) // pure CSS preview; no commit yet
        b.style.flexGrow = String(combined * (1 - frac))
        relayout()
      }
      const onUp = (ev: PointerEvent): void => {
        el.releasePointerCapture(ev.pointerId)
        window.removeEventListener('pointermove', onMove)
        window.removeEventListener('pointerup', onUp)
        const na = round2(flexOf(a))
        const nb = round2(combined - na) // keep the pair sum exact after rounding
        actions.editContentModel(
          name,
          setColumnWidths(content, groupIndex, { [i]: fmt(na), [i + 1]: fmt(nb) }),
        )
      }
      window.addEventListener('pointermove', onMove)
      window.addEventListener('pointerup', onUp)
    })
    return { el, i }
  }

  addGrip.addEventListener('pointerdown', (event) => event.stopPropagation())
  addGrip.addEventListener('click', (event) => {
    event.stopPropagation()
    const avg = round2(cols.reduce((sum, c) => sum + flexOf(c), 0) / cols.length) || 1
    actions.editContentModel(name, insertColumn(content, groupIndex, cols.length, fmt(avg)))
  })

  relayout()
}

function flexOf(el: HTMLElement): number {
  return parseFloat(getComputedStyle(el).flexGrow) || 0
}

function round2(n: number): number {
  return Math.round(n * 100) / 100
}

function fmt(n: number): string {
  return String(round2(n))
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v))
}

function pct(px: number, total: number): string {
  return `${(px / total) * 100}%`
}

function placeRect(el: HTMLElement, slideRect: DOMRect, r: DOMRect): void {
  el.style.left = pct(r.left - slideRect.left, slideRect.width)
  el.style.top = pct(r.top - slideRect.top, slideRect.height)
  el.style.width = pct(r.width, slideRect.width)
  el.style.height = pct(r.height, slideRect.height)
}

function div(cls: string, parent: HTMLElement): HTMLElement {
  const el = document.createElement('div')
  el.className = cls
  parent.append(el)
  return el
}
