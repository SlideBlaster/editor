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

## E3 — content (this file)

- `setNodeContent(picture, name, content)` — replace a node's body content, leaving
  geometry and options untouched. No-op if the node is absent. The `content` is the
  parsed edited body, so an out-of-subset edit lands as `{ kind: 'error', source,
  message }` and re-serializes verbatim (ADR 0015) — data-safe by construction. The
  shell seeds the raw editor with `serializeBody(content)` and re-parses on commit, so
  `setNodeContent(p, name, parseContent(serializeBody(c)))` round-trips.

## Not here

Undo/redo (callers keep history / re-derive from source). Relative placement and
absolute<->relative conversion (E2), arrows (E4), options/style (E5). Per-construct
(sub-node) content splicing is a later refinement — E3 replaces whole-node content.
Document/frame targeting and re-serialization live in the shell, not the ops.
