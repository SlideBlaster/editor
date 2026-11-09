# SlideBlaster 2 package and module map

This is the canonical map of the Haskell implementation. It records what exists
now, which package owns each invariant, and which boundaries are not yet wired
to the browser. Update it whenever modules or package dependencies change.

## Repository layout

```text
slideBlaster2/
  packages/
    slideblaster-source/        exact bytes, revisions, spans, replacements
    slideblaster-syntax/        mixed-dialect markup: read, print, expand, edit
    slideblaster-document/      coherent CST/semantic/provenance snapshots
    slideblaster-canvas/        picture, content, outline, theme, connector, edit
    slideblaster-catalog/       creation presets and attributed stencil data
    slideblaster-presentation/  frames, notes, overlays, animation, presenter
    slideblaster-render/        measurement, resolved layout, closed render plan
    slideblaster-export/        HTML/PDF/LaTeX/archive compatibility and planning
    slideblaster-app/           history, leases, commands, reducer, view state
    slideblaster-tikz/          bounded lossless TikZ reader/edit vertical slice
    slideblaster-deck/          *.slideBlaster.md container (+ provisional .slide trial reader)
    slideblaster-listing/       code-listing model and stepped highlight specs
    slideblaster-cite/          BibTeX reader and citation labels
    slideblaster-engine/        current stateless source/TikZ command engine
    slideblaster-protocol/      versioned engine and host wire boundaries
    slideblaster-product-runtime/ portable App/TikZ/render product composition; session/1 state machine, W analyzer, server driver
    slideblaster-extension/     extension manifests, slots, block.render envelope, fingerprints, TikZ request builder
    slideblaster-ports/         target-neutral runtime capability records
  adapters/
    slideblaster-adapter-native/ ordinary Haskell filesystem and Git effects
    slideblaster-adapter-web/    JSFFI host-capability calls
  apps/
    slideblaster-cli/            native composition
    slideblaster-web-wasm/       Wasm reactor composition
  hosts/web/                     packaged JavaScript/HTML/CSS browser host
  docs/
    architecture/                accepted implementation architecture
    decisions/                   durable Haskell implementation decisions
    specs/                       executable vertical-slice contracts
    research/                    evidence, never architectural authority
  .META/                         design, knowledge, sessions, provenance, research
  scripts/                       build, session, release, and local development tools
  VERSION                        product X.Y.Z (Cabal packages use X.Y.Z.0)
  CHANGELOG.md                   Unreleased and released product changes
```

`.META/design/` and `.META/knowledge/` are the repository-local destination
authorities. The legacy `../design/` and `../knowledge/` trees remain read-only
and must also be searched until a dedicated session safely migrates and
reindexes them.

## Dependency graph

Arrows point from a dependency to its consumer:

```text
slideblaster-syntax (no internal dependencies)
  +--> slideblaster-tikz
  +--> slideblaster-protocol

slideblaster-source
  +--> slideblaster-document
  +--> slideblaster-tikz ------------------------------+
  +----------------------------------------------------+
                                                       |
slideblaster-canvas                                    |
  +--> slideblaster-catalog                            |
  +--> slideblaster-presentation ----------------------+--> slideblaster-render
  +----------------------------------------------------+
  +--> slideblaster-export <--- slideblaster-presentation

document + canvas + presentation + render + export --------> app
source + canvas + presentation + render + export ----------> ports
source + tikz + document + canvas + presentation --> deck
source + tikz + canvas + document + presentation + render --> engine
app + canvas + catalog + engine + render -------------------> protocol (legacy Product/1 plus wire codecs)
protocol + app + engine + deck + common model --------------> product runtime

source + ports ----------------------------------------> native adapter
protocol + ports --------------------------------------> web adapter
source + engine + protocol + native adapter ----------> native CLI
protocol + product runtime + web adapter -------------> Wasm reactor
Wasm reactor + packaged JS capability host -----------> browser composition
```

