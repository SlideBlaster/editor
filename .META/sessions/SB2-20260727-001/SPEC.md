# SB2-20260727-001 specification

## User-visible capability

From `make dev`, the product owner opens `http://127.0.0.1:4173/`, where the
packaged Product/2 browser automatically loads the provisional
`hosts/web/fixtures/demo.slide`. The identical 3,115 bytes are tracked at
`packages/slideblaster-deck/test/fixtures/demo.slide`,
`packages/slideblaster-product-runtime/test/fixtures/demo.slide`, and
`temp/demo.slide`; all four have SHA-256
`d9d15951e4331345cb68c51dbecd3a15f3ac935190fd27c150019bc682428fd1`.
The editor opens stable frames `opening`, `questions`, and `finish`, shows one
Haskell-projected vertical thumbnail and continuous audience/notes row per
frame, selects thumbnails through Haskell, and provides both compact `+ Slide`
and rail `+ New slide` affordances for the same command. A writable
direct-coordinate node retains its recognized authored anchor while being dragged
through the existing bounded TikZ analysis; only its verified child coordinate bytes are lifted into the exact parent body. Normal
snap is attempted first; an unprojectable relative or non-terminating snap is
retried by Haskell at the unchanged pointer destination as guide-free FreeDrag,
without rounding. New Slide inserts one deterministic empty frame after the
active frame, and exact Undo/Redo remain coherent.

This is the accepted STR-007 **provisional implicit-canvas trial**. It does not
select a permanent file extension, grammar, or migration for authored decks.

## Contracts and invariants

Authored parent bytes and revision are sole persistence authority. The portable
Deck CST preserves all bytes and half-open spans for the deck header, repeated
slide headers/metadata/raw bodies, and immediately associated optional notes.
Malformed parent structure, duplicate frame IDs, ambiguous admitted child
identity, or a child boundary that cannot be analyzed safely makes the whole
document syntax-only without changing source.

Every audience body is sliced at the parent revision and analyzed as one
implicit bounded TikZ document. Repeated direct-position nodes and admitted
straight paths are projected; mixed node payload, unsupported options/content,
complex paths, metadata, notes, delimiters, and unrelated slides remain exact.
Unsupported inverse rules are read-only.

One Haskell `AppModel` owns exact history and paint leases. Product/2 owns the
active frame/index, previous/next availability, selection/gesture reset, active
surface correlation, snapping/zoom, New Slide policy, and undo/redo frame
preference. JavaScript validates closed projections, forwards raw DOM facts and
the current New Slide revision, executes returned actions, and paints. It does
not parse decks, mint IDs, calculate revisions, choose insertion text, or own
navigation/source semantics.

A canvas edit captures the exact accepted parent document, active audience
surface, source revision, displayed paint fence, and semantic operation. The
Deck adapter re-slices that child, invokes the bounded TikZ inverse, applies one
expected-text replacement over the exact body span, fully reparses the parent
and active child, and verifies the intended semantic destination and unchanged
non-target structure before App records one history transition. Any failed
check is atomic.

## Included and excluded scope

Included parent syntax is the tracked STR-007 spelling: one `deck` header with
optional quoted title and opaque balanced metadata; one or more
`slide ID "title" (metadata) """body"""` records; and an optional immediately
associated `note """body"""`. Titles and identifiers are validated; metadata
interiors remain opaque. Literal triple-quote body content has no supported
escape convention in P0 and is syntax-only/read-only rather than rewritten.

Included child syntax is the bounded implicit canvas needed by the demo: empty
or repeated nodes, exact nested mixed payloads, direct writable centre
placements, and resolvable simple straight paths. Unsupported properties,
anchored inverses, expanded/relative constructs, and complex paths remain exact
source barriers. Included operations are exact open, all-slide static
audience/notes projection, stable-frame thumbnail/arrow navigation, active
paint acknowledgement, selection, lease-fenced drag preview/commit, source
replacement, snapping/zoom, deterministic New Slide, exact undo/redo, no-op,
and atomic stale/unsupported rejection.

Excluded are permanent-format adoption or legacy conversion; notes canvas
editing (notes are static projected sidecars); arbitrary TikZ expansion;
structured mixed-content painting
and exact font measurement; slide deletion/reorder; whole-document formatting;
creation catalogs beyond New Slide; persistence/Git, collaboration,
presenter/export, and Product/1 removal.

## Failure and stale-state behaviour

Stale parent revisions, expected bytes, paint fences, surfaces, pointer samples,
or history requests fail closed. Duplicate slide IDs, malformed parent syntax,
duplicate child node IDs in one audience body, unresolved admitted connector
targets, unsupported placement inverses, failed child projection, failed full
parent reparse, and intended-semantic mismatch cannot enter source or history.
Navigation clears selection/gesture state and changes no source revision. A
syntax-only document may retain last-good paint only inertly. A no-op emits no
patch, revision, or history entry. New Slide failure adds no history and does
not change active frame; stale dispatch returns the original state.

## Delivery artifacts

