# SB2-20260727-001 shared communication bus

This tracked Markdown file is the sole coordination channel with the monitor
agent. The orchestrator writes requests and stage/status updates; the monitor
may append observations under `Monitor inbox` only when asked. Product decisions
remain in `STEERING.md`/`REVIEW.md`.

## Authority labels

- **Observed fact**: backed by cited file/command output.
- **Accepted decision**: existing authority or explicit product-owner response.
- **Assumption**: must be tested before dependent mutation.
- **Proposal**: not accepted until delegated review or user gate resolves it.

## Role and ownership registry

| Role | Paths | Dependencies | Expected artifact | Acceptance check | Status |
| --- | --- | --- | --- | --- | --- |
| Orchestrator | writes session records/bus; read-only elsewhere through Stage 2 | none | governed synthesis | transitions/evidence recorded, conflicts stopped | active |
| Legacy/knowledge analyst | read-only required legacy knowledge/design/editor files | B0 | oracle research report | exact citations, no writes | pending |
| Current-architecture analyst | read-only current code/tests/docs | B0 | symbol/value/authority map | duplicate models/gaps/seam identified | pending |
| Designer/planner | writes only assigned research/design session artifact | R1,R2 | design + failure table + protocol alternatives | gates classified, implementable DAG | pending |
| Haskell implementer | unassigned until G1 | D1/G1 | shared vertical path and tests | focused native laws pass | pending |
| Browser/Wasm implementer | unassigned until G1 | D1/G1 + interface | reactor/host path and fixtures | protocol/host/Wasm checks pass | pending |
| Independent verifier | writes only verification research evidence | I1,I2 | independent ladder results | contract-derived checks, exact commands | pending |
| Adversarial reviewer | writes only review research evidence | V1 | exact-diff findings | authority/corruption/atomicity/wire/platform audit | pending |
| Integrator | shared manifests/current docs/knowledge only after ownership handoff | R3 | final wiring/docs/demo/review unit | full feasible checks + clean status | complete |

No product file has a writer before G1. Legacy trees and `.META/sources/drawio/`
are permanently read-only. One writer per assigned file.

## Timeline

### 2026-07-27 14:56 CEST — Stage 0 entered

- **Observed fact:** clean `dev` at
  `8aa9cece4a056332cabc214508adec4b63ff4685`; status output `## dev`.
- **Accepted decision:** ADR 0006 requires an immutable registration commit before
  worktree creation. The product owner's explicit worktree instruction permits
  this narrow governance commit, not implementation integration.
- **Observed fact:** session `SB2-20260727-001` created from the exact supplied
  `/tmp/slideblaster-editable-canvas-goal.md`.
- **Assumption to test:** existing bounded node-plus-connector fixture remains the
  thinnest honest common-model seam.
- Next: validate/register session, create/validate worktree, baseline native and
  browser behavior, then request R1/R2 in parallel.

## Interface discoveries

None yet.

## Blockers and decisions

None yet. Any user-gated design discovery stops dependent implementation.

## Monitor requests

No request yet.

## Monitor inbox

No monitor message recorded.

### 2026-07-27 15:14 CEST — Stage 0 complete; Stage 1 entered

- **Observed fact:** governed worktree validated at
  `/home/t/Documents/slide/slideBlaster/sb2-SB2-20260727-001`, branch
  `session/SB2-20260727-001`, registration
  `cbe29eb4f989f830b17157812e2c8180dbb690e0`.
- **Observed fact:** corrected focused native command passed source, TikZ, app,
  and product-protocol suites. TikZ reported 16 source/projection laws green;
  product protocol reported closed JSON and stale mutation rejection green.
- **Observed fact:** `./scripts/build-wasm.sh` successfully compiled all shared
  dependencies and the real reactor with Wasm GHC `9.14.1.20260330`; packaged
  Wasm size was 5,059,135 bytes.
- **Observed fact:** server smoke at `http://127.0.0.1:4173/` returned HTTP 200
  for HTML, Wasm, and generated JS. The first smoke failed only because URL
  logging preceded socket readiness; readiness polling passed.
- **Environmental limitation:** no tracked host test/E2E files were found by the
  initial filename scan; real browser behavior beyond successful packaging and
  serving remains to be located and run during architecture research.
- **Observed fact:** worktree status remained clean; generated build output is
  ignored.
- B0 complete. R1 and R2 are now active in parallel and remain read-only.

### 2026-07-27 15:20 CEST — Stage 1 complete; Stage 2 design complete; G1 blocked on protocol gate

- **Observed fact:** R1 inspected the legacy controller/canvas/snap/transaction/
  source-projector/connector/render paths, executable fixtures, required design
  notes, and both named knowledge concepts. Its complete report is
  `.META/research/SB2-20260727-001--legacy-editable-canvas--legacy-analyst--01/README.md`.