The shared semantic packages compile for native GHC and GHC Wasm. The packaged
browser now uses Product/2 to compose exact source, the common model, App
history/paint authority, common rendering, and the bounded TikZ inverse. This
is one executable subset, not general browser feature parity; broader rendering,
content, presenter, and export compositions remain as mapped below.

## Shared semantic packages

### `slideblaster-source`

Owns exact authored bytes and mechanical source replacement.

- `SlideBlaster.Source` — public facade.
- `Source.Revision` — opaque monotonic process-local revision fences.
- `Source.Snapshot` — exact `SourceBufferSnapshot` and no-op-aware advancement.
- `Source.Span` — portable half-open byte offsets/spans.
- `Source.Edit` — revision/expected-byte/locality-checked replacement.

It has no SlideBlaster package dependency.

### `slideblaster-document`

Depends on `slideblaster-source`. It keeps source, recoverable format-specific
syntax, diagnostics, semantic meaning, and field provenance coherent for one
revision.

- `SlideBlaster.Document` — public facade.
- `Document.Diagnostic` — severity/category/code/span diagnostics.
- `Document.Provenance` — direct, derived, expanded, generated, and read-only
  origins with named inverse rules.
- `Document.Snapshot` — ready versus syntax-only document snapshots.

Concrete readers own their CST and choose the semantic/key parameters. This
package does not parse or canonicalize source.

### `slideblaster-canvas`

Target-neutral package with no source, DOM, filesystem, or process dependency.
It owns one audience or notes `Picture` and the semantic canvas vocabulary.

- `SlideBlaster.Canvas` — public facade.
- `Canvas.Identifier` — nominal IDs and stable `ElementId`.
- `Canvas.Geometry` — exact y-up slide units, points, sizes, boxes, ports.
- `Canvas.Overlay` — one-based fixed-geometry overlay visibility.
- `Canvas.Content` — recursive provenance-tagged Markdown/LaTeX/HTML content.
- `Canvas.Property` — total node/connector properties and precedence patches.
- `Canvas.Placement` — authored absolute/relative/derived placement.
- `Canvas.Connector` — validated anchors and straight/orthogonal/cubic paths.
- `Canvas.Theme` — structured style, master regions, safe area, furniture.
- `Canvas.Outline` — generic primitive, polygon, path, compound, and unresolved
  outline references; no palette rows or catalog metadata.
- `Canvas.Object` — ordered ordinary nodes/connectors/groups and source
  barriers.
- `Canvas.Snap` — binding-first alignment/spacing/grid drag resolution.
- `Canvas.Edit` — typed semantic authoring intents before source projection.

Catalog presets are not retained as semantic node identity. Insertion consumes
a preset into an ordinary outline, property patch, size, and content; an
equivalent hand-authored node is indistinguishable afterward.

### `slideblaster-catalog`

Depends on `slideblaster-canvas` and owns creation-time palette data rather than
canvas meaning.

- `SlideBlaster.Catalog` — public facade.
- `Catalog.Model` — validated preset/catalog/origin/attribution and stencil
  registry types.
- `Catalog.Curated` — the SlideBlaster-native curated P0 pack.
- `Catalog.DrawIO` — decoder for the separately packaged generated import.
- `Catalog.Search` — deterministic search and grouping.

The checked-in data currently combines 15 native P0 presets with 2,257
attributed imported P2 rows. The imported snapshot is quarantined from
`Canvas.Outline`: unresolved stencil references must be resolved to direct
geometry and exact resources before rendering. No live draw.io submodule is
accepted yet; choosing an exact upstream commit, included paths, and compatible
license/provenance manifest remains a user-gated source decision.

### `slideblaster-presentation`

Depends on `slideblaster-canvas`. It owns deck meaning rather than source or
windows.

- `SlideBlaster.Presentation` — public facade.
- `Presentation.Address` — stable
  `FrameId × (audience | notes) × ElementId` addresses.
