# SB2-20260727-001 slices

## Dependency graph

```text
B0 bootstrap/register/worktree/baseline (orchestrator)
  -> R1 legacy oracle (legacy analyst, read-only) ----+
  -> R2 current architecture (architecture analyst) --+-> D1 design/gates
                                                        -> G1 ownership DAG
G1 -> I1 shared Haskell path --------+
   -> I2 protocol/Wasm/browser -------+-> V1 independent verification
                                       -> R3 adversarial exact-diff review
                                       -> G2 integration/docs/demo
                                       -> P1 product-owner gates/integration/close
```

| Node | Role/owner | Dependencies | Owned or read-only paths | Artifact | Acceptance | Status |
| --- | --- | --- | --- | --- | --- | --- |
| B0 | orchestrator | none | session records/bus; product read-only | registered worktree + baseline | metadata/worktree valid, focused native tests and serve smoke pass | complete |
| R1 | legacy analyst | B0 | required `../knowledge`, `../design`, `../editor` paths read-only | legacy oracle research report | exact path/symbol observations, no mutation | complete |
| R2 | architecture analyst | B0 | current packages/apps/host/docs read-only | authority/value/gap map | symbols/tests, duplicate models, safe seam | complete |
| D1 | designer/planner | R1,R2 | research reports + session design records only | data flow/types/failures/alternatives/gates | implementable design; protocol gate identified | complete |
| G1 | orchestrator | D1 + resolved protocol gate | `BUS.md`, this file | disjoint file ownership DAG | one writer/file, cheapest checks | complete |
| I1 | Haskell implementer | G1 | assigned TikZ/App/Engine Haskell and tests | source→common model→app history→common render path | focused laws and native tests | complete |
| I2 | Browser/Wasm implementer | G1/I1 interfaces | assigned Protocol/web-wasm/hosts/web/test paths | real product/2 reactor/browser composition | protocol/host/Wasm/browser checks | complete |
| V1 | independent verifier | I1,I2 | entire diff read-only; verification evidence only | independent verification report | full feasible ladder; repaired gesture finding verified; baseline catalog failure classified | complete |
| R3 | adversarial reviewer | V1 | exact final diff read-only; report only | corruption/authority/atomicity review | all findings resolved or dissent retained | complete (`APPROVE WITH NOTES`) |
| G2 | integrator | R3 | manifests/current docs/knowledge/demo records | final wiring/docs/review unit | complete checks and exact demo | complete |
| P1 | product owner + orchestrator | G2 | review/session records; `dev` only after approval | observation/acceptance/review/integration/closure | every explicit gate separately recorded | active |

## Slice contracts

B0–D1 made no product mutations. Research confirmed the bounded deliberately
noncanonical named absolute node plus connector fixture is the thinnest honest
slice. The accepted internal design roots exact bytes, history, accepted generic
document, paint requests, and leases in `AppModel`; keeps bounded TikZ as a
private format reader/projector; uses common Canvas/Presentation/Render as the
only product semantic and paint vocabulary; and bypasses temporary
`LiveAuthoring`.

I1 admits exact source into the common model and commits a verified common
`MoveElement` through the existing TikZ inverse into exact history. Preview and
commit consume the same stored operation. I2 exposes the same state machine
through the product-owner-selected closed protocol and real reactor; the host
validates projections, paints, translates events, and invokes capabilities only.
V1/R3 are independent of implementation. G2 owns shared manifests and current
documentation only after implementation ownership is released.

## Stage 2 protocol gate

`slideblaster.product/1` is fixed to non-persistent `LiveAuthoring`, is not
mounted by the packaged browser, and its emitted workspace is wire-incompatible
with `product-renderer.js`. Redefining it would change a durable public boundary.
Options are additive `/1`, source-authoritative `slideblaster.product/2`, or a
separate `slideblaster.app/1`. The designer and architecture analyst recommend
`slideblaster.product/2`, freezing `/1` for compatibility and deferring deletion
to a separately approved migration. No product file assignment occurs until the
product owner records this decision.

## Verification ladder

1. Format/static checks.
2. Focused source locality, revision, projection, semantic, history, gesture, and lease laws.
3. Affected package tests and native integration.
4. Protocol codec/reactor and dependency-free host tests.
5. Wasm build and native/Wasm fixture conformance.
6. Real packaged browser E2E.
7. Complete `make dev` product-owner demonstration.

## Second-revision graph after product-owner rejection

```text
R4 legacy UX --------+
R5 format authority --+-> D2 orchestrator synthesis
R6 current interaction+
                           +-> I3 direct-drag reliability (host)
                           +-> I4 Haskell snapping preview (protocol)
I3 + I4 -> I5 browser schema/zoom/preview integration
format spelling gate -> I6 lossless Markdown deck + New Slide
I5 + I6 -> V2 independent verification -> R4 final review -> G3 docs/demo
```

