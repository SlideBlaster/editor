---
status: proposed
updated: 2026-07-23
---

# Vertical slice: honest multi-target export

## Purpose

This slice gives the native and WebAssembly builds one export contract without
pretending that every target is a pure byte serializer. It covers four targets:

1. a self-contained standalone HTML presenter;
2. rendered PDF through a browser or native webview print capability;
3. a deterministic, best-effort LaTeX source project; and
4. a deterministic whole-workspace archive.

The contract separates semantic planning from host effects. Haskell decides
what must be preserved, which losses are acceptable, which diagnostics apply,
and what capability a host must execute. A host may execute a declared
capability; it may not silently reinterpret a rejected plan or report invented
PDF/archive bytes.

This slice is governed by the accepted client-side export, TeX source export,
theme, overlay, and presenter decisions. It does not introduce a render service
or a TeX compiler.

## One request and one report

`ExportRequest` is a closed sum with one constructor per target. Each
constructor carries only the inputs valid for that target:

```text
ExportRequest
  = StandaloneHtmlRequest Presentation RenderedBeatSet HtmlOptions
  | RenderedPdfRequest   Presentation RenderedBeatSet PdfOptions
  | LatexProjectRequest  Presentation LatexOptions
  | WorkspaceArchiveRequest WorkspaceSnapshot ArchiveOptions
```

The exact Haskell constructor names are frozen by the package API. The shape
above explains the boundary:

- the public presentation model supplies a non-empty deck of coherent audience
  scenes, optional notes scenes, authoritative beats, and timed animations;
- semantic pictures, identifiers, mixed content, theme, and furniture come
  from the public canvas model;
- `RenderedBeatSet` is export input produced by the renderer, keyed to the
  presentation's beat identities; it is not a second deck model;
- a workspace snapshot is an ordered set of exact path/byte entries, not an
  interpretation of presentation source.

Every planner produces an `ExportReport`:

```text
ExportReport
  { target
  , diagnostics
  , outcome
  }

ExportOutcome
  = ArtifactsReady [DeterministicArtifact]
  | CapabilityRequired CapabilityPlan
  | ExportRejected
```

Reports are constructed through package functions rather than an exported
record constructor. Their invariants are:

- `ExportRejected` contains at least one fatal diagnostic;
- an artifact or capability plan contains no fatal diagnostic;
- warnings may accompany either a ready artifact or a capability plan;
- artifact paths, diagnostics, beats, assets, and workspace entries have a
  deterministic order;
- an identical request produces byte-identical pure artifacts and an identical
  capability plan;
- no outcome contains a clock, random identifier, host path, or ambient locale.

## Diagnostics and loss policy

Every incompatibility is explicit. A diagnostic has:

- severity: warning or fatal;
- a stable machine-readable code;
- a human-readable explanation;
- a location: whole document, slide, node, animation, asset, or workspace path;
- the target whose fidelity is affected.

Locations use public semantic identities, not DOM identifiers or list indexes.
An animation diagnostic identifies both its owning slide/node and animation
when the model provides those identities.

The caller chooses a `LossPolicy`:

- `RejectLoss` turns every known loss or approximation into a fatal diagnostic;
- `PermitDocumentedApproximation` permits only approximations enumerated by the
  target compatibility analysis and returns a warning for each one.

There is no "ignore" policy. Unsupported input that has no documented
approximation always fails.

## Target contracts

### Standalone HTML

Standalone HTML is one UTF-8 document containing:

- every presentation beat in presenter order;
- the renderer-owned markup for each beat;
- all required style text;
- all required runtime JavaScript;
- embedded local assets;
- keyboard and pointer navigation over the same flattened beat list used by
  presenter mode;
- supported timed animation metadata/runtime.

The writer validates that rendered beats match the presentation beat list
exactly. A missing, duplicate, unknown, or reordered beat is fatal. The writer
also rejects an external script, stylesheet, font, image, or media dependency:
"standalone" means the artifact works offline without fetching another
resource. Embedded bytes use deterministic data URLs.

