# Research artifact: current-editable-canvas

- Slug: `SB2-20260727-001--current-editable-canvas--architecture-analyst--01`
- Session: `SB2-20260727-001`
- Agent: `architecture-analyst`
- Created: `2026-07-27`
- Status: `complete`

## Question

Where are exact source, common canvas/app/render, protocols, Wasm, and browser authority currently implemented, and what is the thinnest safe composition seam without a third model?

## Source and provenance

Read-only inspection at registration revision `cbe29eb4f989f830b17157812e2c8180dbb690e0`. Primary evidence: `PROJECT.md`; accepted architecture/spec/ADR files; package manifests; Source, Document, TikZ, Engine, Canvas, Render, App, Protocol, web-adapter, reactor, and host source/tests. Exact principal paths are indexed below.

## Reproduction

Trace definitions and callers for `SourceBufferSnapshot`, `ExactReplacement`, generic `DocumentSnapshot`, `MoveNode`, common `EditIntent`, `SourceHistory`, `DocumentSession`, paint leases, `LiveAuthoring`, both protocol values, reactor exports, and both browser renderers. Compare exact JSON encoders with host validators. Search the repository for host tests.

## Observations

### Two real but incomplete paths

1. `slideblaster.engine/1`, mounted by `hosts/web/src/main.js`, is source-authoritative and already proves exact bytes/revisions, recoverable bounded TikZ analysis, typed move, provenance/expected-byte replacement, candidate reparse and semantic equality, atomic rejection, connector following, and real GHC-Wasm dispatch. It uses private TikZ picture/render types and browser-owned revision state rather than common Canvas/App/Render.
2. `slideblaster.product/1` proves common Canvas nodes/outlines, selection, snapping/binding, insertion, and semantic undo/redo through a real stateful Wasm endpoint. Its `App.Live.LiveAuthoring` explicitly has no source authority or persistence and duplicates revision/history concerns. It is not mounted by the packaged browser.

### Existing authority pieces

- Source: `SourceBufferSnapshot` is opaque revision + bytes; `ExactReplacement` enforces revision, bounds, expected bytes, locality, and one-step advancement.
- Document: generic `DocumentSnapshot` keeps source always, semantics/provenance only when ready. Only `DirectSlot` provenance with a projection rule is ordinarily editable.
- TikZ: private bounded CST/model and phased candidate/verified patch already implement the exact node-coordinate inverse and semantic equality test. Sixteen focused laws cover byte preservation, locality, stale/no-op, unsupported/ambiguous/missing targets, verification atomicity, CRLF/Unicode, and connector following.
- Canvas: closed common `EditIntent`, especially `MoveElement ElementId Placement`; `resolveDrag` owns binding/theme/alignment/spacing/grid policy and returns authored placement plus guides.
- Render: common closed `RenderPlan` is fenced by revision, ticket, surface, and step with validated layers/resources/interactions. A full Presentation-to-plan lowerer is still absent.
- App: `SourceHistory` stores exact bytes; `DocumentSession` owns draft, accepted generic document, pending paints, and per-surface authority. Paint/edit leases use session + revision + ticket + surface. `App.Update` lacks a canvas-edit/verified-source-edit event seam.
- Wasm: reactor exports `sb_dispatch` and `sb_product_dispatch`; the latter is a process-global `MVar LiveAuthoring` and is real but non-persistent.

### Duplicate and temporary models

The bounded TikZ model is legitimate private format-reader/projector state. Generic Document + Canvas/Presentation are the accepted semantic model. `AppModel`/`DocumentSession`/`SourceHistory` are the accepted app authority. `LiveAuthoring` is temporary non-source demonstration state and must not be extended into a second persistent editor. Browser engine revision state is temporary composition state. JSON values are disposable projections, not models.

### Product wire/renderer incompatibility

`SlideBlaster.Protocol.Product` fixes `slideblaster.product/1` and emits an 11-field workspace including `persistent=false`, `persistenceReason`, `canUndo`, `canRedo`, `themeEditor`, `snapGuides`, and `catalogFamilies`. `product-renderer.js` exact-key validation expects six differently named/structured fields (`guides`, different theme, box, path, arc, and style shapes). A product response fails the renderer closed. No production module mounts `mountProductRenderer`; `main.js` only calls engine dispatch.

