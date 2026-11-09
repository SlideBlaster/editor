---
status: accepted
updated: 2026-07-27
---

# Application layout and semantics

This document defines the browser product as a state machine around the shared
Haskell model. It separates visual layout, semantic state, source authority, and
host effects so the web host does not become a second application.

## Workspace layout

The desktop-width editor has stable regions:

```text
+--------------------------------------------------------------------------+
| identity | view | undo/redo | insert | format | Present | Export | status |
+----------+---------------+-------------+------------------------+----------+
| Files    | Source        | Navigator   | continuous deck        | Shapes   |
| project  | exact source  | carousel    | slide | notes sidecar  | catalog  |
| + Git    | diagnostics   | thumbnails  | slide | notes sidecar  | search   |
|          |               |             | ...                    |          |
+----------+---------------+-------------+------------------------+----------+
                                      [properties] [step HUD] [zoom controls]
```

- The deck is one continuous vertical editing surface. Every slide is mounted
  and editable; the active slide follows the greatest visible area.
- The navigator is a vertical carousel between source and deck. Selection and
  keyboard focus are distinct. New Slide inserts after the active slide;
  reorder and delete are source-history transactions, and the last slide cannot
  be deleted.
- Notes are a second canvas column on the same row. Missing notes show Add
  notes. Audience and notes scroll and preview steps together.
- Files, Source, and Shapes can be collapsed without unmounting their retained
  state. Properties are selection-sensitive. Step and zoom controls are
  canvas-docked, not extra top-bar groups.
- Shapes/search read creation presets from `slideblaster-catalog`. Choosing a
  row consumes its generic outline, property patch, initial size, and content
  into an ordinary node. The semantic deck does not retain a catalog row ID,
  origin, category, or draw.io-specific object variant.
- At narrow widths the regions stack in reading order without changing the
  document, active slide, selection, or tool.

This is the product layout. Host HTML/CSS may realize it responsively, but host
layout never changes the semantic address or command meaning.

## App model

The Haskell app package owns the durable in-session choices:

```haskell
data AppModel syntax key = AppModel
  { documentSession :: DocumentSession syntax
  , selection       :: Selection
  , tool            :: Tool
  , canvasView      :: CanvasView
  , capabilities    :: CapabilitySet
  , presenter       :: Maybe PresenterState
  , exportJobs      :: ExportJobs
  }
```

DOM elements, JavaScript callbacks, file handles, and browser object URLs are
not part of `AppModel`. Workspace handles and target effects enter through
runtime ports rather than being hidden in this pure state.

### Document session

Three states are tracked separately:

1. `SourceDraft`: exact bytes currently in the source editor, possibly awaiting
   Haskell admission.
2. accepted `DocumentSnapshot`: newest revision-fenced bytes, CST,
   diagnostics, and optional semantics.
3. maps of issued `PaintRequest`s and `PaintedCanvasLease` authorities, keyed
   by exact audience/notes `SurfaceAddress`.

Every request is fenced by session, revision, render ticket, and surface. Any
draft change clears pending requests and immediately revokes all old canvas
leases. An invalid accepted snapshot stays saveable and undoable while each
last-good surface remains visible but inert. Ready analysis issues a distinct
request for every audience surface and every present notes surface in
presentation order. A delayed or unsolicited paint can acquire authority only
by echoing the exact still-pending request and a plan whose revision, ticket,
and surface match it.

### History

History stores exact source snapshots, not semantic objects or DOM. Direct
source authorship and verified canvas/property/deck/theme edits enter the same
branching source history. A no-op creates no entry. Undo and redo restore bytes
under a fresh monotonic revision, reparse, and reacquire a canvas lease; they do
not revive stale provenance or render objects.

Cursor, source selection, scroll, panel visibility, canvas selection, and
presenter cursor are view state and do not enter source history.

Which part of the canvas is visible is presentation state owned by the host
viewport. Zoom, fit, and pan are therefore not application commands and cross no
protocol boundary.

## Commands

Commands are closed Haskell values grouped by product meaning:

- project: new/open/save/import/export workspace, Git status/commit/push;
- history: undo/redo;
- deck: select, insert-after-active, delete, reorder;
- source: replace draft/admit source, go to diagnostic;
- canvas: select, insert shape/text/connector, move, resize, bind, detach,
  reorder, delete, edit content;
