---
status: accepted
updated: 2026-07-28
---

# Product capability ownership and implementation map

This map prevents “parity” from meaning whichever controls happen to be visible.
Every original SlideBlaster capability has a semantic owner, a target
composition point, and an explicit status.

Status vocabulary:

- **executable** — the named Haskell path has focused laws;
- **represented** — common types preserve the concept but its end-to-end path is
  not implemented;
- **bounded** — executable only for a declared source/feature subset;
- **host-existing** — JavaScript performs a target capability effect, while
  Haskell remains the semantic owner;
- **contract-only** — architecture/specification fixes the destination and
  failure behavior;
- **decision-needed** — product syntax or semantics still require the user's
  decision.

No row marked represented or contract-only is a parity claim.

## Workspace and application shell

| Capability | Semantic owner | Current implementation | Browser/native composition | Next executable slice |
| --- | --- | --- | --- | --- |
| Product layout: Files, Source, Navigator, continuous deck, notes column, Shapes, Properties, HUD/zoom | `docs/architecture/app-semantics.md`; `App.Selection`; `App.Navigation` | contract-only broad layout; bounded source/rail/continuous-deck/zoom executable | Product/2 host mounts compact commands, ~26rem source, faithful vertical thumbnails at desktop and stacked narrow widths, every static audience/notes card, a browser-owned zoom/pan viewport, and quiet status; Files/Shapes/Properties remain absent | add only capabilities backed by shared semantics and real adapters |
| Project open/new/save | `App.Command`; `Ports.Workspace` | command policy and shared storage contract executable; native conditional replacement executable | browser list/read subset only, not a writable working copy | project model plus browser exact conditional writes |
| Source draft and invalid source | `Source`, `Document`, `App.Model` | exact bytes, syntax-only state, stale analysis executable | Product/2 replace-source path is active; dirty browser draft keeps canvas inert | broader source-pane admission and diagnostics |
| Undo/redo/branching/no-op | `App.History`, `App.Update` | executable | bounded Product/2 undo/redo and no-op are active | expose broader app commands |
| Command enablement/disabled reasons | `App.Command` | executable across all command groups | not browser-wired | render stable disabled controls from Haskell result |
| Pane visibility, selection, tool, zoom | `App.Selection` | represented; validated zoom/ranges/IDs | current host owns separate pane state | app event/protocol wiring |

## Presentation and deck

| Capability | Semantic owner | Current implementation | Browser/native composition | Next executable slice |
| --- | --- | --- | --- | --- |
| Ordered slides, stable identity, aspect ratio, title | `Presentation.Scene`, `Presentation.Model`, `App.Navigation`, provisional `Deck` adapter | coherent presentation plus bounded lossless three-slide admission/navigation executable | Product/2 projects all stable IDs/titles/static plans; thumbnail click and arrows return to Haskell, which owns active selection | permanent format decision and broader deck operations |
| Insert after active, delete, reorder | provisional `Deck` projector plus `App.History`; broader commands remain `App.Command` | deterministic revision-fenced New Slide and exact undo/redo executable; delete/reorder only represented | top-bar `+ Slide` and rail `+ New slide` share the same Haskell request; delete/reorder absent | decide permanent syntax, then add verified delete/reorder |
| Per-slide rotation | `Presentation.Model` | represented and normalized | not rendered or written | decision-needed coordinate/source contract |
| Audience and notes sidecars | `Presentation.Model`, `Presentation.Address` | executable identity distinction and notes cap | no notes canvas | lower both surfaces through shared render path |
| Overlay builds and fixed geometry | `Canvas.Overlay`, `Presentation.Overlay` | executable visibility/count/beat laws | no general overlay preview | renderer lowering + HUD |
| Presenter next/back/home/end | `Presentation.Presenter` | executable total zipper | windows/channel absent | presenter capability bridge |
| Presenter console: notes, next, counters, timer origin | `Presentation.Presenter` | executable synchronized projections | windows/clock absent | audience/console host windows |
| Remote control, laser, annotation, handouts | future presenter extensions | contract-only/roadmap | absent | separate user-directed slice |

## Canvas, geometry, and editing

