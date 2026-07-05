# connector model (connector.ts)

The editable structure behind a `\draw` connector. Path bodies are verbatim in the model
(tikz.ts); this parses the **editable subset** into a `ConnectorPath` the canvas can
reshape, and serializes it back. Everything else stays verbatim and non-editable.

- **Shape.** `ConnectorPath = { anchors: Anchor[], curves: (CurveControls | null)[] }`.
  `anchors` (>= 2) are node refs (`{ kind:'node', name }`, optionally with a border
  `anchor` — `north`, `south east`, … — for TikZ `(name.north)`) or coordinates
  (`{ kind:'point', at }`). `curves[i]` is the segment from `anchors[i]` to
  `anchors[i+1]`: `null` for a straight `--`, or `{ c1, c2 }` for a cubic Bézier
  (`.. controls (c1) and (c2) ..`). `curves.length === anchors.length - 1`.
- **`parseConnector(body) -> ConnectorPath | null`.** Recognizes anchors joined by `--`
  or `.. controls (p) and (p) ..`; a node anchor may carry a border port after a dot
  (`(box.north east)`). Returns `null` for anything outside that grammar
  (orthogonal `-|`/`|-`, `to[...]`, `circle`, a lone anchor with no segment) — the caller
  then keeps the body verbatim and renders it straight, non-editable.
- **`serializeConnector(path) -> string`.** The inverse, emitting a body with the
  leading-space convention (`\draw` + options + body). Round-trips: `serialize(parse(b))`
  equals the canonical form of `b`.
- **Control points are absolute** slide coordinates, exactly as TikZ writes them — the
  full-control curve surface. They do not track an endpoint that later moves; the editor
  owns them.

Used by `render/slide.connectorsOf` (to resolve + draw, incl. curves as an SVG `path`)
and by `edit/ops.updateConnector` (to write a reshaped connector back to source).
