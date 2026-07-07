# edit ops (ops.ts)

Node-granular edits as **pure transforms** `(picture, ...args) -> TikzPicture`. Each
returns a new picture and shares untouched statements; nothing mutates in place. This
matches the pure parse/serialize spine and keeps edits trivially testable against the
format invariants.

## Invariants each op upholds

- **Locality** — only the target statement's serialized text changes; siblings are
  the same objects, so they re-emit byte-for-byte.
- **Stable identity** — a node's `name` is its identity across an edit.
- **Round-trip** — `parse(serialize(op(picture)))` equals `op(picture)`; an edit
  never produces source the parser would read back differently.

## E1 — foundation (this file)

- `findNode(picture, name)` / `uniqueName(picture, base?)` — locate by identity;
  mint an unused `<base>N` name.
- `moveNodeTo(picture, name, at)` — absolute position. The **two-mode rule**: setting
  `at` strips any relative-placement option (`below=of ...`) so position has one
  owner. This is what a canvas drag calls. No-op if the node is absent.
- `createNode(picture, spec?)` — append a node (fresh name, empty content, no options
  by default); returns `{ picture, name }` so the caller can select it.
- `deleteNode(picture, name)` — remove the node and prune any path whose verbatim
  body references it (`(name)` or `(name.anchor)`), so no dangling connector remains.

## E2 — relative placement (this file)

The relative half of the two-mode rule (`moveNodeTo` is the absolute half). Placement
already _parses_ (`tikz/options.placement`) and _renders_ (`layout/resolve`); these ops
are the writer.

- `placeNodeRelative(picture, name, { side, gap, ref })` — bind a node
  `[<side>=<gap> of <ref>]`. Drops any absolute `at` and replaces any existing
  placement token in place (other options kept in order). **No-op** if the node or
  `ref` is missing, if `ref` is the node itself, or if the binding would form a
  placement **cycle** (`placementChainReaches` walks ref -> ref) — refusing keeps the
  relative chain acyclic, so the layout never has to pin a cycle to the origin.
- `adjustPlacement(picture, name, { side?, gap? })` — change an existing binding's gap
  and/or side, keeping its `ref`. This is what a canvas drag of a bound node calls:
  along the axis changes `gap`, across the axis flips `side`. No-op if the node is not
  relatively placed.
- **Detach** (relative -> absolute) is just `moveNodeTo(picture, name, resolvedCenter)`
  — it already strips the placement token. The shell passes the node's current resolved
  center from the layout, so the node stays put as it becomes absolute.

## E3 — content (this file)

- `setNodeContent(picture, name, content)` — replace a node's body content, leaving
  geometry and options untouched. No-op if the node is absent. The `content` is the
  parsed edited body, so an out-of-subset edit lands as `{ kind: 'error', source,
message }` and re-serializes verbatim (ADR 0015) — data-safe by construction. The
  shell seeds the raw editor with `serializeBody(content)` and re-parses on commit, so
  `setNodeContent(p, name, parseContent(serializeBody(c)))` round-trips.
- `setNodeStyleClass(picture, name, styleClass | null)` — set (or clear on `null`) the
  node's style class: drops every bare ROLE token and prepends the new one, so a node
  carries at most the picked class. Key=value options, placements, arrow shorthands, and
  bare style KNOBS (`draw`, `ellipse`, `thick`, `dashed`, … — `tikz/options.isStyleKnobToken`)
  are untouched, so restyling a shape keeps its outline/fill. No-op if the node is absent.
  This is the styles-dropdown op (a deliberate reclassify — distinct from region seeding,
  which stays creation-only per ADR 0017).
- `setNodeOptions(picture, name, options)` — replace a node's whole `options` array (E5:
  style editing), the node counterpart to `setConnectorOptions`. The style panel reads the
  node's tokens, rewrites the one changed knob with the `app` `nodeStyle` helpers (keeping
  role classes, placement, and size), and commits here. Geometry, content, and identity are
  untouched. No-op if the node is absent.
- `setNodeOverlay(picture, name, spec)` — set (raw spec string) or clear (`null`/blank)
  a node's whole-node `overlay=<spec>` reveal (ADR 0018), the properties-panel half of
  the two-level overlay model. Stored brace-wrapped (`overlay={1,3}`) so a spec's commas
  survive tikz option tokenizing; placement/size/content untouched. Read back by
  `tikz/options.nodeOverlay`. No-op if the node is absent.

## E4 — connectors (this file)

- `createConnector(picture, from, to, options?)` — append `\draw[opts] (from) -- (to);`
  between two nodes. Endpoints are node **names**, so the renderer resolves them to the
  nodes' current centers each paint and the connector **re-routes for free** as its
  nodes move. `options` default to `['->']`. No-op if either endpoint is absent.
- `deleteConnector(picture, index)` — remove the connector at `index`, the position
  among the picture's **path** statements. This is the identity the renderer stamps as
  `data-arrow` (see `render/slide.connectorsOf`), so the editor selects an arrow and
  deletes it by the same index. No-op if out of range.
- `updateConnector(picture, index, path)` — replace the connector's body with a reshaped
  `ConnectorPath` (endpoints, waypoints, per-segment curves; see
  [tikz/connector.md](../tikz/connector.md)). Options (arrowheads, dashing) are kept.
  No-op if out of range.

Editing an arrow's style (head direction, dashing) is E5 territory; not here yet.

## Not here

Undo/redo (callers keep history / re-derive from source). Options/style (E5).
Per-construct (sub-node) content splicing is a later refinement — E3 replaces
whole-node content. Document/frame targeting and re-serialization live in the shell,
not the ops.
