# Slide typography (slideType.ts)

The slide's proportional type, keyed on `.sb-slide`/`.sb-content` so it applies in every
context a slide is mounted: the deck canvas, navigator thumbnails, the offscreen
measuring slide ([domMeasurer.ts](./domMeasurer.md)), and the exported standalone/print
document ([export.ts](./export.md)).

- **Why one source.** If the measuring context and the display context disagreed on font
  size, every measured box would be wrong. So the same CSS is injected into all four
  contexts — drift is impossible by construction.
- **Why `cqw`.** Container-query width units make text a fixed fraction of the slide.
  `.sb-slide` is the `inline-size` container; 1 slide unit = 6.25cqw (16 units across). So
  the measurer can measure at any single reference width and the slide-unit result holds
  at every rendered size.
- **Theme owns the scale.** The type scale + per-role looks come from the **theme**
  (`themeStylesheet`, ADR 0017); `SLIDE_THEME_CSS` is that output for the active theme
  (the built-in default until the theme loader lands). `SLIDE_TYPE_CSS` keeps only the
  structural, non-theme rules: the `container-type` declaration, list indentation, and
  math italics. The engine's `slideStylesheet()` still owns slide _structure_ (the layered
  geometry/content positioning); `app.css` keeps only chrome.