- properties: set node, connector, overlay, animation, or frame property;
- theme: open editor, preview, apply, save/import;
- view: panel visibility, step preview;
- presentation: start/stop, open audience, next/back/home/end;
- export: analyze target, confirm warnings, generate/cancel/download/print.

`commandAvailability` is pure and returns either an enabled command contract or
a typed disabled reason. Examples:

- an addressed canvas/node/connector command requires the current painted lease
  for that exact surface;
- Save requires storage but permits syntax-only source;
- Git commit/push require Git capability plus diagnostics accepted for the
  exact current source; pending/stale diagnostics and hard errors block;
- Present requires a current non-empty semantic deck plus window, channel, and
  clock capabilities;
- PDF requires print/PDF capability;
- LaTeX/HTML require semantic readiness and may require user confirmation for
  lossy diagnostics;
- theme and object commands require the correctly addressed selection.

The UI renders disabled reasons rather than hiding important commands or
letting JavaScript rediscover policy.

## Tools and selection

```haskell
data Tool
  = SelectTool
  | TextTool
  | ShapeTool ShapePresetId
  | ConnectorTool ConnectorPreset
  | PanTool

data Selection
  = NoSelection
  | ObjectSelection SurfaceAddress (NonEmpty ObjectId)
  | ConnectorHandleSelection SurfaceAddress ConnectorId HandleId
  | ContentSelection SurfaceAddress NodeId ContentRange
  | FrameSelection FrameId
```

Pointer motion creates previews through the same semantic operation used for
commit. In the active bounded Product/2 path, begin captures the exact displayed
paint fence, selected node, and source revision under a monotonic Haskell gesture
ID. Preview stores the common `MoveElement`, exact `App.CanvasEditRequest`, and
format-owned verified/no-op TikZ result. Commit sends only that ID and consumes
the stored values; a rejected replacement preview cancels both gesture and
preview. One pointer release creates at most one source-history transaction.

Selection is cleared or narrowed when source changes invalidate its semantic
address. It is never used as source provenance.

## Reducer and effects

The application boundary is Elm-like without committing to a framework:

```haskell
update :: AppEvent -> AppModel syntax -> Update syntax

data Update syntax = Update
  { nextModel :: AppModel syntax
  , effects   :: [AppEffect]
  }
```

`AppEvent` contains typed user intents and versioned effect completions.
`AppEffect` requests semantic work such as analysis, measure/render, and
presenter projection. Runtime ports separately request storage, Git,
measurement, clock, window/channel, download/print/archive, compile, and
structured logging. Every asynchronous request carries the full correlation
key required by its owner; stale completions are rejected by Haskell state
transition rules.

The browser host:

- mounts validated render plans and reports pointer/keyboard/measurement events;
- invokes browser capabilities requested by Wasm;
- owns ephemeral DOM focus, caret, native dialogs, Blob URLs, and popup handles;
- never parses source, mutates a semantic presentation, grants a stale lease, or
  classifies export loss.

## Source-edit loop

```text
textarea bytes change
  -> clear pending paints and revoke every surface lease
  -> revision-fenced source replacement
  -> exact source history entry
  -> parse/elaborate
     | ready       -> request measurement/layout/render
     | syntax-only -> retain inert last-good canvas + diagnostics
  -> paint only after exact issued request correlation
```

Source input remains responsive while parsing. Coalescing policy can reduce
history noise, but it cannot merge generated semantic transactions or let a
stale result overwrite newer bytes.

## Canvas-edit loop

```text
pointer/property/deck action
  -> typed EditIntent at current canvas lease
  -> pure intended before/after semantic transaction
  -> provenance-guided CandidatePatch
  -> exact source revision + expected-byte checks
  -> apply candidate
  -> full reparse + elaboration
  -> semantic equality
     | equal    -> format-owned verified successor -> App mechanical commit
                 -> source history -> render loop
     | failure  -> atomic typed diagnostic; model/source/history unchanged
```

`App.CanvasEdit.commitCanvasSuccessor` checks exact base/current bytes and
revision, one-step changed successor, writable lease, and one history transition.
It is not itself semantic verification; the format adapter must supply the
reparsed successor whose common semantics match the stored operation.