- **Observed fact:** `.META/sources/drawio/` is absent and repository policy says
  an unpinned checkout must not be traversed. This is recorded as unavailable,
  not silently treated as evidence; raw draw.io is outside the slice.
- **Observed fact:** R2 traced Source, generic Document, bounded TikZ, common
  Canvas/Render, App history/leases/reducer, both protocols, real Wasm exports,
  and browser host. Its complete report is
  `.META/research/SB2-20260727-001--current-editable-canvas--architecture-analyst--01/README.md`.
- **Observed fact:** `slideblaster.engine/1` is source-authoritative but uses the
  older bounded private model; `slideblaster.product/1` uses common Canvas but
  explicitly non-persistent `LiveAuthoring`. The latter is not mounted, and its
  workspace encoding is structurally incompatible with `product-renderer.js`.
- **Accepted delegated design:** one `AppModel`/`DocumentSession` is sole exact
  source/history/paint-lease root; bounded TikZ remains the private format
  reader/projector; generic Document + Canvas/Presentation are the only semantic
  model; common RenderPlan is the paint projection; JavaScript remains a closed
  validator/event/capability/paint interpreter. `LiveAuthoring` is bypassed.
- **Accepted delegated design:** capture `PaintKey = session × revision × ticket
  × surface`, extend it with monotonic gesture identity, store the common
  `MoveElement` produced by Haskell preview, and commit that exact stored
  operation. Verified successor bytes are recorded once by App history.
- **Accepted delegated design:** use the bounded noncanonical absolute node plus
  unchanged named connector fixture; broader syntax and connector editing remain
  excluded. No T0/T1/T2 meaning changes.
- **Proposal requiring product owner:** freeze `slideblaster.product/1` and add
  source-authoritative `slideblaster.product/2`; retain `/1` temporarily and
  defer deletion to a separately approved migration. Alternatives are additive
  `/1` or separate `slideblaster.app/1`.
- D1 is complete. G1 and all product mutation are blocked pending this explicit
  durable protocol-boundary decision.

### 2026-07-27 15:40 CEST — Protocol gate resolved; Stage 3 ownership assigned

- **Accepted product-owner decision:** implement source-authoritative
  `slideblaster.product/2`; preserve `slideblaster.product/1` unchanged and
  defer any deletion to a later separately approved migration.
- **Accepted delegation:** the orchestrator owns reversible Haskell design and
  implementation choices within existing source-preservation, common-model,
  portability, and browser-boundary laws.
- **Ownership I1-HS:** Haskell implementer exclusively owns touched files under
  `packages/slideblaster-tikz/`, `packages/slideblaster-app/`,
  `packages/slideblaster-engine/`, `packages/slideblaster-protocol/`, and
  `apps/slideblaster-web-wasm/`, including their focused tests and package
  manifests. It may add new modules; it must not edit browser host, repository
  manifests, current docs, or session records. Artifact: native source→common
  model→App history/render→closed product/2→real reactor path. Acceptance:
  focused package tests plus native dispatcher sequence and Wasm build.
- **Ownership I2-WEB:** browser/Wasm-host implementer becomes active only after
  I1-HS freezes the product/2 schema. It exclusively owns touched files under
  `hosts/web/` and host-only dependency-free tests. It must not edit Haskell,
  shared manifests, docs, or session records. Artifact: validated product/2
  renderer/event composition. Acceptance: validator tests and packaged browser
  E2E/smoke.
- **Ownership G2:** integrator reserves root `cabal.project*`, `PROJECT.md`,
  current `docs/`, `.META/knowledge/`, build/runbook scripts, and final session
  evidence after implementation handoff. No implementation agent may edit them.
- **Read-only roles:** verifier and reviewer may inspect the complete diff but
  write only their later research/review evidence.
- One writer per file is enforced. I1-HS is active; I2-WEB remains blocked on
  its schema handoff.

### 2026-07-27 16:05 CEST — I1 shared Haskell checkpoint complete; product/2 schema handoff

- **Observed implementation:** `SlideBlaster.TikZ.Adapter` admits bounded exact
  TikZ into generic Document + common Canvas/Presentation values with direct
  coordinate provenance and read-only connector fields. Common absolute-centre
  `MoveElement` delegates to the existing verified TikZ inverse.
- **Observed implementation:** `SlideBlaster.App.CanvasEdit` captures a common
  operation only against current accepted source and writable paint authority,
  seals only a one-revision byte-changing verified successor, rechecks source
  and lease at completion, and records successor bytes once through
  `SourceHistory`. App remains format-neutral.
- **Observed implementation:** `SlideBlaster.Engine.CommonTikz` lowers the
  admitted common picture to a closed resource-free common RenderPlan containing
  a direct rectangle/hit target and straight connector. Structured text paint is
  deliberately excluded because exact font measurement is not yet available.