### Host tests

`hosts/web/package.json` has build/serve only. No checked-in JS unit, DOM, Playwright/Puppeteer, or packaged-browser E2E test was found. Existing session-local smoke references are not tracked. Build/serve evidence therefore does not prove browser interaction.

## Thinnest safe seam

Root one source-authoritative session in `AppModel TikzSyntax TikzFieldKey`:

```text
exact bytes -> SourceHistory/current snapshot
 -> bounded TikZ parse/CST
 -> adapter builds generic DocumentSnapshot + common Presentation/Canvas + provenance
 -> App accepts exact-current analysis and issues common paint request
 -> minimal lowerer creates common closed RenderPlan
 -> browser validates/paints and acknowledges lease
 -> pointer release sends lease-fenced common MoveElement
 -> common drag policy produces the same typed operation used for preview/commit
 -> adapter delegates supported absolute node move to existing TikZ verified projector
 -> App records verified successor bytes exactly once
 -> reanalysis and successor paint; browser rejects stale responses
```

Undo uses `App.History`, never `LiveAuthoring`. Unsupported common placement forms reject atomically unless an explicit inverse exists. The bounded connector source stays unchanged and follows through successor semantics/layout.

Missing work is therefore: TikZ-to-common document/provenance adapter; common-move-to-TikZ projector; app canvas edit/completion seam; minimal common render lowerer; versioned app/product codec with lease fencing; browser mounting/validation; real Wasm/browser E2E.

## Protocol decision gate

The internal seam is already authorized by accepted ADR 0004 and app/render/source contracts. The public wire choice is not safely inferable:

- extending/redefining `slideblaster.product/1` mixes temporary non-source and source-authoritative meanings;
- `slideblaster.product/2` can freeze `/1` and clearly represent `AppModel`, exact source, leases, and common render projection;
- a separate `slideblaster.app/1` avoids redefining product but risks multiple browser protocols and split state.

Recommendation: `slideblaster.product/2`, unless the product owner wants `/1` removed rather than retained. This is a durable protocol boundary and requires the recorded product-owner decision before implementation.

## Evidence index

- `packages/slideblaster-source/src/SlideBlaster/Source/{Snapshot,Edit}.hs`, tests
- `packages/slideblaster-document/src/SlideBlaster/Document/{Snapshot,Provenance}.hs`
- `packages/slideblaster-tikz/src/SlideBlaster/TikZ/{Edit,Internal/Edit,Internal/Types}.hs`, tests
- `packages/slideblaster-engine/src/SlideBlaster/Engine/TikZ.hs`, tests
- `packages/slideblaster-canvas/src/SlideBlaster/Canvas/{Edit,Snap,Outline}.hs`
- `packages/slideblaster-render/src/SlideBlaster/Render/{Plan,Outline}.hs`, tests
- `packages/slideblaster-app/src/SlideBlaster/App/{History,Lease,Model,Update,Live}.hs`, tests
- `packages/slideblaster-protocol/src/SlideBlaster/Protocol/{Types,Codec,Run,Render,Product}.hs`, tests
- `apps/slideblaster-web-wasm/src/SlideBlaster/Adapter/Web/{Dispatch,Product}.hs`
- `apps/slideblaster-web-wasm/app/Main.hs`
- `hosts/web/src/{main.js,wasm/load-reactor.js,ui/product-renderer.js}`
- `docs/architecture/{product-model.md,app-semantics.md,capability-map.md,vertical-slices.md}`
- `docs/specs/{vs-app-state.md,vs-canvas-authoring.md,vs-render.md,slice1-roundtrip-integration.md}`
- `docs/decisions/{0001-dual-target-haskell-repository.md,0002-source-snapshot-and-verified-edits.md,0004-product-semantic-backbone.md}`

## Limitations

This was static research; it did not claim browser behavior. No checked-in host test exists. Full structured text/font rendering and persistent browser working-copy writes remain outside the bounded fixture.

## Conclusion

Compose the proven TikZ inverse with the accepted generic Document/Canvas/App/Render path; bypass temporary `LiveAuthoring`; make App the sole source/history/lease authority; leave JS as closed projection/event/capability interpreter. Freeze a versioned protocol only after the product-owner gate. This report is evidence, not an accepted decision.
