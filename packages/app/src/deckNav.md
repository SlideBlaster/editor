# The deck navigator (deckNav.ts)

The secondary navigation beside the scrolling deck canvas ([deck.ts](./deck.md)): a
**vertical carousel** of slide thumbnails between the editor and the canvas, for jumping
directly to a slide (ux/deck-navigation.md). It is navigation plus a single edit
affordance — a "+ New slide" button at the bottom of the rail (`onAdd`).

- **Appearance.** A vertical rail (`.deck-rail`); the active thumbnail is centred and
  enlarged, neighbours recede. `setActive` re-centres it (`block: 'center'`). Two highlight
  tiers: `.is-current` is the **passive** active marker (always on, even when the rail is
  unfocused — it says "you are here"); `.deck-rail:focus-within .thumb.is-current` adds the
  **directly selected** ring, on only while the rail holds focus (the state that arms
  ArrowUp/Down and Delete — see below).
- Thumbnails are the same `renderSlide` output as the canvas (math and tables included via
  the shared `renderOptions`), scaled down by `.thumb` CSS; they use the cheap sync naive
  layout since they are static (the editable canvas uses the DOM measurer).

Sync is two-way and lives in the controller:

- **Select -> highlight now, then scroll.** A thumbnail click (or ArrowUp/Down while the
  rail is focused) fires `onSelect(index)`; the controller's `selectSlide` sets the active
  slide **immediately** (highlight + step control) and _then_ best-effort re-centres the
  canvas (`deckHandle.scrollToSlide`). Decoupling the highlight from the scroll is
  deliberate: selecting a slide already in view (e.g. the 2nd of two slides, where the
  scroll can't move) still updates the highlight, because it no longer waits for a scroll
  event that would never arrive.
- **Scroll -> highlight.** As the canvas scrolls, the deck's active-slide report reaches
  the controller (`onActiveChange` -> `setActiveSlide`), which calls `navHandle.setActive`.
  No re-render — just class toggles and a centre-scroll.
- **Keyboard + focus (direct selection).** Thumbnails are `<button>`s, so the rail is
  keyboard-reachable. A click focuses the thumb explicitly (buttons are not focused on
  click in every browser); a single per-host `keydown` handler (swapped each rebuild via a
  `WeakMap`, like deck.ts's observer) maps ArrowDown/ArrowUp to `onSelect(next)` with
  clamping. While a thumb holds focus the rail is "directly selected": `setActive` keeps
  focus on the active thumb (guarded by focus-in-rail, so a canvas scroll never pulls focus
  here), and the controller lets Delete remove the active slide. `focusActive` (a NavProp)
  re-focuses the active thumb after a rebuild the rail itself caused (deleting a slide), so
  consecutive Deletes work; a canvas-driven rebuild passes false and leaves focus alone.
- **Add -> new slide.** A "+ New slide" button (`.deck-add`) sits below the last
  thumbnail. Clicking it fires `onAdd()`; the controller appends a blank frame
  (`addSlide`, undoable). Omit `onAdd` to hide the button. It is the carousel twin of the
  top-bar `#new-slide` button — one action, two triggers. The button is not a thumbnail, so
  it never takes the `is-current` highlight or the active-scroll.

The earlier filmstrip style (a flat horizontal rail below the canvas) was removed —
the carousel is the single navigator (see ux/deck-navigation.md).
