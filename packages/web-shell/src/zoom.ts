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
const STEP = 1.15 // discrete step for buttons / keyboard
// Wheel/pinch zoom scales by the gesture magnitude (like a PDF viewer), not a fixed
// step: `factor = exp(-normalizedDelta * SENSITIVITY)`. Tuned so one mouse notch
// (~100px) ~= one STEP, while a fine trackpad pinch (small delta) nudges smoothly.
const WHEEL_SENSITIVITY = 0.0014
const LINE_PX = 16 // deltaMode=line -> px, so line-mode mice zoom at a sane rate
const MAX_WHEEL_FACTOR = 1.35 // clamp a single event so a huge delta can't lurch

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

  /** The scaled slide under a viewport point (fallback: the first slide). */
  const anchorAt = (clientX: number, clientY: number): HTMLElement | null => {
    const hit = document.elementFromPoint(clientX, clientY)
    return (
      hit?.closest<HTMLElement>('.deck-slide') ??
      scrollport.querySelector<HTMLElement>('.deck-slide')
    )
  }

  /**
   * Zoom toward a viewport point, keeping the content under it fixed. Rather than
   * predicting where the point lands (which assumes the scaled content grows from the
   * scroll origin — false here, since the deck centres slides and only gains scroll
   * range once a slide overflows), we MEASURE: record the cursor's fraction across the
   * slide it is over, apply the zoom, then re-read that slide's box and correct scroll
   * by the real pixel delta. Immune to the centring / overflow-flip that broke the
   * closed-form version.
   */
  const zoomToPoint = (next: number, clientX: number, clientY: number): void => {
    const z1 = clamp(next)
    if (z1 === zoom) return
    const anchor = anchorAt(clientX, clientY)
    if (anchor === null) {
      zoom = z1
      emit()
      return
    }
    const before = anchor.getBoundingClientRect()
    const relX = before.width > 0 ? (clientX - before.left) / before.width : 0
    const relY = before.height > 0 ? (clientY - before.top) / before.height : 0
    zoom = z1
    emit() // relayout at the new scale...
    const after = anchor.getBoundingClientRect() // ...then read where the point moved...
    scrollport.scrollLeft += after.left + relX * after.width - clientX // ...and pull it back.
    scrollport.scrollTop += after.top + relY * after.height - clientY
  }

  /** Zoom toward the viewport centre (buttons / keyboard). */
  const zoomCentre = (next: number): void => {
    const rect = scrollport.getBoundingClientRect()
    zoomToPoint(next, rect.left + rect.width / 2, rect.top + rect.height / 2)
  }

  scrollport.addEventListener(
    'wheel',
    (event) => {
      if (!event.ctrlKey && !event.metaKey) return // plain wheel scrolls / pans
      event.preventDefault() // also suppresses browser page-zoom / pinch-zoom
      // Normalize line/page deltas to px, then zoom by the gesture magnitude so fine
      // pinches are fine and a full notch is a full step.
      const px =
        event.deltaMode === 1
          ? event.deltaY * LINE_PX
          : event.deltaMode === 2
            ? event.deltaY * scrollport.clientHeight
            : event.deltaY
      const factor = Math.min(
        MAX_WHEEL_FACTOR,
        Math.max(1 / MAX_WHEEL_FACTOR, Math.exp(-px * WHEEL_SENSITIVITY)),
      )
      zoomToPoint(zoom * factor, event.clientX, event.clientY)
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
