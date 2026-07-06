# theme furniture (deck-wide chrome)

Furniture — page number, logo, header/footer bands — is theme-defined **chrome** the
renderer draws on every slide (ADR 0017, layer 3). It is frame, not author content, so it
sidesteps absolute positioning (ADR 0002) and, being part of the render DOM (ADR 0014),
it prints (editor == export).

- `furnitureHtml(theme, {index, total}) -> string` — the `<div class="sb-furniture">`
  chrome layer for one slide, or `''` when nothing is shown. Sits inside `.sb-slide`.
  Page-number and band templates expand `{n}` (1-based index) and `{total}` (deck length).
  A logo is an `<img>` whose `src` is the theme's asset path (the app resolves it to a
  loadable URL). Everything is HTML-escaped.
- `furnitureCss(theme) -> string` — positions furniture by a **3x3 anchor grid**
  (`sb-fn-<anchor>`) against the theme's **safe-area** inset, plus full-width
  header/footer **bands** with left/center/right slots. Relative (percent), so placement
  holds across aspect ratios.

The theme sets furniture defaults; a deck's frontmatter overrides them (e.g. page numbers
off) — resolved before this renders. Injected alongside the style stylesheet across the
same mount contexts (display, export). Pure, deterministic strings — headless-testable.