- **Observed fixture:**
  `packages/slideblaster-tikz/test/fixtures/common-noncanonical.tikz` contains
  noncanonical coordinate spelling, comments, tab, CRLF, UTF-8 content, and a
  connector statement.
- **Independent verification:** focused TikZ, App, and Engine suites passed under
  native GHC 9.10.3. TikZ reported 22 green laws, including six new common-model
  laws for admission, locality, connector following with unchanged statement,
  no-op, unsupported placement, and syntax-only authority. App and Engine suites
  passed. `git diff --check` passed, and protocol/Wasm/browser paths remained
  untouched.
- **Schema handoff to I2:** product/2 may depend only on public
  `analyzeCommonTikz`, `applyCommonTikzEdit`, App lease/history/session APIs,
  `CanvasEditRequest`/opaque verified successor functions, and
  `renderCommonTikzPlan`. JSON must not expose private TikZ syntax/spans or mint
  App authority. `/1` remains unchanged.
- I1 complete. I2 protocol/Wasm phase is active; browser files remain blocked
  until exact JSON schema and reactor behavior pass native tests.

### 2026-07-27 16:40 CEST — I2 product/2, Wasm, and browser composition complete

- **Observed implementation:** new closed `slideblaster.product/2` is rooted in
  one `AppModel TikzSyntax TikzFieldKey`; transient state is limited to session,
  selection, and paint correlation. `/1` source and tests remain unchanged.
- **Observed behavior:** open/replace/undo/redo/move synchronously admit exact
  source, accept current analysis, issue real App paint requests, and lower a
  common RenderPlan. Paint acknowledgement consumes the exact pending request.
  Move requires matching revision/session/ticket/surface authority and executes
  `beginCanvasEdit` → common `MoveElement`/TikZ verified inverse → opaque seal →
  one App history record. Every error returns the original runtime state.
- **Observed reactor:** real static export `sb_product_v2_dispatch` is backed by
  a dedicated serial `MVar` runtime; old exports remain. Direct Node/Wasm smoke
  completed open → acknowledge → select → move.
- **Observed browser:** active `main.js` uses product/2; strict validators reject
  unknown/missing/extra/nested-invalid values before detached paint. JavaScript
  paints direct rectangle/connector values, translates finite pointer samples,
  and sends exact fences; it performs no source parsing, snapping, projection,
  history, or semantic connector policy.
- **Fixture parity:** Haskell and browser tracked fixtures have identical SHA-256
  `4ec5d520dc220ec737c01c55b9c75f4dd4f5c193724d7a4141f5347b9f7dff6f`.
- **Independent native checks:** existing engine protocol (18 laws), unchanged
  product/1 (8 laws), and product/2 (11 laws) all passed. Product/2 laws cover
  ready/syntax-only open, closed JSON, authority acknowledgement, local verified
  move and connector following, no-op, stale fences, unsupported/ambiguous
  atomicity, exact undo/fresh revision, redo, and direct invalidation.
- **Independent host checks:** 12 dependency-free Node validator/reducer tests
  passed; all host JS syntax checks and diff checks passed.
- **Independent cross-target check:** full `./scripts/build-wasm.sh` passed and
  packaged a 5,929,184-byte reactor. Static server returned HTTP 200 for HTML,
  active JS modules, 119-byte fixture, Wasm, and JSFFI artifacts.
- **Independent real-browser acceptance:** tracked `npm run test:browser` passed
  with installed Google Chrome: revision 0 ready+writable; selected `alpha`;
  actual pointer drag to `(4,5)` advanced exact authoritative source to revision
  1 and connector followed; one Undo restored all 119 original bytes at fresh
  revision 2; zero page/console errors.
- I2 complete. Implementation ownership is released. V1 independent verifier is
  now active read-only over the complete change set.

### 2026-07-27 17:05 CEST — V1 finding; narrow implementation repair reopened

- **Independent verifier disposition:** `NEEDS_REPAIR`. Full report:
  `.META/research/SB2-20260727-001--editable-canvas-verification--independent-verifier--01/README.md`.
- **Material product finding:** the active browser owns a local drag ghost and
  constructs a fresh `move_node` request on pointer release. Product/2 has no
  monotonic gesture identity, Haskell preview operation, stored operation, or
  commit-by-key. Therefore preview and commit do not yet consume the same
  Haskell-owned common operation as required by SPEC and accepted Stage 2 design.
- **Repair decision:** reopen I2-HS only for ProductV2 protocol/Wasm files, then
  I2-WEB only for hosts/web. Add lease-fenced begin/preview/commit/cancel;
  Haskell stores the exact common `MoveElement`/edit request under a monotonic
  gesture ID; commit carries only that ID. Direct source/history/open/new paint
  invalidates it. Browser may paint only the Haskell-returned preview projection.