| Node | Role/owner | Dependencies | Exclusive write scope | Artifact and acceptance | Status |
| --- | --- | --- | --- | --- | --- |
| R4 | legacy UX analyst | rejection | none; legacy read-only | executable original-product interaction evidence | complete |
| R5 | format analyst | rejection | none; legacy/current read-only | `.slideBlaster.md` syntax and conflict map | complete |
| R6 | current interaction analyst | rejection | none; current worktree read-only | manual-drag diagnosis and implementation map | complete |
| D2 | orchestrator | R4,R5,R6, STR-004 | session records only | reshaped one-slice design with explicit format gate | complete |
| I3 | host interaction implementer | D2 | Product/2 renderer, host orchestration, focused browser interaction tests | one-action unselected press-drag, click/no-op/cancel reliability | pending |
| I4 | Haskell snapping implementer | D2 | ProductV2 Haskell protocol and its focused Haskell test | Haskell-resolved snapping/free-drag preview and guides | pending |
| I5 | browser integration implementer | I3,I4 schema handoff | Product/2 JS codec/policy, zoom/preview UI tests; receives released host files only if wiring requires | validated guides, zoom-safe pointer conversion, preview rail foundation | pending |
| I6 | Markdown/deck implementer | accepted fence spelling | new lossless Markdown adapter/deck tests, then assigned app/protocol paths | exact `.slideBlaster.md`, two-slide deck, verified New Slide and undo | blocked on format spelling |
| V2 | independent verifier | I3-I6 applicable work | verification report only | cheapest-first native/Wasm/browser/product-owner-shaped checks | pending |
| R4-final | independent reviewer | V2 | review report only | source, stale/atomicity, interaction, accessibility, complexity audit | pending |
| G3 | integrator | R4-final | manifests, docs, roadmap, knowledge, session/demo records | reproducible local artifact and exact review unit | pending |

Ownership is exclusive while a node is active and may transfer only after an
explicit handoff. Legacy trees remain permanently read-only. The format gate is
narrow: accepted legacy prose conflicts between fenced info strings `tikz` and
`slide`, while executable fixtures and parsers overwhelmingly use `slide`.

### Architecture-correction nodes

| Node | Role/owner | Dependencies | Exclusive write scope | Acceptance | Status |
| --- | --- | --- | --- | --- | --- |
| I7-HS | Haskell interaction implementer | STR-005; I4 handoff | new App interaction module, App exports/manifest/tests, ProductV2 Haskell/tests | raw-event reducer owns gesture/zoom/navigator policy; native laws pass | active |
| I8-WEB | thin-host implementer | I7 schema freeze; interrupted I5 files | active Product/2 JS codec/policy/renderer/main/tests and necessary host markup/style | no semantic interaction state in JS; JSFFI browser smoke passes | blocked |
| V2A | independent boundary verifier | I7,I8 | evidence report only | adversarial grep/data-flow/runtime proof of Haskell ownership | pending |

I7 may replace or supersede unverified I4/I5 details where needed but must retain
the already-proven source, history, lease, stored-operation, and atomic-failure
laws. I8 receives ownership only after I7 explicitly releases the wire schema.

## STR-007 provisional implicit-canvas trial

| Node | Role/owner | Dependencies | Scope | Acceptance | Status |
| --- | --- | --- | --- | --- | --- |
| I11-DECK | sole deck writer | accepted STR-007 design and STR-005 boundary | portable deck parser/projector, App navigation, Product/2 runtime/protocol, host, manifests, tests, provisional docs | exact real fixture, three Haskell-owned slides, parent-lifted edit, deterministic New Slide/Undo, native+Wasm+Chrome | complete |

I11-DECK adds the explicitly provisional `slideblaster-deck` parent adapter;
each audience body is one implicit multi-node bounded TikZ canvas. It does not
promote `.slide` to a permanent format. Literal triple quotes inside raw bodies
remain unsupported/read-only in P0. Product/2 now opens the exact demo as
`opening`, `questions`, and `finish`; Haskell owns navigation, correlated paints,
active-only interaction, deterministic `slide-N` insertion, and coherent exact
Undo. JavaScript only validates, forwards surface-correlated facts, executes
host actions, and projects navigator/render state.

Verification evidence: affected native Deck/App/TikZ/Engine/ProductV2
protocol/runtime suites passed; host tests passed 16/16; the GHC-Wasm build
compiled and packaged the deck-backed reactor; installed Google Chrome passed
the exact demo, three previews, verified parent-lifted move+Undo, New Slide+exact
Undo/prior active restoration, stale rejection, and zero page/console errors.

## STR-008 drag fallback and legacy workspace grammar

| Node | Role/owner | Dependencies | Scope | Acceptance | Status |
| --- | --- | --- | --- | --- | --- |
| I12-UI-DRAG | sole STR-008 writer | STR-007 Product/2 runtime and two analyst findings | Product/2 snap/inverse boundary, closed all-slide/select-slide schema, host workspace/tests, current docs | real-demo natural no-Alt drag remains active; all-slide vertical rail/continuous deck; exact history/source race; native+Node+Wasm+Chrome | complete |

I12-UI-DRAG keeps normal snap first, then retries only an unprojectable relative
or exact non-terminating result at the unchanged pointer destination as
`FreeDrag`; fallback has no guides and still uses the same Deck/App verification
path. Product/2 navigator items now contain nullable closed audience/notes plans
for every stable frame, and `select_slide` returns identity to Haskell for
validation, gesture/selection reset, and active paint choice.

The browser now mounts only implemented compact commands, a default-visible
~26rem source editor with blur/Ctrl+Enter admission and stale-draft fencing, an
~8.5rem vertical thumbnail rail, every audience card plus static notes sidecar,
floating zoom, and quiet status. Only the Haskell-active acknowledged audience
surface is interactive. Files/Shapes/Connect/format/Present/Export placeholders,
diagnostic copy, identity pills, graph paper, and previous/next surrogate chrome
are absent.

Verification evidence: Product/2 protocol/runtime native suites pass, including
the packaged real-demo natural-move regression; host Node tests pass 19/19; the
GHC-Wasm build recompiles Product/2; installed Google Chrome passes three
thumbnails/cards, Haskell thumbnail selection, five no-Alt intermediate moves
with capture retained, separate Alt/free, exact drag and New Slide undo/redo,
dirty-draft race, absent diagnostic chrome, vertical navigation with faithful
16:9 geometry-matching thumbnails at 1440/820/560/390 CSS-pixel widths, no page
overflow, and zero page/console errors. Product-owner observation and acceptance
remain pending.