| Artifact | Kind | Location/access | Purpose |
| --- | --- | --- | --- |
| Packaged editor | runnable | `make dev`; `http://127.0.0.1:4173/` | Real GHC-Wasm Product/2 STR-007 proof |
| Exact demo | tracked source | `hosts/web/fixtures/demo.slide` | Browser demonstration input |
| Demo oracle copies | tracked test data | `packages/slideblaster-deck/test/fixtures/demo.slide`; `packages/slideblaster-product-runtime/test/fixtures/demo.slide`; `temp/demo.slide` | Identical parser, runtime, and local trial fixtures |
| Shared implementation | Haskell packages | Deck, TikZ, Engine, App, Product runtime, Protocol | Portable lossless parent and source-authoritative runtime |
| Browser composition | Wasm app and `hosts/web` | Product/2 validator/renderer/event adapter | Thin host over real reactor |
| Contracts/evidence | session/docs/tests/research | this specification and linked records | Reproducible laws and review evidence |

Artifact revision remains `pending` until an authorized commit/integration
creates an exact revision. The current review unit is the complete local
worktree diff against registration baseline
`cbe29eb4f989f830b17157812e2c8180dbb690e0`, not an artifact revision or an
acceptance claim.

## Product-owner demonstration

From the governed worktree or a later clean checkout of the authorized artifact:

1. Run `make dev` and open `http://127.0.0.1:4173/`.
2. Confirm the default-visible source, three vertical thumbnails, and three
   continuous audience cards with notes sidecars are present, with `opening`
   active and no horizontal page overflow.
3. Click the `questions` thumbnail, then use ArrowUp/ArrowDown while the rail has
   focus. Confirm Haskell changes the active outline/card without changing source
   revision or history and resets selection/gesture state.
4. Return to `opening` and drag the unselected `source` node through several
   ordinary no-modifier intermediate points to `(12,6)`. Confirm capture and the
   preview survive each point, then release for exactly one verified parent
   revision. Click Undo and confirm exact parent restoration. Separately hold Alt
   for a free drag and confirm it has no guides.
5. Select `questions`, click rail `+ New slide` (or top `+ Slide`), and confirm
   one new `slide-4` titled `Untitled` appears immediately after it, becomes
   active, and advances the revision exactly once.
6. Click Undo, Redo, and Undo. Confirm the exact generated bytes/frame return on
   Redo and all 3,115 original bytes plus active `questions` return on Undo.
7. Edit source and leave the editor or press Ctrl+Enter. Confirm Haskell admits
   it and that an older in-flight response cannot overwrite a newer dirty draft.

The automated Chrome smoke performs the all-slide workspace checks, Haskell
thumbnail selection, natural no-Alt and explicit Alt drags, exact drag and New
Slide undo/redo, dirty-draft race, responsive no-overflow, stale rejection, and
page/console-error checks. The focused native runtime additionally proves the
real-demo inverse fallback plus New Slide stale-state preservation and exact
Undo/Redo frame reconciliation.

## Acceptance evidence

The STR-007 implementation review records the focused Deck, TikZ, Engine, App,
Protocol, and Product/2 runtime suites as passing. The host suite passes its closed-schema, all-slide projection,
policy-leakage, and visible accessible New Slide laws; Wasm packaging succeeds;
and real Chrome passes three vertical thumbnails and continuous audience/notes
rows, Haskell thumbnail selection, five natural no-Alt intermediate moves from
an unselected node with capture retained, a separate explicit Alt/free drag,
exact drag and New Slide undo/redo, a dirty-draft race, absent diagnostic chrome,
vertical navigation with non-collapsed 16:9 geometry-matching thumbnails at
1440/820/560/390 CSS-pixel widths, no page overflow, stale rejection, and zero
page/console errors. The focused native runtime additionally uses the packaged real demo to
prove unprojectable relative/non-terminating snaps fall back without cancelling
the gesture, return no guides, and release as one verified parent revision. `git diff --check`, session validation, and the
four matching fixture hashes are additional review gates.

The repository-wide native matrix still has the pre-existing unrelated catalog
fixture failure on `sports.camper-1`; it must not be reported as wholly green.
Product-owner observation of this STR-007 artifact, specification acceptance,
change review, integration authorization, integration, and closure remain
separate pending gates in `REVIEW.md`.

## STR-007 implementation design

The implemented root is one long-lived `AppModel DeckSyntax DeckFieldKey`.
`SourceHistory` owns exact parent bytes and revisions; the accepted generic
`DocumentSnapshot` owns source-locked multi-frame Presentation semantics and
lifted provenance. App paint requests and leases fence each surface by session,
revision, ticket, and surface. `SlideBlaster.App.Navigation` owns ordered frame
identity and active-frame reconciliation.

