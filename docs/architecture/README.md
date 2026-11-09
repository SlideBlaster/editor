---
status: accepted
updated: 2026-07-27
---

# Architecture

The accepted direction is defined cross-project by
[ADR 0025](../../../design/decisions/0025-slideblaster2-haskell-core.md).
The product model is broader than the first bounded source-edit proof:

```text
exact source + CST/provenance
              |
              v
      semantic Presentation
       /          |          \
      v           v           v
 Canvas       Presenter      Export
authoring   notes/animation  HTML/PDF/LaTeX
      \           |           /
       +----------+----------+
                  v
       layout + typed RenderPlan
                  |
          native CLI / Wasm app
```

The 0.2.0-alpha build design (format, extension interface, features, lanes) is in
[alpha.md](alpha.md).

The complete semantic ownership is in
[product-model.md](product-model.md). Browser workspace layout, app state,
commands, asynchronous leases, presenter synchronization, and export workflows
are in [app-semantics.md](app-semantics.md). These contracts give every original
SlideBlaster capability a module/type home now. The
[capability map](capability-map.md) records which paths are executable,
represented, bounded, contract-only, or still require a product decision.

The packaged browser now executes one source-authoritative bounded transaction
inside that model:

```text
exact SourceBufferSnapshot + SourceHistory (one AppModel)
  -> private lossless TikZ reader/projector
  -> generic DocumentSnapshot + common Canvas/Presentation
  -> App PaintRequest/lease -> common RenderPlan -> validated browser paint
  -> begin exact paint/revision/selection gesture
  -> Haskell stores common MoveElement + App request + TikZ verified/no-op result
  -> commit by monotonic gesture ID only
  -> exact successor history -> reanalysis/repaint -> exact-byte undo
```

`SourceBufferSnapshot` remains the sole persistence authority. The private TikZ
CST owns format recovery and inverse projection; it is not a competing product
model. App owns exact history and per-surface paint authority. The common
Document/Canvas/Presentation/Render packages own semantic and paint vocabulary.
The real GHC-Wasm reactor owns the long-lived Product/2 state in an `MVar`; the
browser host validates, paints, translates events, and interprets capabilities
without reconstructing source or semantic policy.

Product/2 is deliberately bounded to the admitted node and connector subset.
Structured text requiring exact font measurement and broader syntax remain
excluded. The older `slideblaster.product/1` endpoint is frozen for
compatibility, inactive in the packaged host, and may be removed only by a
separately approved migration. See the
[Product/2 protocol contract](../specs/product-v2-protocol.md).

The architecture documents are:

- [core-model.md](core-model.md)
- [product-model.md](product-model.md)
- [app-semantics.md](app-semantics.md)
- [capability-map.md](capability-map.md)
- [runtime-targets.md](runtime-targets.md)
- [vertical-slices.md](vertical-slices.md)
- [Slice 1 integration](../specs/slice1-roundtrip-integration.md)

The current package mapping is [PROJECT.md](../../PROJECT.md).
