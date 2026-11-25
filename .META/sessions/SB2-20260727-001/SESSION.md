# SB2-20260727-001: Source-authoritative editable browser canvas

- ID: `SB2-20260727-001`
- Type: `implementation`
- Status: `active`
- Created: `2026-07-27`
- Base branch: `dev`
- Session branch: `session/SB2-20260727-001`

## Goal

Connect exact authored TikZ source, the common semantic/application/render model,
the closed product protocol, the real GHC-Wasm reactor, and the browser canvas
into one source-authoritative node-drag path with exact undo and atomic stale or
unsupported rejection.

The captured `.prompt` is the exact goal file supplied by the product owner. The
additional orchestration direction in the initiating chat governs role
independence, the shared bus, stage order, and approval gates.

## Ownership

The orchestrator owns session records and synthesis. Until Stage 3 assigns
implementation writers, all product source, tests, manifests, current docs, and
legacy trees are read-only. Role assignments, dependencies, artifacts,
acceptance checks, and statuses are authoritative in `BUS.md` and `SLICES.md`.
Legacy `../editor/`, `../design/`, and `../knowledge/` and
`.META/sources/drawio/` remain read-only for the entire session.

## Evidence

- Baseline branch: `dev`.
- Baseline revision: `8aa9cece4a056332cabc214508adec4b63ff4685`.
- Initial status: clean (`git status --short --branch` printed only `## dev`).
- Research runs will live under `.META/research/SB2-20260727-001--*`.
- Exact commands/results and every stage transition are recorded in `BUS.md`.

Technical verification does not substitute for product-owner observation,
acceptance, exact change review, integration authorization, or closure.

## Handoff

The governed local review artifact is running at `http://127.0.0.1:4180/`
with no-store headers. Zoom and pan are local browser presentation state in
`hosts/web/src/ui/viewport.js`, applied as one composited canvas transform at
unit layout scale: pointer-anchored Ctrl/Cmd wheel and pinch zoom, plain-wheel
panning, centred button and keyboard zoom, reset, Fit width, middle-drag and
Space+primary panning, plus the persistent accessible rail-bottom
`+ New slide`. The product owner accepted this viewport and authorized removing
the superseded Haskell viewport reducer and the Product/2 `viewport_event`
vocabulary, which are now gone from the app, protocol, runtime, browser decoder,
tests, and specifications. Source bytes, revisions, history, selection, snapping,
and verified node movement remain Haskell-owned.

One material risk is open: a scripted deletion destroyed about 530 lines of
`SlideBlaster/Product/Runtime/ProductV2.hs` and the file had no recoverable copy,
so the request-handling core was reconstructed from the intact laws and package
contracts. It is behaviourally equivalent under every retained law but is not the
original text and needs product-owner review before integration. `REVIEW.md`
records the incident in full.

Ten native package suites pass, including all fifteen retained runtime laws; host
tests pass 37/37; Wasm packaging, exact-port Chrome, `git diff --check`, and
session validation pass. Acceptance of the viewport is recorded; session closure
and integration are not authorized, and nothing has been committed, integrated,
released, or deployed.

## Alpha integration (0.2.0-alpha) — 2026-11-06

- Integrated into branch `alpha` (not `dev`) from session/SB2-20260727-001 (83acebc) by merge commit `c21617f472104a9119efc69624048215793c379b`.
- Authority: on 2026-11-06 the product owner authorised the SlideBlaster 0.2.0-alpha
  integration (see `docs/architecture/alpha.md`), covering agent implementation, review
  and local commits, with no push and no movement of `dev` or `main`.
- The product owner's earlier 'changes requested' recorded in this file's Change review section is superseded for the alpha by the explicit authorisation below; the viewport/carousel follow-up observations above remain pending and are not claimed as accepted.
- Status is deliberately left at `active`: `approved-for-integration` and later states
  require product-owner approval of a review unit and an integration commit contained in
  `dev`, which this alpha integration does not claim.
