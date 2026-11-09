---
status: accepted
updated: 2026-07-27
---

# Vertical-slice program

Delivery remains vertical, but the product model is established before further
feature breadth. The first TikZ proof does not define the application roadmap.
Canvas authoring, presentation, and export are parallel product slices sharing
the semantic backbone in
[product-model.md](product-model.md) and the state machine in
[app-semantics.md](app-semantics.md).

## Slice 0: dual-target composition proof

User-visible demonstration:

```text
open exact source
  -> inspect its revision and byte length
  -> apply a revision-checked and expected-text-checked replacement
  -> inspect the new source
  -> perform the same request through the CLI and browser Wasm protocol
```

This proves:

- the shared source and protocol packages compile natively and to Wasm;
- exact bytes and source revisions survive the boundary;
- the native and JavaScript capability seams are real;
- a rejected primitive edit is atomic.

It does not claim CST, TikZ semantics, canvas verification, or formatting.

## Slice 1: source to canvas to source

User-visible demonstration:

```text
open a noncanonical SlideBlaster/TikZ source
  -> parse one node and one connector losslessly
  -> render them in the browser
  -> drag the node
  -> project and verify the new coordinate
  -> show the updated source
  -> prove every unrelated byte is identical
  -> exercise the same edit through the CLI
```

This slice introduced the lossless CST and verified inverse. Its current browser
integration promotes the admitted node/connector through generic Document and
common Canvas/Presentation/Render, roots source/history/leases in one AppModel,
and exposes a Haskell-owned begin/preview/commit gesture through Product/2. The
older Product/1 endpoint is frozen, inactive in the packaged host, and retained
until separately approved removal.

## Format proof: bounded LaTeX/Beamer reader

Add one explicitly bounded LaTeX/Beamer reader and writer slice:

- preserve the complete authored input;
- interpret one supported frame/tikzpicture subset;
- canvas-edit a direct coordinate through provenance;
- regenerate clean LaTeX for a new document;
- retain unsupported LaTeX as diagnosed, source-backed, read-only syntax.

LaTeX is not relegated to export only. Reading authored `.tex` and generating a
new LaTeX export project are nevertheless separate contracts: the reader
preserves exact source and supports verified local edits; the export writer is
pure, deterministic, best-effort, and has no reverse law.

## VS-CANVAS: real canvas authoring

User-visible demonstration:

```text
open one multi-object slide
  -> render text, a catalog shape, and a connector with real properties
  -> select and inspect the node
  -> drag with relative binding or alignment/spacing/grid snapping
  -> change one paint/property value
  -> verify and patch only the owning source slots
  -> undo as one source transaction
```

This slice owns:

- freely mixed provenance-tagged Markdown/LaTeX/HTML content;
- nodes, generic outline geometry, catalog presets, imported stencils, groups,
  images, and ordered layer barriers;
- editable straight/orthogonal/cubic connectors and their properties;
- absolute/relative placement, resize, rotation, paint, typography, role,
  overlay and animation references;
- structured theme style/master-regions/furniture and property precedence;
- measurement, resolved layout, snapping/binding, hit regions, and typed canvas
  intents.

The package must contain an executable pure resolver before it is promoted:
property resolution plus drag binding/snapping is the initial proof. Browser
completion additionally requires a real Wasm intent and verified source patch.
Catalog breadth can then grow as data without changing the object model.

## VS-PRESENT: notes, overlays, animation, and presenter

User-visible demonstration:

```text
open a two-slide deck with audience builds and notes
  -> preview audience and notes at one shared step
  -> start presenter mode
  -> advance from either window through steps then slides
  -> show notes, next beat, counters, and elapsed time in the console
  -> apply reduced-motion policy to timed animation
```

This slice owns:

- ordered `Presentation`/`Frame` values and optional full notes pictures;
- fixed-geometry Beamer-style overlays and audience-derived step counts;
- timed animation triggers, keyframes, easing, repeats, effects, slide
  transitions, and reduced-motion behavior;
- the flat beat list, cursor transitions, audience projection, and presenter
  console projection;
- same-snapshot synchronization between audience and console.

The initial executable proof is pure beat flattening/navigation/projection with
notes capped to audience steps. Browser completion uses the same projections
through the Wasm protocol and treats popup/channel operations as host
capabilities.

## VS-EXPORT: standalone HTML, rendered PDF, LaTeX, and archive

User-visible demonstration:

```text
choose an export target
  -> analyze the exact semantic revision
  -> show target-specific fidelity warnings or fatal errors
  -> honor fail-on-loss or warn-and-approximate policy
  -> emit/download a deterministic artifact or invoke a typed print capability
```

This slice owns:

- one `ExportRequest`/`ExportReport` vocabulary for HTML, PDF, LaTeX, and
  workspace archive;
- deterministic standalone HTML with interactive beats/animations;
- PDF page planning over rendered beats and a browser/native print capability;
- deterministic best-effort LaTeX project generation with theme,
  bibliography, assets, and explicit animation/fidelity diagnostics;
- deterministic safe workspace traversal/archive rules;
- target/object/animation-addressed warnings and fatal failures.

The initial executable proof is a standalone HTML writer plus LaTeX
compatibility/project planning. PDF does not return invented bytes from the pure
core; it becomes complete only when a real capability executes its page plan.

## VS-APP: shared application state and browser composition

This integration slice is owned centrally because it joins the other three:

```text
working copy -> source session/history -> semantic document
  -> canvas authoring
  -> presenter snapshot
  -> export workflow
```

It implements command availability, exact source history, render leases,
selection/tool state, continuous deck/navigation, notes rows, theme editor
entry, async correlation, and Wasm-to-host effects. JavaScript mounts plans and
performs browser capabilities; Haskell owns policy and state transitions.

## Capability slices

Capabilities are added through the smallest real workflow that uses them:

- browser working copy: open, save, reopen, list, and asset/theme access;
- Git: status/diff/stage/commit/push with hard-diagnostic gates;
- compile: tables/citations through the packaged compiler adapter;
- collaboration: source/semantic convergence without a second edit path;
- workspace archive: deterministic export/import with path safety.

Native and web interpreters implement the same small port vocabulary. A missing
capability disables its command with a typed reason; it never causes semantic
logic to move into the host.

## Acceptance for every slice

Each slice records:

- one observable end-to-end capability;
- the full type/module contract and the implemented subset;
- source authority and stale/failure behavior;
- native and Wasm applicability;
- focused semantic tests;
- protocol/adapter/browser checks when the slice crosses those boundaries;
- explicit fidelity warnings, read-only regions, and deferred syntax.

A directory tree or a set of placeholder ADTs is not completion. Conversely,
an untyped browser shortcut is not a vertical slice because it cannot join
source verification, native tooling, presenter, or export.
