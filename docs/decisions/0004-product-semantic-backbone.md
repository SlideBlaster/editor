---
status: accepted
updated: 2026-07-23
---

# 0004. Establish the complete product semantic backbone before further parity work

## Context

Slice 0 and the bounded TikZ Slice 1 proved exact bytes, native/Wasm
composition, a small renderer-neutral plan, and one verified canvas edit. The
implementation then treated broader SlideBlaster behavior as a long serial list
after that proof.

That order did not define the actual application. Important existing product
concepts had no Haskell home: continuous decks, notes sidecars, presenter beats,
mixed Markdown/LaTeX/HTML content, the shape catalog and real object properties,
themes and furniture, snapping/binding, general animation, standalone HTML,
rendered PDF, and best-effort LaTeX export. Continuing from the narrow TikZ
types risked making those features bolt-ons or duplicating their semantics in
JavaScript.

## Decision

Promote a complete, target-neutral semantic backbone now. It is organized
around:

- `slideblaster-canvas`: pictures, mixed content, canvas objects, properties,
  shape presets/generic geometry, themes, authored versus resolved placement,
  and snapping/edit vocabulary;
- `slideblaster-presentation`: presentations, frames, audience/notes surfaces,
  overlays, timed animation, beats, and presenter projections;
- `slideblaster-document`: exact-source-locked syntax, semantic readiness,
  diagnostics, and provenance;
- `slideblaster-export`: standalone HTML, rendered-PDF planning, LaTeX project
  generation, workspace archive planning, and explicit fidelity reports;
- `slideblaster-app`: source/history/render leases, selection/tools, commands,
  async effects, presenter state, and export workflows.

The browser remains the primary composition, and its JavaScript remains a
capability/render host. Haskell owns presentation meaning, layout decisions,
command availability, presenter cursor semantics, animation classification,
and export fidelity diagnostics.

Implementation advances in parallel vertical slices:

1. canvas authoring implements a real property and binding/snapping path;
2. presentation implements real beat flattening/navigation and synchronized
   audience/console projection;
3. export implements a real standalone HTML writer and LaTeX compatibility/
   project path;
4. the app integration composes those paths through Wasm and the browser.

Every material legacy capability receives a module, type, and executable
contract even when its concrete source projection or browser interaction is
not yet implemented. Contract-only and implemented behavior are labeled
separately.

The common model represents a broad product meaning; individual readers remain
bounded. An unsupported source form is preserved and diagnosed rather than
being accepted merely because the semantic type could represent it.

## Consequences

- Themes, notes, animation, and export participate in the model early enough to
  constrain layout, rendering, protocols, and source provenance correctly.
- Standalone HTML, presenter mode, and PDF share the same beat/render contract.
  Generated LaTeX uses the same presentation but reports target-specific loss.
- A shape catalog can grow as data over generic geometry instead of expanding a
  closed application object enum.
- More packages and public types exist before all are wired through the
  browser. This is accepted only because each promoted feature package includes
  an executable vertical proof and the app integration is an explicit next
  gate.
- The bounded TikZ package remains valuable as a reader/edit proof. Its private
  small model must adapt into the common canvas model rather than becoming a
  competing application architecture.

The detailed model is
[product-model.md](../architecture/product-model.md); application layout and
state transitions are
[app-semantics.md](../architecture/app-semantics.md); delivery checks are
[vertical-slices.md](../architecture/vertical-slices.md).