| Capability | Semantic owner | Current implementation | Browser/native composition | Next executable slice |
| --- | --- | --- | --- | --- |
| Ordered canvas objects and z barriers | `Canvas.Object` | executable validation/reorder laws; provisional deck scanner admits repeated nodes/simple paths | Product/2 common plan renders all admitted nodes and straight connectors on the active surface, including empty new slides | general picture lowering |
| Node identity, placement, size, transform/style | `Canvas.Identifier`, `Placement`, `Property` | core property precedence executable; unsupported trial options retained read-only | direct-coordinate trial nodes with recognized retained anchors are writable; relative/expanded/ambiguous placements remain read-only | complete property vocabulary then source adapters |
| Absolute/relative placement | `Canvas.Placement`, `Render.Layout` | executable measured placement graph | direct coordinates render; recognized direct anchors have a verified inverse in this trial | browser measure/layout slice |
| Selection/move/resize/delete/reorder | `Canvas.Edit`, `App.Selection`, `App.CanvasEdit`, provisional `Deck` projector | typed intents plus lease-fenced exact parent-lifted move executable | Product/2 selects/moves active direct-coordinate nodes under their retained anchor; other operations absent | add format-owned verified projectors |
| Binding/snapping/guides/Alt bypass | `Canvas.Snap` | executable binding > alignment > spacing > grid | Product/2 resolves in Haskell; unprojectable normal snap retries exact pointer as guide-free FreeDrag without rounding; explicit Alt remains separate | broaden objects and measured geometry |
| Connector anchors/path/ports | `Canvas.Connector` | executable straight/orthogonal/cubic resolution | no general connector authoring | connector render/edit lowering |
| Groups/containers | `Canvas.Object` | membership represented; containment deliberately absent | absent | decision and verified group semantics |
| Imported stencil geometry and resource bytes | `Canvas.Outline`, `Catalog`, `Render.Resource` | an ordinary node may retain an unresolved outline reference; catalog definitions and attributed source data stay outside Canvas; render resources carry exact bytes | generated pack exists, but no live draw.io checkout/submodule is accepted | resolve selected catalog entries into direct geometry and a closed resource manifest |
| Accessibility/hit testing | `Render.Plan`, `Presentation.Address` | labelled/decorative and semantic interaction represented | not mounted | layered DOM renderer |
| Provenance-guided canvas commit | `Document.Provenance`, `Canvas.Edit`, `App.CanvasEdit`, `TikZ.Adapter`, provisional `Deck` adapter | child operation -> verified child successor -> exact parent-span lift -> full parent reparse -> exact history executable | active Product/2 direct-coordinate move retains its recognized authored anchor and changes only verified parent coordinate bytes; stale/surface/projection failure is atomic | extend admitted syntax and operations |

## Shapes and properties

| Capability | Semantic owner | Current implementation | Browser/native composition | Next executable slice |
| --- | --- | --- | --- | --- |
| Generic outline geometry | `Canvas.Outline` | rectangle/rounded/ellipse/arc/polygon/path/compound plus unresolved stencil/custom/unsupported references represented; no catalog rows or search metadata | target renderer absent | generic SVG/HTML translator |
| Curated P0 palette | `Catalog.Curated`; `vs-shape-catalog.md` | 15 catalog-owned creation presets; insertion consumes each into an ordinary node | no palette | lazy browser catalog panel |
| Curated P1 palette | `Catalog`; `vs-shape-catalog.md` | inventory/contract only; no concrete rows in Canvas | no palette | add executable catalog rows by vertical slice |
| Long-tail shapes | `Catalog.DrawIO` plus source/import tooling | 2,257 attributed generated P2 rows independently validated | exact upstream commit, included paths, and license/provenance manifest await user decision; no live submodule | choose and pin source, then resolve selected rows into direct geometry/resources |
| Fill/stroke/width/dash/opacity/corners | `Canvas.Property`, shape outline | typed fill/stroke/dash/opacity/corner treatment represented | no property panel | property UI and render lowering |
| Typography/alignment/wrapping/line spacing | `Canvas.Property` | represented and resolved | no inline editor/measurement composition | content measurement + property UI |
| Gradient, shadow, scale, flip | `Canvas.Property` | typed values represented; lowering remains target capability work | absent | property UI and render lowering |
| Theme role precedence | `Canvas.Theme` | executable fallback < theme < role < preset patch < overrides < explicit | no theme UI | theme source reader/editor |