Overlay steps are preserved as separate beats. Timed animations stay timelines
inside their owning beat and do not become extra beats. If the standalone
runtime does not support an animation kind, the export either fails or applies
one specifically documented static approximation under
`PermitDocumentedApproximation`; it never deletes the animation silently.

The real writer implemented in this slice emits `index.html` with deterministic
escaping, ordering, CSS, navigation script, beat metadata, and embedded markup.
It accepts renderer-produced beat fragments because semantic `Picture` values
alone do not contain the final HTML produced by Markdown/LaTeX/HTML compile
adapters.

### Rendered PDF

Rendered PDF is not a pure `ByteString` writer.

The pure package validates the same complete rendered beat set as standalone
HTML, constructs a deterministic print document with one page per beat, and
returns a `PrintRenderedBeats` capability plan. The plan declares:

- the exact print-document bytes;
- page order and count;
- page size and orientation;
- the target output name;
- animation sampling decisions and their diagnostics.

The web host executes the plan with browser print. A native host executes it
with its bundled webview. The browser print dialog may not return PDF bytes, so
successful dispatch and artifact acquisition are distinct host results. The
pure report never labels its print HTML as a PDF.

Overlays naturally produce one page per beat. A continuously timed animation
cannot exist in static PDF. Under `RejectLoss` it is fatal. Under
`PermitDocumentedApproximation` the request must name a supported sampling rule
such as first or final state. The renderer records that choice by constructing
each fragment with `staticRenderedBeat`; each sampled animation produces a
warning at its animation location.

### LaTeX project

LaTeX export is a pure source handoff and never invokes `latex`, `latexmk`,
LaTeXML, a server, or a WASM TeX distribution. A successful project contains a
deterministically ordered set headed by:

```text
deck.tex
theme.sty
refs.bib       when bibliography data is present
assets/...     referenced local assets, or declared copy requirements
```

The compatibility analysis runs before generation and accounts for every
audience scene, notes scene, node, content run, theme feature, furniture item,
and animation:

- fixed picture geometry maps to TikZ coordinates;
- overlay builds map to Beamer overlay specifications and remain one semantic
  slide with multiple pages;
- point pauses in audience or notes content map to Beamer `\pause` commands;
- an optional notes scene is emitted inside its owning frame as
  `\note{\begin{tikzpicture}...\end{tikzpicture}}`, preserving the same generic
  node/content projection rather than flattening notes to plain text;
- provenance-tagged LaTeX content is passed through exactly where its public
  content representation promises that;
- supported Markdown and HTML content is projected to LaTeX;
- furniture is emitted;
- editor-only master layout regions are omitted by product definition and
  reported as an informational compatibility fact when present in the input
  view;
- browser-only HTML/CSS, unsupported theme effects, missing fonts, and timed
  animations produce scoped warnings or fatal diagnostics according to the
  loss policy; audience and notes timelines are diagnosed independently;
- an unknown or non-projectable construct is always fatal.

The project is best-effort, not WYSIWYG. Even a lossless compatibility result
retains target-level warnings for TeX text reflow and environmental font
availability unless the input proves those concerns irrelevant.

The writer implemented in this slice produces real `deck.tex` and `theme.sty`
artifacts for the bounded public canvas/presentation subset. Its focused tests
cover overlay wrappers, point pauses, speaker-note pictures, audience/notes
timed-animation warnings, deterministic output, and at least one hard
rejection.

### Workspace archive

The archive target snapshots the complete working copy, not only source files
known to the presentation parser. Entries use normalized relative POSIX paths
and exact bytes. They are sorted lexicographically. `.git` and its descendants
are excluded; no timestamp, owner, host path, or platform-specific separator
may affect output.

The pure package validates paths, rejects duplicate or unsafe entries, and
returns a deterministic archive-compression capability plan. Compression and
download are host capabilities in this slice; no arbitrary pure bytes are
called a ZIP file. A future pure ZIP writer may replace that capability without
changing `ExportRequest` or the report invariants.

