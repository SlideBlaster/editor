# Zoom & pan (zoom.ts)

Beamer/PDF-style zoom and pan for the deck scrollport (`#deck`), per
ux/canvas-zoom-pan.md. `enableZoomPan(scrollport, { onChange })` wires the input
and returns `{ zoomIn, zoomOut, reset, fitWidth, get }` for a UI control.

- **Applied by scaling width.** Zoom sets the `--zoom` custom property on the
  scrollport; the CSS scales the slide width by it (`width: calc(min(100%, 62rem)
  - var(--zoom))`) and the deck's gaps/padding-block to match. The slide grows
past the viewport, so the scrollport gains real scroll range to pan. (An earlier
attempt with the CSS `zoom`property capped the slide at the viewport once its
percentage width fought the zoom — width-scaling grows monotonically.)`--zoom`lives on the scrollport, so it **survives deck rebuilds** (an edit replaces the
canvas, not`#deck`).
- **Zoom-to-cursor is measured, not predicted.** The deck centres slides and only
  gains scroll range once a slide overflows, so there is no fixed origin to scale
  from — a closed-form `(scroll + cursor) * factor - cursor` drifts the point to the
  corner. Instead we record the cursor's fraction across the slide under it, apply the
  zoom, re-read that slide's box, and correct scroll by the real pixel delta. Robust to
  the centring and the overflow-flip. The anchor slide comes from `elementFromPoint`
  (fallback: the first slide).
- **Drag math is unaffected.** `canvas.ts` measures with `getBoundingClientRect`,
  which returns the scaled slide rect, so `move`/`create` land correctly at any
  zoom, and the live-drag preview translates in plain pixels (no transform/zoom
  context to compensate for).
- **Inputs.** Ctrl/Cmd + wheel and trackpad pinch (browsers deliver pinch as a
  ctrl-wheel) zoom to the cursor **by the gesture magnitude** — `factor =
exp(-delta * SENSITIVITY)`, with line/page deltas normalized to px and a per-event
  clamp — so a fine pinch nudges and a full notch is a full step (a fixed step felt
  chunky). `Ctrl +/-/0` and the floating control use the discrete `STEP`.
- **Immediate scroll.** The deck has no CSS `scroll-behavior: smooth`; wheel, pan, and
  the scroll corrections written during zoom must track input 1:1 or fine navigation
  feels floaty. Only explicit thumbnail jumps pass `behavior:'smooth'`.
- **Pan.** Middle-drag, or Space + drag. A **capture-phase** `pointerdown` on the
  scrollport claims the gesture (`stopPropagation`) so a Space-drag pans instead
  of the overlay treating it as select/create. Space is guarded off while typing
  in the code pane.

- **Fit width.** `fitWidth()` (the Fit button) scales a slide to the scrollport width.
  Zoom is linear in `--zoom`, so the target is the current zoom times the measured
  width ratio (with a hair of margin).

Range 0.25x–6x. Open: touch pinch, persisting zoom across reloads.