- `Presentation.Scene` — coherent `Picture` plus derived overlays and validated
  animation ownership.
- `Presentation.Model` — aspect ratio, rotation, frame, notes, non-empty
  presentation, and authoritative non-empty flattened beats.
- `Presentation.Overlay` — normalized overlay aggregation and audience-owned
  step count.
- `Presentation.Animation` — typed tracks, timing, scheduling, endpoint
  sampling, transitions, and reduced-motion policy.
- `Presentation.Presenter` — total cursor and synchronized audience/console
  projections.

Every semantic frame contains an audience `Scene`; notes are optional full
`Scene` sidecars at the audience step and cannot add presenter beats. Timed
animation runs within an existing beat and also cannot add beats.

### `slideblaster-render`

Depends on source, canvas, and presentation. Render values are disposable
revision-fenced projections.

- `SlideBlaster.Render` — public facade.
- `Render.Content` / `Style` / `Geometry` — dialect-free direct paint values;
  the host does not parse authored content or resolve theme/shape semantics.
- `Render.Resource` — exact embedded font/image/media bytes and validated typed
  references.
- `Render.Measurement` — correlated batches over already-lowered content and
  the exact resource manifest, with positive-width and exact-coverage checks.
- `Render.Layout` — measured-node dependency resolution with missing-target,
  unsupported-placement, duplicate, and cycle failures.
- `Render.Plan` — closed layered direct primitives, interaction/accessibility
  data, resource closure, overlay visibility, animations, surface ownership,
  and render tickets.

The first executable layout kernel resolves node boxes and connector-ready node
maps. A measurement adapter that cannot honor structured `RenderContent` and
the plan's embedded fonts remains unavailable; flattening text or accepting
font fallback would invalidate layout authority. Furniture layout, catalog
stencil decoding, and full picture-to-plan lowering remain composition work;
they have typed destinations and cannot bypass the closed plan.

### `slideblaster-export`

Depends on canvas and presentation. It classifies fidelity before requesting a
target effect.

- `SlideBlaster.Export` — closed `ExportRequest` and pure `planExport`.
- `Export.Diagnostic` — target/location-scoped warning and fatal categories.
- `Export.Rendered` — renderer fragments keyed only from authoritative beats.
- `Export.Types` — HTML/LaTeX artifacts, print/archive capability plans, and
  invariant-preserving reports.
- `Export.Internal.Html` — deterministic self-contained HTML and print document.
- `Export.Internal.Latex` — recursive mixed-content LaTeX projection.
- `Export.Internal.LatexProject` — deterministic LaTeX project planning.
- `Export.Internal.Workspace` — safe deterministic workspace archive planning.
- `Export.Internal.Model` / `Report` — presentation compatibility analysis and
  report invariants.

Standalone HTML and LaTeX are deterministic artifacts. The LaTeX writer emits
picture/content pauses as Beamer `\pause` commands and preserves a frame's notes
scene in `\note`; animation diagnostics cover both audience and notes
timelines. PDF is an explicit print capability plan; workspace export is an
explicit archive capability plan. Animation or content loss is scoped and
warned or rejected according to `LossPolicy`; it is never silently omitted.

### `slideblaster-app`

Depends on the shared source/document/canvas/presentation/render/export
packages. It is pure and owns product policy, not DOM nodes or platform handles.

- `SlideBlaster.App` — public facade.
- `App.Capability` — closed availability vocabulary shared by command policy.
- `App.History` — branching exact-byte undo/redo with fresh revisions.
- `App.Lease` — opaque issued `PaintRequest` fences and painted authority.
- `App.Selection` — semantic tools, selections, panels, and zoom.
- `App.Command` — project/history/deck/source/canvas/property/theme/view/
  presenter/export commands and disabled reasons.
