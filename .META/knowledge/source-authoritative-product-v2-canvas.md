---
id: source-authoritative-product-v2-canvas
title: Product/2 is the source-authoritative bounded browser canvas
status: current
updated: 2026-07-28
tags: [haskell, browser, wasm, source, canvas, protocol, app, tikz]
---

# Product/2 is the source-authoritative bounded browser canvas

The packaged Haskell browser actively uses `slideblaster.product/2`. One
long-lived `AppModel` is the sole authority for exact source/history, accepted
analysis, and session/revision/ticket/surface paint leases. Generic
Document/Canvas/Presentation/Render values are the semantic and paint
vocabulary. The private bounded TikZ adapter preserves/reparses source and owns
the intended-semantic inverse; App's public canvas-successor commit is an honest
mechanical exact-source/lease/history boundary, not a semantic-proof sealer.
Direct literal `at (x,y)` nodes retain their authored border port: snap geometry
resolves a disposable box centre, then Product/2 converts that centre back to the
retained anchor point before the Deck inverse replaces only the two coordinate
lexemes. Recognized anchors such as `north west` are writable; relative,
expanded, unknown, or ambiguous placement forms remain read-only and receive no
drag interaction projection.

A drag begins with the exact revision, selected node, and displayed paint fence.
Haskell owns press/threshold/drag/preview/commit/cancel and stores the exact
common operation, App request, and verified/no-op Deck result consumed on
release. Normal snapping runs first. If its placement cannot enter the bounded
Deck inverse because it is relative or a non-terminating exact decimal, Haskell
retries the unchanged pointer destination as guide-free `FreeDrag`; it never
rounds or asks JavaScript to decide. A pointer destination that is itself
unsupported still cancels atomically. Authority or source/history changes
invalidate gestures. Failures are source-redacted.

Product/2 projects stable frame identity/title plus a closed static audience and
optional notes plan for every slide. The browser may paint vertical thumbnails
and a continuous deck from those plans, but only the Haskell-active acknowledged
audience paint is interactive. `select_slide` returns stable identity to Haskell,
which validates it and resets gesture/selection before choosing active paint.

The real GHC-Wasm adapter serializes Product/2 state in an `MVar`. Browser
JavaScript only validates closed projections, paints, translates finite pointer
events, and interprets capabilities. The admitted trial is the provisional
multi-slide implicit-canvas Deck/TikZ subset with direct-coordinate writable nodes
that retain recognized authored anchors, static notes projection, straight connectors, and deterministic New Slide;
broader TikZ, structured text/font measurement, notes editing, and general
authoring remain deferred.

`slideblaster.product/1` remains unchanged and frozen for compatibility, is not
mounted by the packaged host, and may be removed only in a later separately
approved migration. See `docs/specs/product-v2-protocol.md` and
`.META/sessions/SB2-20260727-001/SPEC.md`.