- **Other verification:** all seven focused native suites, 12 host tests, full
  native build, Wasm build, static serve, and real Chrome acceptance passed.
- **Unrelated broad-gate finding:** 15/16 native suites pass. Catalog test
  `sports.camper-1` fails identically on untouched `dev` with no catalog/root
  manifest diff; classified as a pre-existing product failure, not this slice.
- V1 remains active until the repaired path is independently rerun.

### 2026-07-27 17:35 CEST — Gesture repair independently verified; V1 complete

- **Repair result:** product/2 direct `move_node` was removed. Haskell allocates
  monotonic gesture IDs, captures the exact writable paint/node/base revision,
  constructs and stores the common `MoveElement`, App edit request, and verified
  or no-op TikZ result during preview, and commits using only `gestureId`.
- **Atomic invalidation:** open, replace (including source no-op), undo/redo,
  selection/new authority, cancel, stale/duplicate IDs, and successful commit
  clear or reject gesture state without source/history mutation.
- **Browser repair:** pointer movement only supplies finite coordinates; only a
  validated Haskell `workspace.preview` centre positions the ghost. Release
  waits for the latest preview and sends one exact-key commit-by-ID request.
  Active product/2 source contains no `move_node` or `requestMoveNode`.
- **Independent recheck disposition:** `VERIFIED`. Product/2 protocol 14 laws,
  host validator/reducer 14 tests, JS syntax and forbidden-name checks, full
  Wasm build, and actual Chrome begin → preview `(4,5)` → commit-by-key → exact
  undo all passed. Current reactor is 6,010,465 bytes; zero browser errors.
- **Residual infrastructure/baseline note:** broad native remains 15/16 because
  untouched catalog fixture `sports.camper-1` fails identically on `dev`; no
  catalog/root-manifest path is in this session diff.
- V1 complete. R3 adversarial exact-diff review is now active and product paths
  are read-only pending findings.

### 2026-07-27 20:10 CEST — R3 adversarial review complete; G2 entered

- **Independent final disposition:** `APPROVE WITH NOTES`. Complete report:
  `.META/research/SB2-20260727-001--editable-canvas-adversarial-review--exact-diff-reviewer--01/README.md`.
- **Resolved Haskell findings:** a failed replacement preview now cancels the
  active gesture so an older verified operation cannot commit; the public App
  boundary is honestly mechanical rather than a forgeable semantic-proof token;
  Product/2 commits only the exact format-owned TikZ result stored by preview;
  Wasm state/response are forced inside `modifyMVar`; browser-safe session ID
  exhaustion has its own stable redacted error.
- **Resolved browser findings:** the exact closed schema includes
  `drag_preview_rejected` and `session_id_exhausted`; successful preview
  rejection clears gesture/ghost and never commits; dirty direct-source drafts
  cannot be discarded by refresh/load/history or failed cleanup; hidden protocol
  traces are source-redacted; real Chrome proves exactly one begin/commit and an
  isolated second real-Wasm valid-preview → unsupported-preview cancellation.
- **Independent final evidence:** six focused Haskell suites pass, including 15
  Product/2 laws, 22 TikZ/common laws, 18 engine protocol laws, and eight
  unchanged Product/1 laws; host Node tests pass 22/22; full Wasm packaging and
  real Chrome pass; fixture copies remain byte-identical; `git diff --check` and
  session validation pass. Browser smoke profile cleanup is fail-closed and left
  no matching temporary profile.
- **Review notes, not blockers:** the unsupported centre is exercised through a
  second production Wasm instance inside Chrome because finite pointer geometry
  cannot naturally emit exact `1/3`; broader syntax, structured text/font
  measurement, and other specified exclusions remain deferred. Broad native is
  still 15/16 solely because `sports.camper-1` fails identically on untouched
  `dev` and this diff changes no catalog/root-manifest path.
- R3 complete. Integrator G2 now owns reserved current docs, knowledge, final
  session specification/demo records, and review-unit preparation. Product
  implementation paths are read-only unless documentation validation exposes a
  product defect.


### 2026-07-27 20:21 CEST — G2 documentation integration complete; P1 next

- **Observed integration:** root README and canonical PROJECT map now identify
  the active source-authoritative Product/2 browser path, one AppModel
  source/history/lease authority, common Document/Canvas/Presentation/Render
  vocabulary, private bounded TikZ adapter, real forced-MVar GHC-Wasm reactor,
  and browser capability/event/paint boundary. Product/1 remains frozen,
  compatibility-only, inactive in the packaged host, and separately gated for
  later removal.
- **Observed contracts:** accepted architecture/capability/runtime/app/slice docs
  and the build runbook now match the active composition. New
  `docs/specs/product-v2-protocol.md` records the closed commands,
  outcomes/errors, source-redacted failures, and exact stored-operation gesture
  invariant without duplicating nested generated render schema.