- `App.Model` — source draft, accepted analysis, last-good canvas, presenter,
  export jobs, capabilities, and view state.
- `App.Update` — pure source/analysis/paint/presenter transitions and typed
  capability effects.
- `App.CanvasEdit` — captures a common edit against exact accepted source and a
  writable paint lease, then mechanically commits a format-verified successor
  through exact history once.

The document session retains pending requests and canvas authorities per
`SurfaceAddress`. A paint completion is eligible only when it echoes the exact
issued session/revision/ticket/surface request; a self-consistent unsolicited
plan cannot grant authority. Product/2 now consumes these laws for its bounded
browser canvas. `commitCanvasSuccessor` is deliberately not a semantic sealer:
the format adapter must provide the reparsed, intended-semantic successor.

### `slideblaster-ports`

Depends on source, canvas, presentation, render, and export. It owns small
target-neutral capability records for workspace storage, Git, render
measurement, presenter windows/channel, download/print/archive, compile,
monotonic clock, and structured logging.

Capability provision is explicit: an adapter supplies a real interpreter or a
typed absence. Ports carry authoritative shared-package requests and results;
they do not form a global effect environment and do not grant adapters source,
layout, presenter, or export-policy authority.

## Existing bounded source/TikZ path

### `slideblaster-syntax`

Depends on nothing inside the repository, so it is usable from any layer. It reads
authored markup in LaTeX, HTML, and Markdown into one tree that retains each
construct's dialect and exact spelling, prints it back byte for byte, expands
LaTeX2e macro definitions, and edits style without an inverse rule.

- `Fix` closes each syntax functor and supplies the folds (`cata`, `para`,
  `cataM`), so traversals are algebras rather than hand-written recursion;
- `Ast` is one semantic tree of 18 constructors for all three dialects;
- `Surface` holds how each construct was spelled, including the dialect;
- `Style` is the shared style vocabulary, keyed so an edit can change one
  property without asserting anything about the others;
- `Colour` models xcolor's semantics and resolves expressions to sRGB;
- `Printer` is one exact printer for all three dialects;
- `Expand` performs bounded macro expansion;
- `Path` addresses a construct structurally, replacing byte spans;
- `Range` reduces a selection over rendered text to whole constructs;
- `Inline` lowers the tree to style-resolved runs for a renderer;
- `Edit` changes style at one construct, re-spelling it in its own dialect;
- `Command` is the edit language a user interface issues, as data, including the
  toggle a toolbar button means, resolved against the tree rather than by the host;
- `Tex.Reader` reads LaTeX and dispatches to the other notations;
- `Html.Reader` reads inline HTML, taking the content parser as an argument;
- `Markdown.Reader` reads inline Markdown, likewise.

Authored content is one mixed language. LaTeX, Markdown and HTML are co-equal
notations that appear side by side and nest inside one another in any order, with
nothing declaring a region and no outermost notation. All three are read from text.
The recursion knot is tied once, in `Tex.Reader`, so no reader knows what the
others are.

Because there is no root notation, the notation a *new* construct is written in is
decided in three steps: the innermost enclosing construct, else the content being
wrapped when it agrees with itself, else a theme setting. Only the last is a
configured choice, and it exists because an empty text box has no notation for
anyone to read off. Bare characters commit to nothing, being identical in all
three, which is what `Surface.spelledDialect` records.

Markdown blocks are represented and printable but not yet parsed; the reader
covers inline constructs, which is what a slide's text content is.

### `slideblaster-tikz`

Depends on source and syntax. It is the executable Slice 1 reader/editor for the
exact grammar in `docs/specs/slice1-tikz-subset.md`.

- public facade, document, diagnostic, model, render-plan, and edit modules;
- `NodeContent` interprets a node's content through `slideblaster-syntax`;
- `TikZ.Adapter` — admits the bounded source into generic Document plus common
  Canvas/Presentation and applies a common move through the verified inverse;