## Mixed-language content

| Capability | Semantic owner | Current implementation | Browser/native composition | Next executable slice |
| --- | --- | --- | --- | --- |
| Recursive Markdown/LaTeX/HTML mixing | `Canvas.Content` | represented with provenance on every construct | no common reader/editor | content reader + renderer slice |
| Text marks, links, code, lists, math, images | `Canvas.Content` | represented; opaque math preserved | no inline editor | one verified inline edit |
| Overlay content | `Canvas.Content`, `Canvas.Overlay` | represented and visibility executable | no content renderer | maximal-layout content lowering |
| Columns/matrices/tables | recursive container types | represented generically; structured cells/operations contract-only | absent | structured table/column types and source projection |
| Citations/bibliography | product model | contract-only | absent | resolved/unresolved citation state package |
| Includes/assets | `Canvas.Content` | reference represented; loading/failed derived states contract-only | absent | storage-backed include resolver |
| Unsupported/opaque source | `Canvas.Content`, `Document.Provenance` | represented, diagnosed/read-only contract | bounded TikZ reader executable | format-specific CST adapters |
| Live Markdown list shortcut | future inline editor | contract-only | original strict expected-red | inline edit state-machine slice |

## Theme

| Capability | Semantic owner | Current implementation | Browser/native composition | Next executable slice |
| --- | --- | --- | --- | --- |
| Palette, type scale, semantic roles | `Canvas.Theme` | represented; role resolution executable | no theme editor | structured JSON reader/writer |
| Master regions and snap guides | `Canvas.Theme`, `Canvas.Snap` | represented; explicit axis references executable | no theme studio | guide generation from relative regions |
| Safe area and page/logo/header/footer furniture | `Canvas.Theme`, `Render.Plan` | represented | furniture layout/render/export absent | one furniture item across editor/presenter/HTML |
| Save/import/load theme | `App.Command`, storage port | commands represented | current original Save is incomplete on load | source-backed theme document slice |
| Shared accessible popup surface | browser UI contract | contract-only | absent | reusable popup host component |

## Animation

| Capability | Semantic owner | Current implementation | Browser/native composition | Next executable slice |
| --- | --- | --- | --- | --- |
| Entrance/emphasis/exit/motion/transition | `Presentation.Animation` | represented and classified | playback absent | Web Animations translator |
| Opacity/translation/rotation/scale/fill/stroke tracks | `Presentation.Animation` | typed keyframes, validation, endpoint sampling executable | playback absent | interpolation/playback |
| Motion paths | `Presentation.Animation` | line/cubic paths and endpoint sampling executable | playback absent | resolved-coordinate interpolation |
| Frame/step/with/after triggers | `Presentation.Animation` | ordering/scheduling failures executable | host scheduler absent | beat-local scheduler |
| Timing/easing/repeat/fill | `Presentation.Animation` | represented and validated | host clock/player absent | player conformance tests |
| Playback direction and direct click trigger | product model | contract-only in current package | absent | additive semantic type before player |
| Reduced motion | `Presentation.Animation` | executable disposition | host preference query absent | capability + playback application |
| Source syntax/projection | future format adapters | decision-needed | absent | user chooses authored syntax |

## Layout and rendering

| Capability | Semantic owner | Current implementation | Browser/native composition | Next executable slice |
| --- | --- | --- | --- | --- |
| Correlated text/content measurement | `Render.Measurement`, `Ports.Measurement` | already-lowered structured content, positive width, exact resource manifest, and exact result coverage executable | legacy DOM measurer is explicitly unavailable through the shared port because it cannot honor the contract | implement structured DOM measurement with embedded-font readiness |
| Relative dependency layout | `Render.Layout` | node kernel executable | not mounted | whole picture fold |
| Connector resolution | `Canvas.Connector` + resolved node map | executable | not mounted | connector primitives |
| Furniture/asset/group layout | render package destinations | represented/contract-only | absent | incremental lowerers |
| Closed layered render plan | `Render.Content`, `Style`, `Geometry`, `Resource`, `Plan` | dialect-free content, direct style/geometry, exact embedded resources, layer/identity/interaction/resource/animation validation executable | Product/2 validates/paints a bounded common rectangle + connector plan | broaden common lowering and structured measurement |
| Continuous deck/thumbnails/presenter/export reuse | presentation + render architecture + `App.Navigation` | bounded all-slide audience/notes workspace projection executable; presenter/export reuse remains contract-only | browser paints three vertical thumbnails and every audience/notes row; only Haskell-active acknowledged audience is writable | one beat rendered across editor/presenter/export surfaces |
| Stale or unsolicited paint fencing | `App.Lease`, `App.Model` | one exact issued `PaintRequest` and authority per `SurfaceAddress`; completion must match session/revision/ticket/surface | active Product/2 echoes exact fences and invalidates gestures on authority change | generalize beyond bounded surface |