- **Observed knowledge/demo:** repository-local
  `.META/knowledge/source-authoritative-product-v2-canvas.md` records the
  accepted authority and deferred Product/1 removal. `SPEC.md` now fixes the
  identical 119-byte fixture/hash, `(3/2,0)` and `(9,8)` initial geometry,
  `(4,5)` target, exact token locality, revisions 0→1→2, manual success/undo,
  automated isolated-production-Wasm `(1/3,7)` rejection, and exclusions.
- **Observed review unit:** `REVIEW.md` identifies
  `local-diff:cbe29eb4f989f830b17157812e2c8180dbb690e0-worktree`, contains an
  exact 33-modified/20-untracked inventory and inspection commands, keeps the
  artifact revision pending, and makes no product-owner observation,
  acceptance, approval, integration, or closure claim.
- **Validation passed:** current architecture/spec/runbook front matter and
  local Markdown links; session validator (`Valid implementation session
  (active)`); baseline `git diff --check`; exact fixture SHA-256 and 119-byte
  parity; exact REVIEW inventory; and current-authority stale-claim scans for
  earlier packaged-browser/Product/1 wording, Product/2 direct move, and the
  removed forgeable `VerifiedCanvasSuccessor`/sealer descriptions.
- **Deliberately not rerun:** expensive product suites, Wasm build, and Chrome;
  final R3 evidence remains the latest product verification and the
  orchestrator owns any final rerun.
- G2 is complete. P1 product-owner demonstration, observation, specification
  acceptance, exact-diff review, integration authorization/integration, and
  closure gates are next and remain pending.

### 2026-07-27 20:24 CEST — G2 complete; final verification passed; P1 entered

- **Current documentation/knowledge:** `PROJECT.md`, root/current architecture,
  capability, runtime, app, vertical-slice, build-runbook, Product/2 protocol,
  and repository-local knowledge records now describe the active
  source-authoritative Product/2 composition. Product/1 remains unchanged,
  frozen for compatibility, inactive in the packaged host, and removable only
  through a later separately approved migration.
- **Final fixture/demo record:** both tracked fixture copies are 119 bytes with
  SHA-256 `4ec5d520dc220ec737c01c55b9c75f4dd4f5c193724d7a4141f5347b9f7dff6f`.
  The session specification records `(3/2,0)` → `(4,5)`, exact coordinate-token
  locality, connector endpoint `(9,8)`, unchanged connector statement, revision
  0 → 1, byte-exact Undo at revision 2, and isolated real-Wasm `(1/3,7)`
  rejection evidence.
- **Final native/host checks:** session validation and diff checks pass; Source,
  TikZ, App, Engine, engine protocol, unchanged Product/1, and Product/2 suites
  all pass. Product/2 reports 15 laws and TikZ/common reports 22. Host Node tests
  pass 22/22; all current host JavaScript parses; fixture `cmp` passes.
- **Final cross-target/browser checks:** `./scripts/build-wasm.sh` passes. Final
  Wasm is 6,013,327 bytes, SHA-256
  `87edfe52c59688c5627bc44e300a9e11677896dd226797a345b866503f50cf3a`;
  JSFFI is 5,342 bytes, SHA-256
  `1160ffc16acda33c88122f797dee973ca89e155fe8b0a56205e5e18736c486f5`.
  Real Chrome passes isolated unsupported-preview cancellation plus live
  selection, exactly one begin/commit drag to `(4,5)`, exact Undo, dirty-draft
  preservation, and zero page/console errors. No smoke profile remains.
- **Known baseline note:** the broad catalog `sports.camper-1` failure remains
  the independently reproduced untouched-`dev` baseline result; no catalog or
  root project manifest is changed by this session.
- **Review unit:** `REVIEW.md` identifies the exact local diff against
  registration baseline `cbe29eb4f989f830b17157812e2c8180dbb690e0` and its
  complete modified/untracked inventory. Artifact revision remains pending until
  product-owner-authorized commit/integration.
- G2 complete. P1 is active. No commit, integration, push, or closure has been
  performed; observation, specification acceptance, exact-diff approval,
  integration authorization, and closure remain separate product-owner gates.

### 2026-07-28 — Visual-readiness repair complete; product-owner observation gate renewed

