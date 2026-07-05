# Zoom & pan (zoom.ts)

Beamer/PDF-style zoom and pan for the deck scrollport (`#deck`), per
ux/canvas-zoom-pan.md. `enableZoomPan(scrollport, { onChange })` wires the input
and returns `{ zoomIn, zoomOut, reset, get }` for a UI control.

- **Applied by scaling width.** Zoom sets the `--zoom` custom property on the
  scrollport; the CSS scales the slide width by it (`width: calc(min(100%, 62rem)
  * var(--zoom))`) and the deck's gaps/padding-block to match. The slide grows
  past the viewport, so the scrollport gains real scroll range to pan. (An earlier
  attempt with the CSS `zoom` property capped the slide at the viewport once its
  percentage width fought the zoom — width-scaling grows monotonically.) `--zoom`
  lives on the scrollport, so it **survives deck rebuilds** (an edit replaces the
  canvas, not `#deck`).
- **Zoom-to-cursor is exact.** Because every extent scales linearly in `--zoom`,
  the content point under the cursor is held by `newScroll = (scroll + cursor) *
  factor - cursor`. Apply the scale first (relayout), then set scroll.
- **Drag math is unaffected.** `canvas.ts` measures with `getBoundingClientRect`,
  which returns the scaled slide rect, so `move`/`create` land correctly at any
  zoom, and the live-drag preview translates in plain pixels (no transform/zoom
  context to compensate for).
- **Inputs.** Ctrl/Cmd + wheel and trackpad pinch (browsers deliver pinch as a
  ctrl-wheel) zoom to the cursor; `Ctrl +/-/0` zoom to centre / reset; the
  floating zoom control calls `zoomIn/zoomOut/reset`.
- **Pan.** Middle-drag, or Space + drag. A **capture-phase** `pointerdown` on the
  scrollport claims the gesture (`stopPropagation`) so a Space-drag pans instead
  of the overlay treating it as select/create. Space is guarded off while typing
  in the code pane.

Range 0.25x–6x. Open: fit-to-width presets, touch pinch, persisting zoom.
