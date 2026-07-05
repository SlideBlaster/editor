# Slide typography (slideType.ts)

`SLIDE_TYPE_CSS` — the slide's proportional type scale, keyed on `.sb-slide` so it
applies in every context a slide is mounted: the deck canvas, navigator thumbnails,
the offscreen measuring slide ([domMeasurer.ts](./domMeasurer.md)), and the exported
standalone/print document ([export.ts](./export.md)).

- **Why one source.** If the measuring context and the display context disagreed on
  font size, every measured box would be wrong. Centralizing the type here — instead
  of duplicating it per surface in `app.css` — makes drift impossible by construction.
- **Why `cqw`.** Container-query width units make text a fixed fraction of the slide.
  `.sb-slide` is the `inline-size` container; 1 slide unit = 6.25cqw (16 units across).
  So the measurer can measure at any single reference width and the slide-unit result
  holds at every rendered size.
- **Split of duties.** The engine's `slideStylesheet()` owns slide *structure* (the
  layered geometry/content positioning); this owns the *type scale*. `app.css` keeps
  only chrome (the card border/shadow around `.deck-slide .sb-slide`, thumbnail frames).
