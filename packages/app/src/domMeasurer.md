# DOM measurer (domMeasurer.ts)

The browser adapter for the engine's `BatchMeasurer` seam — the Track-0 "async
measurement" spike made real. Replaces `naiveMeasurer`'s character estimate with the
node's _actual_ rendered box, so layout matches what you see.

`createDomMeasurer()` returns a `BatchMeasurer` plus `dispose()`.

- **Measure offscreen at a reference width.** A hidden `.sb-slide` at `REF_PX` (1600px
  ⇒ 100px per slide unit) holds the nodes. Because the slide type is `cqw`-proportional
  ([slideType.ts](./slideType.md)), the slide-unit result is width-invariant, so one
  reference width is correct at every rendered size. Each node renders via the engine's
  `renderContent` (identical HTML to the real slide) and its `getBoundingClientRect` is
  divided by `PER_UNIT`.
- **Natural vs fixed width.** No `text width` ⇒ `width: max-content` (the node's widest
  line). `text width=n` ⇒ width fixed to `n` units and the height is read after wrap —
  mirroring how the display slide sizes the box.
- **Async + batched.** `measureAll` awaits `document.fonts.ready` once before trusting a
  box (math typesetting will hook in the same way later), inserts a slide's nodes
  together, forces one reflow, and reads them in a single pass.
- **Cached by content.** Key = `[content, styleClasses, textWidth]`. Re-rendering the
  whole deck on each keystroke only measures nodes that actually changed; repeats within
  a batch are de-duplicated. A `.sb-measure-root` stylesheet supplies only structural
  overrides (offscreen, height:auto, static flow) — never font metrics, so measurement
  can't diverge from display.
- **Floors.** Empty/whitespace nodes still get a min box (1 × 0.6 units) so their handle
  stays grabbable, matching the naive measurer's behaviour.

Consumed by [deck.ts](./deck.md) through `resolveLayoutAsync`; the naive measurer stays
the synchronous fallback if the DOM path ever throws.