Snap guides, resize handles, connector handles, and animation previews are
transient. The committed operation is expressed in semantic coordinates and
properties.

## Measure, layout, and render loop

```text
semantic non-empty Presentation/Scene + theme + each surface/step
  -> issue PaintRequest(session, revision, ticket, surface)
  -> lower authored content, theme, catalog references, and geometry
     to dialect-free direct render values
  -> Haskell emits content measurement requests
     with the exact embedded resource manifest
  -> a capable host measures structured content with declared
     font/style/width constraints and those exact font bytes
  -> correlated measurements return
  -> Haskell resolves boxes, connectors, furniture, overlays, animations
  -> resource-closed RenderPlan with direct content/style/geometry
  -> browser validates and paints layered DOM/SVG
  -> browser echoes PaintRequest with the completed plan
  -> reducer consumes that still-pending request
  -> only the addressed surface lease becomes writable
```

Measurement results are inputs, not authority. A resize, font load, theme
change, or aspect-ratio change invalidates the relevant layout key without
changing authored source. A host that cannot interpret structured
`RenderContent` or install/honor the exact manifest fonts reports measurement
unavailable; it must not flatten content or silently substitute fonts and
claim authoritative layout.

## Presenter loop

Presenting takes an immutable semantic/render snapshot. Editing can continue in
the main window only by creating a new presentation snapshot; it does not
silently alter a running show.

```text
non-empty Presentation of coherent Scenes -> beats -> PresenterSnapshot
                       -> console window
                       -> audience window

key/click in either window
  -> versioned cursor command
  -> Haskell presenter transition
  -> audience + console projections for the same cursor
```

The audience shows current slide/step only. The console shows notes capped to
that audience step, next beat, counters, and elapsed time. Popup handles and the
transport channel are host capabilities; cursor bounds and projections are
Haskell semantics.

## Export workflow

```text
ExportRequest target + LossPolicy + exact semantic revision
  -> compatibility analysis
     | fatal -> ExportFailed diagnostics
     | lossy -> require confirmation or fail by policy
     | clean -> continue
  -> deterministic pure plan/artifacts
  -> target capability execution, when required
  -> ExportReport artifacts + warnings + capability failures
```

Standalone HTML and LaTeX generation are deterministic pure writers followed
by download/storage. Rendered PDF is a print/PDF capability over beat pages; the
core never invents PDF bytes. Workspace zip is a storage traversal capability
with a pure deterministic archive codec.

The LaTeX projection preserves point pauses as Beamer `\pause` commands and
emits each notes scene inside the owning frame's `\note`. Timed animation still
cannot be expressed as source motion there: compatibility diagnostics are
scoped independently to audience and notes timelines and follow the selected
loss policy.

An export request is revision-fenced. A completion for an older revision may be
downloaded as an explicitly named snapshot but cannot be reported as the
current document without user confirmation.

## Browser and local compositions

Both compositions use the same Haskell document, canvas, presentation, export,
and app packages.

| Capability                | Browser adapter                                                   | Native adapter                                        |
| ------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------- |
| Storage                   | current shared adapter supplies list/read only; conditional exact-byte write remains unavailable | ordinary Haskell libraries supply read/list and best-effort expected-byte replacement |
| Git                       | explicitly unavailable until packaged browser Git is wired        | argument-array process adapter currently supplies version/status |
| Measurement               | explicitly unavailable until DOM host accepts structured content and exact resources | explicitly unavailable until a native measurer is selected |
| Presenter windows/channel | explicitly unavailable in the current host                        | unavailable in the CLI                                |
| Download/print/archive    | explicit shared-port absence until target interpreters land       | explicit shared-port absence until target interpreters land |
| Compile                   | explicit shared-port absence until a packaged worker lands        | explicit shared-port absence until a local interpreter is selected |
| Clock/log                 | structured log supplied; monotonic clock not yet bridged           | monotonic `base` clock and structured stderr log supplied |

Capability absence is typed and reflected in command availability. It does not
fork the semantic model or invite a JavaScript fallback implementation. The
packaged browser currently mounts only the bounded Product/2 source/canvas path
over this App authority; the full workspace capability table remains incremental.
Product/1 is retained as frozen compatibility behavior and is not mounted.