## Export and interchange

| Capability | Semantic owner | Current implementation | Browser/native composition | Next executable slice |
| --- | --- | --- | --- | --- |
| Standalone self-contained HTML | `SlideBlaster.Export`, `Internal.Html` | deterministic writer executable from rendered beats | download not wired | app export effect + Blob/native write |
| PDF | `SlideBlaster.Export` | compatibility analysis and print plan executable; core intentionally emits no fake PDF bytes | browser print/native PDF capability absent | execute/report print capability |
| LaTeX project/source | `Internal.Latex`, `LatexProject` | deterministic mixed-content writer, Beamer pauses, speaker-note scenes, and scoped audience/notes animation diagnostics executable | download/compiler not wired | fixtures + capability execution |
| Animation fidelity warnings/failure | export diagnostics + `LossPolicy` | executable classification and reject/permit policy | UI not wired | warning review/confirmation surface |
| Workspace ZIP | `Internal.Workspace` | safe entry validation and archive plan executable | compressor not wired | deterministic archive capability |
| Standalone `.tikz` figure | `Picture` semantic root + bounded TikZ reader | admitted node/connector promote through generic Document and common Canvas/Presentation | active bounded Product/2 workbench | broaden the admitted TikZ/common subset |
| Compiled view-only figure | compile port | contract-only | original SwiftLaTeX path not migrated | packaged Wasm compiler worker |
| Beamer authored source | `slice2-beamer-subset.md` | proposed exact grammar only | absent | user acceptance before implementation |

## Runtime, files, and Git

| Capability | Semantic owner | Current implementation | Browser/native composition | Next executable slice |
| --- | --- | --- | --- | --- |
| Filesystem storage | `Ports.Workspace` + native/web adapters | shared exact-byte conditional-write contract; native read/list/replace executable | web read/list subset provided; exact conditional write explicitly unavailable | browser binary working-copy interpreter |
| Git status/commit/push | `Ports.Git` + native adapter + `App.Command` | closed structured request/response vocabulary; native version/status subset; stale/pending or hard diagnostics block commit/push | browser Git explicitly unavailable | packaged browser Git interpreter and remaining native operations |
| Measurement | `Render.Measurement` + `Ports.Measurement` | shared batch/result contract executable | native has no selected measurer; web legacy text measurer fails closed | structured DOM interpreter |
| Presenter windows/channel | `Ports.Presenter` | window handles and sequenced navigation transport represented without owning deck/cursor semantics | both current adapters explicitly unavailable | browser window/channel interpreter |
| Download/print/archive/compiler | `Ports.Export`, `Ports.Compile` | typed execution records over already-planned artifacts/jobs executable | current adapters explicitly unavailable | target interpreters, one vertical slice at a time |
| Clock/log | `Ports.Clock`, `Ports.Log` | monotonic origin and payload-safe structured log contracts executable | native supplies both; web supplies logging and reports clock unavailable | browser monotonic clock |
| Native implementation rule | native adapter | ordinary Haskell libraries; no glibc/FFI path | native focused tests pass | keep target-only dependencies outside shared packages |

## Deliberate non-claims

The semantic backbone is now broad enough to prevent one-off feature models,
but browser parity remains incomplete. In particular:

- Product/2 serializes only the bounded common node/connector and App workspace subset;
- the general layered renderer is not mounted beyond that bounded common plan;
- source readers/projectors exist only for the bounded TikZ path;
- several advanced property/content/animation concepts are still contract-only
  and are named above;
- presenter windows and export effects are not executed; and
- collaboration/service work is outside the current local/web core.

These are explicit vertical slices with named module homes. None requires
changing source authority, inventing JavaScript semantics, or rebuilding the
product model.