`SlideBlaster.Deck` owns lossless parent parsing, active body slicing,
child-to-parent verified edit lifting, and deterministic insertion.
`SlideBlaster.TikZ.Adapter` maps only admitted child syntax to the common model
and applies common absolute-centre moves through the private verified inverse.
`SlideBlaster.Engine.CommonTikz` produces empty or multi-node/multi-path bounded
resource-free plans. `SlideBlaster.Product.Runtime.ProductV2` owns the closed
state machine and active paint map; `SlideBlaster.Protocol.ProductV2` owns the
closed wire vocabulary. The Wasm adapter serializes runtime access in one real
`MVar`, and the packaged host mounts only the Product/2 validator, policy, and
renderer.

### Protocol and format gates

The product owner delegated the protocol choice on 2026-07-27. The accepted
boundary is `slideblaster.product/2`, freezing Product/1 for compatibility and
deferring removal to a later separately approved migration. Additive Product/1
was rejected because it would mix source authorities; a separate
`slideblaster.app/1` was rejected because it would split product state across
protocols.

STR-007 accepts only this bounded `.slide` experiment. It neither supersedes the
legacy design authority for the eventual authored format nor authorizes a
migration. Promotion, syntax changes, and any permanent extension remain
product-owner gates.

## Viewport and carousel follow-up — 2026-07-29

The local review artifact at `http://127.0.0.1:4180/` now matches the inspected
legacy viewport contract: Haskell owns the `0.25x–6x` range, `1.15` discrete
step, wheel magnitude normalization/factor, Fit calculation, pan eligibility,
pointer identity/phase, and scroll deltas. JavaScript forwards raw browser facts
and measurements, performs pointer capture/scrolling, and validates and executes
closed returned actions. Ctrl/Cmd+wheel or pinch preserves the pointer focal
point; buttons and Ctrl/Cmd `+/-` use the viewport centre; percentage click and
Ctrl/Cmd+0 reset; Fit uses the legacy `0.98` width margin; middle drag and
Space+primary drag pan without changing source/history. The vertical rail keeps
an accessible sticky-bottom `+ New slide` action governed by Haskell availability.

Verification from the governed worktree passed the App, Product/2 protocol, and
Product runtime suites (17 runtime laws), all 25 host tests, Wasm packaging,
`git diff --check`, and session validation. Real Google Chrome against the exact
no-store port 4180 passed cursor-centred zoom, Fit, middle and Space pan, exact
headline drag/history/New Slide, responsive widths, and zero page/console
errors. Product-owner observation and acceptance remain pending; no artifact
revision, commit, integration, release, deployment, or closure is claimed.

## Wheel transport performance follow-up — 2026-07-29

Raw Ctrl/Meta wheel delivery is mechanically backpressured to one unresolved
Product/2 dispatch plus the latest pending browser sample. Superseded samples
are discarded only at the transport boundary; delivered samples remain exact
raw facts. Haskell continues to own delta-mode normalization, sensitivity,
per-event factor clamping, zoom bounds, focal policy, and source-neutral effects.
This prevents high-frequency input from accumulating a multi-second serialized
Wasm/response/layout backlog while preserving the thin-adapter contract.

Two deterministic host tests cover one-in-flight/latest-pending behavior and
rejected-dispatch recovery. Real Chrome holds the first dispatch, emits 40 wheel
samples, and requires exactly two viewport dispatches, settlement under two
seconds, unchanged source revision, and successful completion of all existing
viewport and source-authority acceptance checks.

## Local viewport ownership — 2026-07-29

Superseding the Haskell-owned viewport contract above, the visible region of the
canvas is browser presentation state.

- `hosts/web/src/ui/viewport.js` owns zoom, pan offsets, bounds `1/4`-`6`, step
  `23/20`, fit margin `49/50`, wheel unit conversion, and the clamped
  exponential per-sample wheel factor.
- Every gesture updates numbers and writes one composited transform on
  `.deck-canvas` with `transform-origin: 0 0`. No dispatch, promise, or await
  participates in a visible movement.
- Slide layout stays at unit scale. Zoom must not resize slides, reflow the
  deck, or invalidate a rendered surface, and `--product-zoom` must not exist.
- Element bounding rectangles remain the only pointer coordinate authority, so
  node dragging stays exact at any zoom or pan.
- Haskell retains source bytes, revisions, history, selection, slide navigation,
  render plans, node geometry, and verified movement. The viewport module has no
  access to the protocol, the workspace, or revisions.
- `viewport_event` must not appear in any browser trace.

## Reduced Product/2 surface — 2026-07-29

With the local viewport accepted, the boundary carries no viewport vocabulary.

- `SlideBlaster.App.Interaction` exports pointer gesture policy, the navigator
  projection, and command availability only. It has no zoom or pan state, no
  zoom bounds or wheel policy, and no viewport effects.
- `viewport_event` is not a command. `view_command` accepts only
  `previous_slide` and `next_slide`.
- The workspace projects no `zoom` or `viewport` object, and the closed action
  set is `capture_pointer`, `release_pointer`, `repaint`, `show_preview`,
  `clear_preview`, and `focus_node`.
- The browser decoder rejects any removed field, action kind, response kind, or
  view command, and the browser never constructs a viewport request.