Import safety such as zip-slip defense remains an import responsibility, but
the export planner only admits paths that would pass the same relative-path
rules.

## Capability execution

Capability plans are data. Initial plans are:

| Capability           | Required target   | Host responsibility                                                                       |
| -------------------- | ----------------- | ----------------------------------------------------------------------------------------- |
| Print rendered beats | rendered PDF      | load exact print document, invoke browser/webview print, report dispatch or acquired file |
| Compress workspace   | workspace archive | create deterministic ZIP from ordered exact entries                                       |

Project-asset copying is a future capability. Until that plan can carry both
generated source artifacts and exact resolved asset bytes without an invalid
half-success state, image-bearing LaTeX requests fail with an asset-scoped
diagnostic.

The web and native shims implement these effects separately. The pure export
package must build unchanged for native GHC and GHC-Wasm.

## Determinism rules

All generated text is UTF-8 with LF line endings. The writers:

- sort artifact paths and unordered metadata explicitly;
- preserve semantic presentation order for slides, beats, nodes, and
  animations;
- use fixed escaping rules independent of locale;
- emit no generated timestamps or random nonces;
- use stable decimal/text representations from the public semantic packages;
- never inspect the file system, browser, environment, or clock.

Two reports are byte-for-byte equal when their requests are equal. A host may
produce a PDF with platform metadata after capability execution; that
host-produced byte equality is outside the pure determinism law and must not be
claimed by the planner.

## Source and rendering authority

Export reads an immutable semantic revision. It does not write source and does
not make the canvas authoritative. The rendered beat input is checked against
the same presentation identity and beat keys. If source or semantics advance,
the host must discard the stale rendered set and request a new export.

The package does not infer semantic content by scraping DOM. Markup fragments
are opaque renderer results carried only into renderer-native HTML/PDF
artifacts. LaTeX generation reads public semantic content and provenance.

## Implemented in this slice

- the GHC2024 `slideblaster-export` package and public report/diagnostic types;
- deterministic standalone HTML generation from a complete rendered beat set;
- rendered-PDF capability planning over the same beats;
- LaTeX compatibility analysis and bounded `deck.tex`/`theme.sty` generation,
  including Beamer pauses and speaker-note scenes;
- workspace path validation and deterministic archive capability planning;
- tests for determinism, beat coverage, HTML self-containment, overlay order,
  animation approximation warnings, LaTeX hard failure, and safe archive paths.

## Contract-only after this slice

- browser/native print capability execution and acquisition of its resulting
  PDF;
- deterministic ZIP compression and browser download;
- storage-backed asset resolution/copying;
- the complete Markdown/HTML-to-LaTeX projection table;
- compiling generated projects in CI with a user-supplied TeX toolchain;
- pixel-parity tests across Chromium and native webviews;
- animation kinds beyond the bounded compatibility table implemented here.

These items are not represented by fake success values. Requests that require
them either return a capability plan or a scoped fatal diagnostic.

## Required tests

The package test suite must prove:

1. identical requests produce identical reports and artifact bytes;
2. standalone HTML contains no external dependency and preserves beat order;
3. missing or foreign rendered beats are fatal;
4. PDF returns a print capability, not a PDF artifact;
5. overlay beats become distinct HTML/PDF pages in presenter order;
6. timed animation fails under `RejectLoss` and warns under an explicit
   supported approximation;
7. supported LaTeX input produces stable `deck.tex` and `theme.sty`, preserving
   point pauses and optional notes scenes;
8. unsupported HTML/theme/animation input is never omitted without a
   diagnostic;
9. a non-projectable LaTeX feature has a tested hard-failure path;
10. unsafe or duplicate workspace paths are fatal and `.git` is excluded
    deterministically;
11. the package builds with `-Werror` under native GHC and, once integrated
    into the repository's Wasm package list, under GHC-Wasm.
