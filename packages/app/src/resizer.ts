/**
 * Draggable pane resizers for the workspace chrome. Contract: see resizer.md.
 *
 * The workspace is a CSS grid whose file-tree and editor tracks size to custom
 * properties; the slide canvas is the flexible `1fr` track. Each gutter is a thin
 * drag handle between two panes: dragging it sets the width property of the pane on
 * its left, so the canvas absorbs the difference and grows/shrinks to match. Widths
 * are clamped so no pane (nor the canvas) collapses, remembered in localStorage, and
 * reset to the CSS default on double-click. Keyboard: focus a gutter, nudge with the
 * left/right arrow keys.
 */

const NUDGE = 16 // px per arrow-key press
const MIN_PREVIEW = 240 // px the slide canvas must keep, capping how wide a pane may grow

interface ResizeTarget {
  gutter: HTMLElement
  pane: HTMLElement
  prop: string // the CSS custom property carrying the pane width (set on .workspace)
  min: number // px floor for this pane
  key: string // localStorage key
}

/** Wire the workspace gutters so the file tree, editor, and slide canvas are draggable. */
export function enableResizers(root: HTMLElement): void {
  const workspace = root.querySelector<HTMLElement>('.workspace')
  if (!workspace) return
  const preview = root.querySelector<HTMLElement>('.preview')

  const targets: ResizeTarget[] = []
  const wire = (
    gutterId: string,
    paneSel: string,
    prop: string,
    min: number,
    key: string,
  ): void => {
    const gutter = root.querySelector<HTMLElement>(gutterId)
    const pane = root.querySelector<HTMLElement>(paneSel)
    if (gutter && pane) targets.push({ gutter, pane, prop, min, key })
  }
  wire('#side-resizer', '.side-panel', '--sb-side-w', 140, 'sb.width.side')
  wire('#editor-resizer', '.editor', '--sb-editor-w', 260, 'sb.width.editor')

  // Widest a pane may grow: enough that the canvas keeps MIN_PREVIEW. Measured live so
  // it accounts for whatever else is on the row (the rail, the other pane, the gutters).
  // Falls back to a fraction of the workspace when the preview isn't laid out yet.
  const maxFor = (t: ResizeTarget): number => {
    const paneW = t.pane.getBoundingClientRect().width
    const previewW = preview ? preview.getBoundingClientRect().width : 0
    const bound = previewW > 0 ? paneW + previewW - MIN_PREVIEW : workspace.clientWidth * 0.6
    return Math.max(t.min, bound)
  }

  const clampAndSet = (t: ResizeTarget, width: number): void => {
    const w = Math.round(Math.min(maxFor(t), Math.max(t.min, width)))
    workspace.style.setProperty(t.prop, `${w}px`)
    try {
      localStorage.setItem(t.key, String(w))
    } catch {
      /* private mode / quota: the layout still works, it just isn't remembered */
    }
  }

  // Restore remembered widths (best-effort; re-clamped in case the viewport changed).
  for (const t of targets) {
    try {
      const saved = localStorage.getItem(t.key)
      if (saved) clampAndSet(t, Number(saved))
    } catch {
      /* localStorage unavailable: keep the CSS defaults */
    }
  }

  for (const t of targets) {
    let startX = 0
    let startW = 0

    const onMove = (event: PointerEvent): void => {
      clampAndSet(t, startW + (event.clientX - startX))
    }
    const onUp = (event: PointerEvent): void => {
      t.gutter.releasePointerCapture(event.pointerId)
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onUp)
      t.gutter.classList.remove('is-dragging')
    }

    t.gutter.addEventListener('pointerdown', (event) => {
      if (event.button !== 0) return
      event.preventDefault()
      startX = event.clientX
      startW = t.pane.getBoundingClientRect().width
      t.gutter.setPointerCapture(event.pointerId)
      t.gutter.classList.add('is-dragging')
      window.addEventListener('pointermove', onMove)
      window.addEventListener('pointerup', onUp)
    })

    // Double-click restores the default: drop the override so the CSS width wins again.
    t.gutter.addEventListener('dblclick', () => {
      workspace.style.removeProperty(t.prop)
      try {
        localStorage.removeItem(t.key)
      } catch {
        /* ignore */
      }
    })

    // Keyboard: nudge the boundary with the arrow keys (the gutter is focusable).
    t.gutter.addEventListener('keydown', (event) => {
      const dir = event.key === 'ArrowLeft' ? -1 : event.key === 'ArrowRight' ? 1 : 0
      if (dir === 0) return
      event.preventDefault()
      clampAndSet(t, t.pane.getBoundingClientRect().width + dir * NUDGE)
    })
  }
}