- private lossless CST/parser/decimal/projection implementation;
- exact recovery, one verified node-move transaction, and one verified content
  style transaction.

Both edit transactions have the same shape: the change reaches the source only
through recorded provenance, and is accepted only after the patched source is
reparsed and found to mean what was asked for. They differ in what "means" is. A
move compares pictures. A style edit compares the runs a renderer would draw,
because dividing a text construct to style half of it yields a tree that prints
identically without being equal as a tree.

Its small private CST/model types remain a format-owned adapter seam, not a
second product model. The adapter maps the admitted subset into the common model
without granting the browser source authority.

### `slideblaster-deck`

Portable deck package depending only on shared semantic/source packages.
`SlideBlaster.Deck.Container` and `.Frontmatter` find the exact spans of a
`*.slideBlaster.md` deck, `.Markdown` derives the document (presentation, slide
view, provenance, diagnostics) through the flow lowering in
`SlideBlaster.Canvas.Flow`, and `.Edit` offers the verified writers (new,
duplicate, delete, move, set id); see `docs/specs/slideblaster-md-alpha.md`.
`SlideBlaster.Deck` still owns the provisional `.slide` trial (lossless parent
CST, verified direct-coordinate edits, minimal slide insertion) until the product
runtime migrates; see `docs/specs/str-007-implicit-canvas-slide-trial.md`.

### `slideblaster-engine`

Depends on source, TikZ, and the common Document/Canvas/Presentation/Render
packages.

- inspection and mechanical exact replacement;
- bounded TikZ analysis and verified node movement;
- `Engine.CommonTikz` — lowers the admitted common picture to the bounded,
  resource-free common Render plan used by Product/2;
- no persistence or target effects.

### `slideblaster-protocol`

The package retains the existing engine, host, and frozen Product/1 wire
boundaries. Product/2 no longer imports or owns product composition.

- `Protocol.Types` / `Codec` / `Run` / `Render` / `Version` — versioned engine
  commands and results.
- `Protocol.Host` — versioned Wasm-to-browser host request/response envelope.
- `Protocol.ProductV2` — closed composition-neutral Product/2 request types,
  exact-key JSON decoder, stable source-redacted errors, and response envelope.
  Its vocabulary includes raw pointer facts, bounded view commands,
  `activate_node`, and stable-identity `select_slide`; workspace navigator items
  carry closed static audience/optional-notes plans for every frame.

`Protocol.Product` (`slideblaster.product/1`) is frozen compatibility behavior.
Product/2 is the active packaged-browser contract; broader app/render/export
commands must still be added deliberately without moving policy into the host.

### `slideblaster-product-runtime`

Depends on protocol plus App, Engine, Deck, and the common semantic/render
models. It is pure and shared by native GHC and GHC Wasm.

- `SlideBlaster.Product.Runtime` — public facade.
- `Product.Runtime.ProductV2` — the long-lived Product/2 state, exact
  source/history/lease authority, App interaction reducer composition,
  provisional deck/TikZ verified inverse, multi-surface common render
  projection, normal-snap-to-exact-FreeDrag inverse fallback,
  snapping/stable-frame navigation policy, deterministic New Slide, and
  protocol dispatch.

Keyboard node activation selects an admitted semantic node and emits the closed
`focus_node` action without changing source revision or history. Keyboard move
commands are deliberately absent. Codec/shape laws remain in protocol tests;
state-machine/source-authority laws are owned by this package's tests.

## Target adapters and compositions

### Native adapter

`slideblaster-adapter-native` uses ordinary Haskell libraries:

- `Native.FileSystem` — load and best-effort conditional save via
  `bytestring`, `directory`, and `filepath`;
- `Native.Git` — structured argument-array Git process operations;
- `Native.Port` — shared storage/Git/clock/log interpreters plus explicit
  absence for capabilities the CLI cannot honestly execute;
- `Native` — facade.