- **Observed fact:** the initial 1440×1100 screenshot exposed effectively invisible Product/2 geometry, a caption leaking below the slide, raw protocol JSON dominating the viewport, and unsupported toolbar clutter. The initial observation request was withdrawn before any product-owner response.
- **Observed repair:** the host now uses visible non-scaling rectangle/connector/selection strokes; keeps the concise `alpha` identity badge inside the slide without changing Haskell geometry or pointer authority; hides unsupported controls while preserving required DOM bindings; makes the browser path read-only; and reduces diagnostics to a compact status strip while retaining redacted protocol data for tests.
- **Observed verification:** host tests passed 22/22; all host JavaScript syntax checks passed; real Chrome against the production Wasm passed the visual contract, selection, one begin/commit drag to `(4,5)`, exact 119-byte undo at revision 2, dirty-draft inertness, isolated rejected preview cancellation, and zero page/console errors.
- **Observed visual evidence:** final 1280×1000 captures exist under `/tmp/SB2-20260727-001-visual-final/` for initial-ready, selected, moved, undone, and dirty states. Direct inspection found the repaired states presentable and internally consistent.
- **Gate:** product-owner observation is requested again only now. Observation, specification acceptance, exact-diff approval, integration, and closure remain pending and separate.

### 2026-07-28 — Product-owner observation recorded; first artifact rejected

- **Observed product-owner response:** the repaired artifact was observed but rejected. Manual box movement did not work for the product owner despite the automated pointer smoke; therefore drag reliability is a product failure, not a passed capability.
- **Observed missing workflow:** no New Slide action, no slide preview carousel/rail, no canvas zoom controls, no snapping, and insufficient parity with original SlideBlaster.
- **Format concern:** the product owner expects the document to be `.md`, not the demonstrated `.tex`. Exact Markdown syntax/authority must be recovered from original-product evidence and explicitly specified before changing the durable format boundary.
- **Gate state:** no acceptance, exact-diff approval, integration, or closure. The session remains open and starts a broader second revision with parallel read-only legacy, format, interaction, and current-architecture research.

### 2026-07-28 10:25 CEST — Second-revision three-agent research complete; I3/I4 assigned

- **Accepted steering:** STR-004 permits justified reshaping of P0 and roadmap
  order while retaining one active governed slice and every source-safety gate.
- **Observed manual-drag root cause:** the active renderer returns immediately
  when pointerdown targets an unselected node, so an ordinary first press-drag
  performs selection only. The Chrome smoke preselected with a separate click
  and therefore did not cover the product owner's gesture. The initial node is
  also half-clipped at y=0, worsening manual acquisition.
- **Observed legacy interaction:** the original product captures the first
  pointer sequence, suppresses native drag, distinguishes a 2px click threshold,
  previews from semantic state, commits once, supports pointer cancel, resolves
  binding before alignment/spacing/grid snapping with fixed-pixel tolerance,
  supports Alt bypass, and keeps drag coordinate conversion zoom-safe.
- **Observed product format:** the durable deck extension is
  `*.slideBlaster.md`; executable legacy parser/writer/fixtures use one
  `## title {#id}` plus fenced `slide` TikZ body and optional `notes`. The current
  Haskell path supports only the child bare TikZ body. Accepted legacy ADR 0004
  instead says the fence info string is `tikz`; no superseding ADR resolves the
  spelling conflict. A lossless parent container can reuse the current verified
  child projector after that narrow product-owner choice.
- **I3 ownership:** host interaction implementer exclusively owns
  `hosts/web/src/ui/product-v2-renderer.js`, `hosts/web/src/main.js`, and focused
  direct-interaction/browser-smoke tests until handoff. Acceptance is one-action
  unselected press-drag, click/subthreshold selection without edit, cancellation,
  and a fully in-bounds default target.
- **I4 ownership:** Haskell snapping implementer exclusively owns
  `packages/slideblaster-protocol/src/SlideBlaster/Protocol/ProductV2.hs` and
  `packages/slideblaster-protocol/test/ProductV2Main.hs`. It must reuse common
  Canvas snapping policy, retain format-owned verified projection, add no JS
  semantic logic, and return validated preview/guides plus free-drag disposition.
- I3 and I4 are active in parallel on disjoint files. Markdown deck mutation is
  blocked only on the exact fence spelling; no other implementation waits for a
  fourth agent.

### 2026-07-28 10:58 CEST — Product-owner architecture stop; Haskell-first correction entered

- **Product-owner finding:** the JSFFI transport is correct, but `main.js`,
  Product/2 policy, and renderer were accumulating a second interaction
  controller. The owner confirmed this does not meet the intended architecture.
- **Immediate stop:** I5 was interrupted. Its recent edits to Product/2 browser
  files are explicitly unverified and confer no completion status.
- **Accepted correction (STR-005):** Haskell owns pointer gesture phase,
  threshold, selection-plus-drag behavior, snapping/free disposition,
  preview/commit/cancel, zoom, command enablement, and navigator projection.
  JavaScript may capture/coalesce raw events, invoke the static JSFFI export,
  execute pointer capture and other browser APIs, validate closed values, and
  paint only.
- **I7-HS ownership:** exclusively owns a new generic App interaction reducer
  and its App facade/manifest/tests plus ProductV2 Haskell protocol/tests. It
  must expose raw pointer-event and view-command transitions with closed host
  actions/projections; preserve exact source/history/lease laws; and keep format
  composition outside generic App policy.
