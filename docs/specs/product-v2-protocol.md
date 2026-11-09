---
status: accepted
updated: 2026-07-29
---

# Source-authoritative Product/2 protocol

`slideblaster.product/2` is the active packaged-browser boundary. The closed
wire vocabulary/codec lives in `SlideBlaster.Protocol.ProductV2`; the portable
state machine lives in `SlideBlaster.Product.Runtime.ProductV2`. One Haskell
state owns exact source/history, deck analysis, active navigation, interaction,
selection, snapping, paint leases, verified edits, and New Slide policy.
JavaScript validates, forwards DOM facts, executes host actions, and paints; it
does not parse source/decks, mint semantic IDs, calculate revisions, or own
navigation/edit policy.

Which part of the canvas is visible is browser presentation state. Zoom and pan
are owned by the host viewport, are never protocol commands, and appear in no
request, action, or workspace field.

## Closed envelope

Every request is an exact-key object with
`"protocol":"slideblaster.product/2"`, `command`, and only that command's
fields. Authored bytes cross as bounded lowercase base16. Successes contain
exactly `protocol`, `ok:true`, `kind`, `actions`, and `workspace`; `actions` is
a closed array of host effects interpreted mechanically by JavaScript. Errors
contain exactly `protocol`, `ok:false`, `kind:"error"`, and source-redacted
`{code,message}`. Executable Haskell and JavaScript codec tests are authoritative
for nested action, render, and interaction shapes.

## Commands

| Command | Input beyond protocol/command | Meaning |
| --- | --- | --- |
| `open_source` | `sourceBase16` | Open/analyze exact provisional deck bytes and offer the first active audience paint. |
| `workspace_snapshot` | none | Return the current projection without mutation. |
| `acknowledge_paint` | exact paint fence | Grant authority only for the matching session/revision/ticket/surface. |
| `pointer_event` | closed raw pointer fact | Let Haskell own press/drag/preview/commit/cancel policy. Node targets include their painted surface. |
| `activate_node` | `surface`, `nodeId` | Surface-correlated keyboard activation; Haskell may return `focus_node`. |
| `select_slide` | stable `frame` identity | Haskell validates the projected frame, resets gesture/selection, switches active audience authority, and returns `slide_selected`. |
| `view_command` | `previous_slide` or `next_slide` | Haskell-owned slide traversal. Navigation changes no source revision/history. |
| `new_slide` | current `revision` | Insert one deterministic minimal slide after active and return `slide_created`. |
| `undo` / `redo` | current `revision` | Exact-byte history transition with coherent active-frame reconciliation. |
| `replace_source` | current `revision`, `sourceBase16` | Direct authorship; stale or invalid input cannot gain paint authority. |

There is no direct `move_node`, phase-specific drag, frame-selection-by-index,
browser-authored New Slide, or viewport request. Unknown and extra fields reject.

## Workspace and correlation

The workspace projects source revision/base16, readiness, authority, history,
selection, pointer/preview state, optional active offered/displayed render,
and a closed navigator:

- `activeIndex`, `activeFrame`, and `slideCount`;
- ordered `{frame,title,audience,notes}` items, where `audience` and `notes` are
  closed static Render plans (nullable when no ready plan exists);
- previous/next actions with Haskell-owned availability/reasons;
- New Slide availability with `source_not_ready` as its closed disabled reason.

The host may paint every item as a thumbnail and continuous audience/notes row,
but only the active acknowledged audience paint is interactive. `select_slide`
accepts stable identity rather than an index; Haskell validates membership,
resets selection/gesture state, chooses the correlated paint, and offers or
returns that active paint. JavaScript does not parse source or derive navigator
policy.

Node pointer targets, `activate_node`, and returned `focus_node` carry the exact
painted `{frame,kind}` surface. Haskell rejects events not matching the active
displayed audience surface (`surface_not_active`), preventing delayed events or
same-named nodes on another slide from crossing authority. Navigation clears
selection/gesture state and selects the correlated cached/offered paint for the
new active frame.

## Source and edit invariants

A drag commit uses the accepted parent revision and expected bytes, active paint
lease/surface, a format-owned child projection, exact parent-span lift, full
deck reparse, and intended destination verification before one App history
transition. Failure is atomic.

Product/2 resolves normal snapping first. If that resolved placement cannot enter
the active Deck inverse because it is relative or contains a non-terminating
exact decimal, Haskell retries the unchanged pointer destination as `FreeDrag`
and projects no guides. It never rounds the snapped coordinate, asks JavaScript
to choose a fallback, or bypasses the normal full reparse/intended-result
verification. If the exact pointer destination is itself unsupported, preview
still rejects atomically.

`new_slide` is likewise revision-fenced, chooses its collision-free ID and source
bytes only in Haskell, and records one history entry. Undo restores exact parent
bytes and the prior active frame; redo remains coherent when the recreated frame
exists.

Stable source-redacted deck errors include `deck_not_ready`,
`active_slide_missing`, `deck_projection_rejected`, and `surface_not_active`, in
addition to the existing malformed/unknown/stale/paint/history/analysis/render
and canvas rejection categories.

## Trial and compatibility

The active fixture and parent adapter are the explicitly provisional STR-007
`.slide` trial described in
[`str-007-implicit-canvas-slide-trial.md`](str-007-implicit-canvas-slide-trial.md).
This protocol behavior does not make that syntax permanent.

`SlideBlaster.Adapter.Web.ProductV2` serializes the pure runtime in one forced
`MVar`; the static Wasm export is `sb_product_v2_dispatch`.
`slideblaster.product/1` remains unchanged, frozen for compatibility, and
inactive in the packaged host. Its removal requires separate approval.
