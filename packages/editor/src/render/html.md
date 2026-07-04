# render html (content layer)

`renderContent(content, options?) -> string`: the HTML content layer of the layered
DOM (ADR 0014). Pure string output, so it is headless and snapshot-testable.

Each run renders to its **semantic** element, so the three dialects collapse to one
output: `\textbf{x}` / `**x**` / `<b>x</b>` all become `<strong>x</strong>` (bold ->
`strong`, italic -> `em`, underline -> `u`, strike -> `s`). Structural HTML wraps
(`div`/`span`) keep their tag. Lists -> `<ul>`/`<ol>`; columns -> a flex row; matrix
-> `<table>`; image -> `<img>`.

- **Math** goes through a seam: `options.renderMath(source, display)`. The default is
  a marked placeholder (`<span class="sb-math" data-mode=…>source</span>`); a KaTeX
  adapter drops in behind it at shell integration, like the layout Measurer.
- **Port-gated payloads are labelled, never dropped:** `deferred` (table) renders
  "table &mdash; render pending" (Compile port); `include` shows `[include: path]`
  (Storage port); a `fragment` is an empty marker span (reveal is a presentation
  concern).
- All text and attributes are HTML-escaped.

Contract: pure, deterministic, injection-safe (escaped). Geometry/positioning is not
here — a placed node's box comes from `../layout`, and B3 stacks this content over
the SVG geometry layer.