- **I8-WEB ownership:** blocked until I7 freezes the schema. It then exclusively
  owns active Product/2 JS policy/codec/renderer/main and focused host tests,
  reworking the interrupted I5 edits. It must contain no gesture state machine,
  snap resolver, zoom policy, history, revision arithmetic, or command policy.
- New Slide/Markdown remains separately blocked on the fence spelling gate.

### 2026-07-28 — V2A/R5 boundary review found blocking repairs

- **Disposition:** `NEEDS_REPAIR` despite passing focused native, host, fresh
  Wasm, and Chrome checks.
- **Source-preservation defect:** an older in-flight pointer/history response can
  overwrite a newer textarea draft because source adoption is not fenced by the
  draft generation captured at dispatch.
- **Pointer defect:** an out-of-bounds captured release is dropped, potentially
  stranding Haskell gesture/capture state; capture is also requested only after
  the Wasm round trip, leaving a fast-leave gap.
- **Accessibility defect:** semantic node buttons expose focus and ARIA state but
  have no keyboard activation path.
- **Diagnostic defect:** hidden DOM receives the full response including exact
  source despite a separate redacted trace.
- **Architecture finding:** semantic authority is correctly in Haskell, but
  `Protocol.ProductV2` currently combines wire codec with the App/TikZ/render
  composition and forces the protocol package to depend on nearly the complete
  semantic stack. The product-owner architecture concern therefore requires a
  package-level extraction, not only thinner JavaScript.
- **Repair ownership:** I9-HOST owns the active Product/2 host files/tests for
  draft-generation fencing, terminal pointer handling, keyboard behavior, and
  redacted diagnostics. I10-HS owns extracting Product/2 state/composition into
  a dedicated shared Haskell product-runtime package while leaving closed wire
  vocabulary/codec in `slideblaster-protocol`; it alone owns affected package
  manifests/composition imports. Both are active on disjoint paths except that
  any schema change is handed off before host finalization.

### 2026-07-28 — STR-005 correction independently approved; Markdown fence gate next

- **Independent disposition:** `APPROVE WITH NOTES` after the repair cycle.
- **Verified boundary:** closed Product/2 wire vocabulary/codec remains in
  `slideblaster-protocol`; portable source/history/App/TikZ/render composition
  now lives in `slideblaster-product-runtime`; the Wasm adapter serializes that
  runtime in one forced `MVar`; static `foreign export javascript` functions and
  generated GHC JSFFI glue carry requests/responses.
- **Verified thin host:** active JavaScript captures/coalesces raw DOM facts,
  invokes only Product/2 JSFFI, validates closed projections, executes pointer
  capture/release/focus, and paints. Gesture threshold/phase, selection,
  snapping/free mode, commit/cancel, source/history/revisions, zoom bounds, and
  navigator availability are Haskell-owned.
- **Resolved blockers:** newer drafts are dispatch-generation fenced; outside
  release/cancel cannot strand Haskell; Enter/Space activate through Haskell;
  diagnostic DOM is source-redacted.
- **Independent evidence:** focused App/TikZ/Engine/ProductV2 protocol/runtime
  suites, 16/16 host tests, Wasm build command, real Chrome acceptance, and diff
  check passed. Reviewer notes only that Wasm was already up-to-date, real Chrome
  did not synthesize lost-capture, no MVar fault-injection stress ran, and no
  full screen-reader audit ran.
- **Current gate:** lossless `.slideBlaster.md` deck/New Slide implementation is
  blocked only on reconciling the accepted-ADR `tikz` fence spelling with the
  executable parser/fixtures/notes ADR/current knowledge `slide` spelling.

### 2026-07-28 — STR-007 provisional deck trial implemented and verified

- **Accepted scope:** `.slide` is an explicitly provisional P0 trial, not a
  permanent format. Literal triple quotes inside raw bodies remain unsupported
  and read-only/syntax-only.
- **Implementation:** new portable `slideblaster-deck` preserves the exact demo
  parent bytes/spans, associates all three notes, admits repeated nodes/simple
  paths per slide, lifts verified coordinate edits to exact parent spans, and
  inserts collision-free deterministic slides. `App.Navigation` and Product/2
  own active frame/index, availability, selection/gesture reset, paints, New
  Slide, and Undo/redo frame preference.
- **Host boundary:** the host loads `fixtures/demo.slide`, renders inert projected
  navigator entries and a visible accessible New Slide button, and correlates
  node facts with painted surfaces. It does not parse decks, mint IDs, advance
  revisions, or own navigation/source policy.
- **Observed native evidence:** Deck, App, TikZ, Engine, ProductV2 protocol, and
  ProductV2 runtime suites all passed in one affected-suite invocation. Runtime
  includes prior pointer/snapping/undo regressions plus three-slide navigation
  and one-step New Slide exact Undo.