There is no glibc or `renameat2` FFI. Conditional save re-reads expected bytes,
writes a temporary sibling, copies portable permissions, and renames; it
honestly documents the remaining recheck-to-rename race instead of claiming
atomic compare-and-exchange.

### Web adapter

`slideblaster-adapter-web` depends on protocol:

- `Web.HostCall` — asynchronous correlated JSFFI boundary;
- `Web.Storage`, `Web.Measure`, `Web.Log` — typed current host wrappers;
- `Web.Port` — bridge from the supported host operations to shared ports;
- `Web.String` — explicit Haskell/JavaScript string conversion;
- `Web` — facade.

The current web host can provide shared logging plus a read/list-only storage
subset. Conditional exact-byte writes, Git, presenter, export, compile, and
clock remain explicitly unavailable. Its legacy plain-text measurement call is
also unavailable through the shared port because it cannot honor structured
`RenderContent` and exact embedded font resources.

### CLI

`slideblaster-cli` composes source, engine, protocol, and the native adapter. It
currently exposes version, inspect, exact replace, bounded TikZ analyze, and
verified TikZ move. Writes are explicit; no-op edits do not touch storage.

### Wasm reactor and browser host

`slideblaster-web-wasm` exports `sb_start`, the retained engine/Product/1
exports, and `sb_product_v2_dispatch`. Its `ProductV2` adapter stores one
long-lived `slideblaster-product-runtime` state in an `MVar` and forces the
successor state and strict response within `modifyMVar`; the static JSFFI export
and `Main` composition remain unchanged. `hosts/web`:

- initializes the real GHC-Wasm reactor with packaged WASI support;
- actively mounts `slideblaster.product/2` through `main.js`;
- validates the closed Product/2 workspace/render/gesture schema before DOM use;
- paints every Haskell-projected frame as a vertical thumbnail and continuous
  audience/notes row, while only the active acknowledged audience is writable;
- forwards stable-frame selection and finite pointer samples to Haskell, paints
  returned snap/free previews, and contains no source/navigation/edit policy;
- admits source drafts on blur or Ctrl+Enter with dispatch-generation fencing;
- interprets the versioned browser capability envelope.

The active Product/2 host modules are `src/protocol/product-v2.js`,
`src/product-v2-policy.js`, and `src/ui/product-v2-renderer.js`; their focused
Node tests and real-Chrome smoke are under `hosts/web/test/`. JavaScript remains
an effect, event, validation, and DOM interpreter. The retained Product/1 export
and renderer are frozen compatibility surfaces and are inactive in the packaged
host; removal requires separate product-owner approval.

## Local development

The one supported browser entrypoint remains:

```sh
make dev
```

It builds the Wasm reactor, packages the web artifact, and serves it on port
`4173`. Override the port with `make dev PORT=4198`.

Repository control-plane authority and session records are described in `.META/README.md`.
Use `docs/runbooks/development.md` and `docs/runbooks/worktrees.md` for normal
work. Completed sessions integrate only to `dev`; the product-owner-only
versioned promotion of `dev` to `main` is in `docs/runbooks/release.md`.

## Contract index

- 0.2.0-alpha build design (accepted): `docs/architecture/alpha.md`.
- Product types and ownership: `docs/architecture/product-model.md`.
- Workspace layout and reducer semantics: `docs/architecture/app-semantics.md`.
- Feature-to-module coverage: `docs/architecture/capability-map.md`.
- Current executable slices: `docs/architecture/vertical-slices.md`.
- Canvas: `docs/specs/vs-canvas-authoring.md`.
- Shape catalog: `docs/specs/vs-shape-catalog.md`.
- Presenter/animation: `docs/specs/vs-presenter-animation.md`.
- Export: `docs/specs/vs-export.md`.
- App/history/leases: `docs/specs/vs-app-state.md`.
- Measurement/layout/render: `docs/specs/vs-render.md`.
