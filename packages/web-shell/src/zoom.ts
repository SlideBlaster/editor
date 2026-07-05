/**
 * Zoom & pan for the deck scrollport. Contract: see zoom.md.
 *
 * Beamer/PDF-style navigation of the deck canvas (ux/canvas-zoom-pan.md):
 * Ctrl/Cmd + wheel and trackpad pinch zoom toward the cursor; middle-drag or
 * Space + drag pans; Ctrl +/-/0 step and reset. Zoom sets the `--zoom` custom
 * property on the scrollport; the CSS scales the slide width (and the deck's
 * gaps/padding) by it, so the slide grows past the viewport and the scrollport
 * pans over it. `--zoom` lives on the scrollport, so it survives deck rebuilds,
 * and the scaling is linear, which keeps the zoom-to-cursor math below exact.
 */
const MIN = 0.25
const MAX = 6
const STEP = 1.15

export interface ZoomController {
  zoomIn(): void
  zoomOut(): void
  reset(): void
  get(): number
}

export function enableZoomPan(
  scrollport: HTMLElement,
  opts: { onChange?: (zoom: number) => void } = {},
): ZoomController {
  let zoom = 1
  const clamp = (z: number): number => Math.min(MAX, Math.max(MIN, z))

  const emit = (): void => {
    scrollport.style.setProperty('--zoom', String(zoom))
    opts.onChange?.(zoom)
  }

  /** Zoom toward a viewport point, keeping the content under it fixed. */
  const zoomToPoint = (next: number, clientX: number, clientY: number): void => {
    const z1 = clamp(next)
    const f = z1 / zoom
    if (f === 1) return
    const rect = scrollport.getBoundingClientRect()
    const px = clientX - rect.left
    const py = clientY - rect.top
    const left = (scrollport.scrollLeft + px) * f - px
    const top = (scrollport.scrollTop + py) * f - py
    zoom = z1
    emit() // relayout at the new scale first...
    scrollport.scrollLeft = left // ...then anchor the cursor point.
    scrollport.scrollTop = top
  }

  /** Zoom toward the viewport centre (buttons / keyboard). */
  const zoomCentre = (next: number): void => {
    const rect = scrollport.getBoundingClientRect()
    zoomToPoint(next, rect.left + rect.width / 2, rect.top + rect.height / 2)
  }

  scrollport.addEventListener(
    'wheel',
    (event) => {
      if (!event.ctrlKey && !event.metaKey) return // plain wheel scrolls
      event.preventDefault() // also suppresses browser page-zoom / pinch-zoom
      zoomToPoint(zoom * (event.deltaY < 0 ? STEP : 1 / STEP), event.clientX, event.clientY)
    },
    { passive: false },
  )

  // Pan: middle-drag anywhere, or Space + left-drag. A capture-phase pointerdown
  // beats the slide overlay so a Space-drag pans instead of selecting.
  let spaceHeld = false
  let pan: { x: number; y: number; left: number; top: number } | null = null

  scrollport.addEventListener(
    'pointerdown',
    (event) => {
      const wantsPan = event.button === 1 || (event.button === 0 && spaceHeld)
      if (!wantsPan) return
      event.preventDefault()
      event.stopPropagation()
      pan = {
        x: event.clientX,
        y: event.clientY,
        left: scrollport.scrollLeft,
        top: scrollport.scrollTop,
      }
      scrollport.setPointerCapture(event.pointerId)
      scrollport.classList.add('is-panning')
    },
    true,
  )

  scrollport.addEventListener('pointermove', (event) => {
    if (!pan) return
    scrollport.scrollLeft = pan.left - (event.clientX - pan.x)
    scrollport.scrollTop = pan.top - (event.clientY - pan.y)
  })

  const endPan = (event: PointerEvent): void => {
    if (!pan) return
    pan = null
    scrollport.releasePointerCapture(event.pointerId)
    scrollport.classList.remove('is-panning')
  }
  scrollport.addEventListener('pointerup', endPan)
  scrollport.addEventListener('pointercancel', endPan)

  document.addEventListener('keydown', (event) => {
    if (document.activeElement instanceof HTMLTextAreaElement) return
    if (event.code === 'Space') {
      event.preventDefault() // hold to pan; don't page-scroll
      spaceHeld = true
      scrollport.classList.add('space-held')
      return
    }
    if (!(event.ctrlKey || event.metaKey)) return
    if (event.key === '=' || event.key === '+') {
      event.preventDefault()
      zoomCentre(zoom * STEP)
    } else if (event.key === '-') {
      event.preventDefault()
      zoomCentre(zoom / STEP)
    } else if (event.key === '0') {
      event.preventDefault()
      zoomCentre(1)
    }
  })
  document.addEventListener('keyup', (event) => {
    if (event.code !== 'Space') return
    spaceHeld = false
    scrollport.classList.remove('space-held')
  })

  emit()
  return {
    zoomIn: () => zoomCentre(zoom * STEP),
    zoomOut: () => zoomCentre(zoom / STEP),
    reset: () => zoomCentre(1),
    get: () => zoom,
  }
}