- **Observed host/cross-target evidence:** host tests pass 16/16;
  `./scripts/build-wasm.sh` compiled `SlideBlaster.Deck` and the deck-backed
  runtime with Wasm GHC `9.14.1.20260330`; `npm run test:browser` passed with
  installed Google Chrome for byte-exact demo open, all three previews without
  navigation revision change, verified `source` move+Undo, `slide-4` insertion
  after `questions`, exact Undo with prior active restoration, stale rejection,
  and zero page/console errors.
- No reset, clean, commit, push, or network operation was performed. Product-owner
  observation/acceptance and session closure remain separate pending gates.

### 2026-07-28 15:55 CEST — STR-008 drag/workspace repair implemented

- **Drag repair:** Product/2 still computes normal Canvas snap first. If the
  active Deck inverse rejects that placement as relative or as the provisional
  non-terminating absolute projection failure, Haskell recomputes the same raw
  destination as `FreeDrag`. It emits no guides, performs no rounding, and uses
  the unchanged App capture/Deck reparse/semantic verification/history path.
  Exact pointer destinations that are themselves unsupported still reject
  atomically.
- **Native regression:** the product-runtime suite packages and opens the real
  demo. Natural no-Alt intermediate samples for the writable `source` node cover
  a left-of-`model` relative bind and a path through the non-terminating
  one-third snap region. Every sample remains `dragging`; fallback samples have
  zero guides; each release produces exactly revision 1 and one undoable parent
  transition.
- **Closed workspace:** Product/2 navigator rows now carry stable frame/title,
  static audience plan, and optional notes plan for every frame. New
  composition-neutral `select_slide {frame}` validates identity in Haskell,
  resets gesture/selection, and selects an acknowledged or offered active paint.
  Only that active audience paint is writable.
- **Host result:** diagnostic workbench chrome was replaced by compact identity,
  Source, Undo/Redo, and `+ Slide`; a default-visible source editor; vertical
  thumbnail rail with `+ New slide`; continuous audience/notes rows; floating
  zoom; and quiet product status. Source admission is blur/Ctrl+Enter and keeps
  dispatch-generation stale-draft fencing. Unsupported placeholder controls,
  protocol tags/copy, source byte/revision/path copy, identity pills, and graph
  paper are removed.
- **Verification observed so far:** focused Product/2 native tests pass; host
  Node tests pass 19/19; `./scripts/build-wasm.sh` rebuilt and packaged with Wasm
  GHC 9.14.1.20260330; installed Google Chrome passes all STR-008 checks with
  zero page/console errors. Final formatting/diff/status reruns remain before
  handoff.
- **Gate:** no product-owner acceptance, integration, commit, push, or closure
  is claimed. The complete local diff remains the review unit.

### 2026-07-28 15:48 CEST — STR-008 UI reviewer blockers repaired

- **Observed review defects:** the narrow breakpoint made the slide rail
  horizontal, the inline thumbnail card collapsed to a line, and visible chrome
  exposed the internal `demo.slide` fixture name.
- **Observed repair:** the navigator remains a bounded ~8.5rem vertical column
  when the workspace stacks; `.thumb-card` establishes a block 16:9 box; the
  authored title `Small Systems, Clear Thinking` identifies the document and
  the editor heading is simply `Source`.
- **Verification:** host tests pass 19/19; JavaScript syntax and diff checks pass;
  real Google Chrome passes the complete smoke at 1440, 820, 560, and 390 CSS
  pixels with vertical rail, three geometry-matching 16:9 thumbnails, three
  continuous cards, no page overflow, no forbidden fixture copy, and zero
  page/console errors.
- **Gate:** technical reviewer blockers are repaired. Product-owner observation,
  acceptance, review approval, integration, and closure remain pending.


### 2026-07-28 — STR-008 terminal reuse reviewer blocker repaired

- **Ordering repair:** pointer IDs are generation-fenced in the host transport. A same-ID down waits for the predecessor's dispatched move and one terminal fact to settle; latest queued movement is retained without exceeding one unresolved move dispatch.
- **Capture safety:** capture-target replacement occurs only when the queued generation is admitted. Predecessor lost-capture duplication is suppressed while settling, and deactivation terminates tracked queued/admitted generations without capturing detached targets.
- **Boundary:** JavaScript still owns only raw-event transport ordering and browser capture effects; no gesture, snap, commit, revision, or source policy moved from Haskell.
- **Verification:** host tests pass 24/24, including immediate same-ID reuse after cancel and lost capture; JS syntax and focused diff checks pass. Real Google Chrome against the exact no-store port-4180 server passes five stepwise previews plus genuine `touchCancel`, both 36-move no-wait bursts, Alt/free, exact history, New Slide, draft race, responsive checks, and zero errors.
- No commit, network operation, reset, integration, release, or closure was performed.
