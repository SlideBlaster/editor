# Research artifact: editable-canvas-verification

- Slug: `SB2-20260727-001--editable-canvas-verification--independent-verifier--01`
- Session: `SB2-20260727-001`
- Task: `editable-canvas-verification`
- Agent: `independent-verifier`
- Run: `01`
- Created: `2026-07-27`
- Status: `complete`
- Disposition: `VERIFIED`

## Independent V1 recheck — 2026-07-27 17:07–17:10 +02:00

### Final disposition

`VERIFIED` for the SB2-20260727-001 V1 repair.

The previously material failure is repaired. Product/2 now owns a lease-fenced gesture transaction: Haskell allocates a monotonic gesture ID, captures the exact displayed paint/node/base revision, constructs and stores one common `MoveElement` together with its exact `App.CanvasEditRequest` and verified/no-op TikZ result, projects that stored operation for preview, and commits only by gesture ID from the stored request/result. The active browser path paints the ghost only from the validated Haskell `workspace.preview`; raw pointer movement only submits a sample. The tracked real-Chrome smoke proves the actual Wasm exchange is `begin_drag` → exact Haskell preview `(4,5)` → `commit_drag` containing only the gesture key.

The unrelated repository-wide catalog baseline remains red on `sports.camper-1`. It is unchanged from the prior independently reproduced baseline and is not part of, caused by, or repaired by this gesture change. Product-owner observation/acceptance and session closure also remain outside this verifier disposition.

### Independent implementation proof

The repaired implementation was read directly; implementer summaries were not used as evidence.

- `packages/slideblaster-protocol/src/SlideBlaster/Protocol/ProductV2.hs:85-100` defines the closed request ADT with `BeginDrag`, `PreviewDrag`, `CommitDrag GestureId`, and `CancelDrag`; it has no direct move constructor. Exact-key decoding at `:921-943` accepts only `{protocol,command,revision,paint,nodeId}` for begin, `{protocol,command,gestureId,centre}` for preview, and `{protocol,command,gestureId}` for commit/cancel. Unknown `move_node` therefore reaches `ProductV2UnknownCommand`; the native closed-JSON law independently observes `unknown_command`.
- Gesture state at `ProductV2.hs:136-160` stores `GesturePreview EditIntent CommonCanvasEditRequest TikzCanvasEditResult` inside `ActiveGesture GestureId CorrelatedPaint NodeId Revision`. `productNextGesture` starts at 1 and is incremented, not reset, by begin; `openSource` clears only the active gesture and advances the document session. The passing monotonic law observes IDs 1, 2 after cancel, and 3 after reopening.
- Begin at `ProductV2.hs:351-380` requires the selected node, exact displayed fence, and `authorityAllowsEdit` for the captured paint. It captures the complete correlated paint (request plus plan), node ID, and current source revision before incrementing the gesture counter.
- Preview at `ProductV2.hs:382-403` constructs `Canvas.MoveElement (Canvas.NodeElement identity) (Canvas.AbsolutePlacement destination Canvas.Centre)`, calls `App.beginCanvasEdit` with the captured paint, applies that same operation through `Tikz.applyCommonTikzEdit`, and stores all three values. A subsequent preview replaces the `Maybe GesturePreview` in the same `ActiveGesture`; the ID/paint/node/base revision remain unchanged. Projection at `:610-632` derives its centre from the stored operation and its outcome from the stored TikZ result.
- Commit at `ProductV2.hs:405-431` accepts only the ID, obtains the stored preview through `requireCurrentGesture`, and consumes its stored `editRequest` and `projected` result. It does not accept or reconstruct a centre. Verified commit seals the stored request/result via `App.makeVerifiedCanvasSuccessor` and `App.commitVerifiedCanvasSuccessor`; no-op ends the gesture without source/history change.
- `SlideBlaster.App.CanvasEdit` independently rechecks the exact accepted document, source revision/bytes, writable paint lease, successor revision, and commit-time source/lease before recording one history transition. `SlideBlaster.TikZ.Adapter.applyCommonTikzEdit` delegates the stored common operation to the bounded inverse and verifies the admitted successor has the requested destination.
- Rejected dispatch returns the original immutable state. Cancel and no-op explicitly clear the gesture. Successful commit clears it before successor analysis. Selection, paint acknowledgement/new authority, open, direct source replacement (including `source_unchanged`), undo, and redo clear it. Wrong, missing, duplicate, old-session, cancelled, stale-revision, stale-paint, unsupported-preview, and analysis failures cannot commit. Defensive `requireCurrentGesture` rechecks both exact base revision and the current displayed writable paint even though ordinary authority-changing transitions proactively clear the gesture.

### Browser ownership and sequencing proof

- `hosts/web/src/ui/product-v2-renderer.js:127-144` converts `pointermove` to a sample and calls `onGestureSample`; it does not position or reveal the ghost. The sole ghost-positioning call is `positionBox(pointerGesture.ghost, ...)` at `:200`, inside `updateGesture`, after gesture-ID/node correlation against the validated Haskell projection. The ghost remains hidden until that projection arrives.
- `hosts/web/src/main.js:192-280` serializes one gesture flow with `inFlight`. While a request is pending, newer samples replace `pendingPoint`; after completion the pump sends the latest retained point. Release stores its exact point as both `latestReleasePoint` and pending work. Commit is guarded by `released`, no pending sample, exact equality with `latestPreviewPoint`, and `!commitSent`; `commitSent` is set before dispatch. Thus one release produces at most one commit and only after its release point has a correlated Haskell preview.
- The browser validates the response before `applyGestureWorkspace` calls `renderController.updateGesture(workspace.gesture, workspace.preview)`. Gesture projections must match current source, selection, displayed fence, node, and ID. A stale browser response is rejected by request token/revision basis and cannot replace newer workspace state.
- Exact active-path grep over `hosts/web/src/main.js`, `hosts/web/src/protocol/product-v2.js`, `hosts/web/src/ui/product-v2-renderer.js`, the ProductV2 Wasm adapter, and Haskell ProductV2 returned no `move_node` or `requestMoveNode`. Remaining repository matches are the explicit rejection/smoke assertions and legacy/non-product/2 paths, not the active repaired composition.

### Recheck commands and results

All commands ran from `/home/t/Documents/slide/slideBlaster/sb2-SB2-20260727-001` unless noted.

```sh
cabal --project-file=cabal.project.native test \
  slideblaster-product-v2-protocol-tests --test-show-details=direct
```

Pass: 14/14 named ProductV2 checks. In particular: closed gesture JSON/direct-command rejection; exact writable begin and monotonic IDs; Haskell-owned/latest preview commit; no-op; gesture races/stale IDs; source/history invalidation; unsupported preview atomicity; exact undo/redo; and direct-invalid last-good inertness.

```sh
cd hosts/web
npm test
find src test -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) \
  -print0 | sort -z | xargs -0 -n1 node --check
```

Pass: 14/14 Node tests, 0 failures/skips, followed by clean syntax checks for every host source/test JavaScript file. The tests include closed nested gesture projections, correlation failures, exact gesture request keys, all closed gesture outcomes/errors, stale-response rejection, and bounded exact pointer conversion.

```sh
grep -RInE 'move_node|requestMoveNode' \
  hosts/web/src/main.js \
  hosts/web/src/protocol/product-v2.js \
  hosts/web/src/ui/product-v2-renderer.js \
  apps/slideblaster-web-wasm/src/SlideBlaster/Adapter/Web/ProductV2.hs \
  packages/slideblaster-protocol/src/SlideBlaster/Protocol/ProductV2.hs
```

Pass: no output (grep status 1), recorded as `PASS: no move_node/requestMoveNode in active product/2 path`.

```sh
./scripts/build-wasm.sh
```

Pass: current reactor reported up to date and was copied/generated into `hosts/web/dist`. The actual artifact used by this recheck is 6,010,465 bytes with SHA-256 `c47d29b4fb98409acd0b6a655b01e66acf96ff1b6ead51c4267777de26b1cbfa`; generated JSFFI is 5,342 bytes with unchanged SHA-256 `1160ffc16acda33c88122f797dee973ca89e155fe8b0a56205e5e18736c486f5`. Both were timestamped `2026-07-27 17:08:51 +0200`; `hosts/web/dist/` remains ignored.

```sh
cd hosts/web
npm run test:browser
```

Pass against real `google-chrome` and the current Wasm artifact:

```text
PASS browser smoke (google-chrome): ready+writable revision 0; selected alpha;
dragged to (4,5) revision 1; undo restored 119 exact bytes at revision 2;
0 page/console errors
```

The tracked smoke was inspected, not accepted solely from its final message. It drives CDP pointer events and inspects the raw protocol trace. It asserts: no `move_node`; begin precedes the latest preview; commit follows that preview; raw Haskell `workspace.preview.centre` is exactly `{x:"4",y:"5"}` with `verified`; commit request keys are exactly `command`, `gestureId`, and `protocol`; node/centre/revision/paint are absent; commit ID equals preview ID; the commit response is `drag_committed`; exact moved bytes match the `(4,5)` replacement; connector geometry is `(4,5)->(9,8)`; and exact 119-byte undo reaches fresh revision 2.

```sh
cabal --project-file=cabal.project.native test \
  slideblaster-catalog-tests --test-show-details=direct
```

Expected baseline failure independently reconfirmed:

```text
FAIL: draw.io snapshot: InvalidDrawIOPath "sports.camper-1"
      (InvalidStencilPathStructure PathSubpathNeedsDrawnSegment)
0 of 1 test suites passed.
```

This is the same prior failure already reproduced on untouched `dev`; the repair changes no catalog or root project file. It remains an unrelated baseline finding, not a V1 repair failure.

### Previously failed or dependent SPEC rows reassessed

| Prior row | Recheck | Evidence |
| --- | --- | --- |
| Haskell owns typed edit, projection, semantic verification, history, leases, acceptance | PASS without the prior preview qualification | ProductV2 stores common operation/App request/TikZ result; App and TikZ recheck source, semantics, lease, and history. |
| Preview and commit use the same Haskell-owned stored operation | **PASS (repaired)** | Repeated preview replaces the stored triple under one ID; commit accepts only ID and consumes stored request/result. |
| Stale revision/paint/session and delayed response reject atomically | PASS including gesture-key model | Haskell base revision/current paint checks, proactive invalidation, immutable failure dispatch, stale/duplicate/cancel tests, and host token/revision reducer. |
| JavaScript is validator/painter/pointer adapter only | **PASS (repaired)** | Pointer movement emits samples; only validated `workspace.preview` positions the ghost; no browser reconstruction of `MoveElement` or commit centre. |
| Real pointer path to exact target `(4,5)` | PASS with stronger protocol evidence | Chrome trace asserts exact begin/preview/commit ordering, Haskell centre `(4,5)`, exact commit keys, source bytes, and geometry. |
| Closed, source-redacted product/2 JSON | PASS with gesture schema | Haskell exact-key decoder/rejection laws and 14 host closed-schema tests. |
| No-op/cancel/duplicate/direct-source/history/new-authority behavior | PASS | Native state-machine laws plus transition inspection; all rejected paths preserve source/history and invalidated IDs cannot commit. |
| Broad native suite | **FAIL (pre-existing, unrelated)** | Catalog-only `sports.camper-1` baseline reconfirmed; it is not reclassified as a gesture regression. |
| Complete product-owner demonstration/acceptance | UNVERIFIED by role | Real technical smoke passes; explicit product-owner observation, acceptance, diff approval, integration, and closure remain pending. |

All other prior PASS rows remain supported by the earlier evidence and by the repaired focused/Wasm/browser reruns; no repair introduced a contradictory result. The prior `NEEDS_REPAIR` body below is retained as the historical first-pass record. Its material finding is superseded by this dated recheck, while its catalog baseline and deferred-scope observations remain applicable.

## Question

Does the Stage V1 worktree independently satisfy the accepted source-authoritative editable-browser-canvas contracts and the complete session SPEC, including exact source locality, common-model semantics, App history and paint leases, closed product/2, the real GHC-Wasm/browser path, and atomic failures?

## Result

`NEEDS_REPAIR`.

The bounded source-to-common-model-to-App-to-product/2-to-real-Wasm/browser move and exact undo path works and all focused gates pass. The real Chrome test performs an actual pointer drag to `(4,5)`, reaches revision 1, keeps the connector statement unchanged while its geometry follows, and restores all 119 original bytes at fresh revision 2 with no page/console errors.

One material SPEC contract is not implemented: the drag preview and commit do not use one Haskell-owned stored operation. The browser owns the preview ghost and, only on `pointerup`, creates a fresh `move_node` request containing identity and destination. Product/2 has no gesture identity, Haskell pointer-sample/preview command, stored preview operation, or commit-by-gesture-key command. This contradicts both the top-level SPEC invariant “Preview and commit use the same `MoveNode` operation” and the accepted Stage 2 design requiring a monotonic gesture identity, Haskell-resolved/stored common operation, and commit carrying only its gesture key.

A broad native gate also has one pre-existing unrelated failure: `slideblaster-catalog-tests` rejects draw.io stencil `sports.camper-1`. It reproduces on untouched `dev` at the same registration revision and this session changes no catalog or root project file. It is not caused by this slice, but the complete native matrix is not green.

## Source and provenance

Verification was performed in `/home/t/Documents/slide/slideBlaster/sb2-SB2-20260727-001` without editing product, session, current-doc, or legacy files. The only verifier-owned mutation is this report.

- Branch: `session/SB2-20260727-001`.
- Registration/HEAD revision: `cbe29eb4f989f830b17157812e2c8180dbb690e0`.
- Baseline authority: `dev`; the untouched adjacent checkout was also at `cbe29eb4f989f830b17157812e2c8180dbb690e0` when the catalog failure was reproduced.
- Contracts read: `.META/sessions/SB2-20260727-001/{SESSION,SPEC,SLICES,BUS,STEERING,REVIEW}.md`; accepted ADRs `0001`, `0002`, `0004`, and `0006`; `docs/specs/vs-canvas-authoring.md`, `p2-source-history-slice.md`, `host-protocol.md`, and `slice1-tikz-subset.md`; `AGENTS.md` and `STYLE.md`.
- Stage 1 reports read: `SB2-20260727-001--current-editable-canvas--architecture-analyst--01` and `SB2-20260727-001--legacy-editable-canvas--legacy-analyst--01`.
- Review input: complete 2,355-line/95,034-byte tracked patch plus every untracked implementation module, fixture, and test.
- Fixture SHA-256, both copies: `4ec5d520dc220ec737c01c55b9c75f4dd4f5c193724d7a4141f5347b9f7dff6f`.
- Fixture size: 119 bytes in both `packages/slideblaster-tikz/test/fixtures/common-noncanonical.tikz` and `hosts/web/fixtures/common-noncanonical.tikz`.
- Built Wasm: 5,929,184 bytes, SHA-256 `0e941e054c8034a2f3cc53e7452a537b43a28f5336d41abb692c620b9c5d1311`.
- Generated JSFFI: 5,342 bytes, SHA-256 `1160ffc16acda33c88122f797dee973ca89e155fe8b0a56205e5e18736c486f5`.

### Exact changed paths at verification

Modified tracked paths:

```text
.META/sessions/SB2-20260727-001/BUS.md
.META/sessions/SB2-20260727-001/SLICES.md
.META/sessions/SB2-20260727-001/SPEC.md
.META/sessions/SB2-20260727-001/STEERING.md
apps/slideblaster-web-wasm/app/Main.hs
apps/slideblaster-web-wasm/slideblaster-web-wasm.cabal
hosts/web/README.md
hosts/web/index.html
hosts/web/package.json
hosts/web/src/main.js
hosts/web/src/wasm/load-reactor.js
hosts/web/styles.css
packages/slideblaster-app/slideblaster-app.cabal
packages/slideblaster-app/src/SlideBlaster/App.hs
packages/slideblaster-app/test/Main.hs
packages/slideblaster-engine/slideblaster-engine.cabal
packages/slideblaster-engine/src/SlideBlaster/Engine.hs
packages/slideblaster-engine/test/Main.hs
packages/slideblaster-protocol/slideblaster-protocol.cabal
packages/slideblaster-protocol/src/SlideBlaster/Protocol.hs
packages/slideblaster-tikz/slideblaster-tikz.cabal
packages/slideblaster-tikz/src/SlideBlaster/TikZ/Internal/Decimal.hs
packages/slideblaster-tikz/src/SlideBlaster/TikZ/Model.hs
packages/slideblaster-tikz/test/Main.hs
```

Untracked intended source/evidence paths:

```text
.META/research/SB2-20260727-001--current-editable-canvas--architecture-analyst--01/README.md
.META/research/SB2-20260727-001--editable-canvas-verification--independent-verifier--01/README.md
.META/research/SB2-20260727-001--legacy-editable-canvas--legacy-analyst--01/README.md
apps/slideblaster-web-wasm/src/SlideBlaster/Adapter/Web/ProductV2.hs
hosts/web/fixtures/common-noncanonical.tikz
hosts/web/src/protocol/product-v2.js
hosts/web/src/ui/product-v2-renderer.js
hosts/web/test/browser-smoke.js
hosts/web/test/product-v2.test.js
packages/slideblaster-app/src/SlideBlaster/App/CanvasEdit.hs
packages/slideblaster-engine/src/SlideBlaster/Engine/CommonTikz.hs
packages/slideblaster-protocol/src/SlideBlaster/Protocol/ProductV2.hs
packages/slideblaster-protocol/test/ProductV2Main.hs
packages/slideblaster-tikz/src/SlideBlaster/TikZ/Adapter.hs
packages/slideblaster-tikz/test/fixtures/common-noncanonical.tikz
```

No changed path is under legacy `editor/`, legacy `design/`, `infra/`, current `docs/`, root `cabal.project*`, or `PROJECT.md`. No product/1 implementation or test path changed. `git diff --quiet ... -- packages/slideblaster-catalog cabal.project cabal.project.native cabal.project.wasm` returned 0. Added Cabal edges are existing workspace packages; `aeson` is reused by a new test component. There is no package lock, `node_modules`, or new npm dependency.

## Environment

- Linux.
- Native GHC selected by Cabal: 9.10.3, profile `-O1`.
- Wasm GHC reported by existing session/build evidence: 9.14.1.20260330.
- Node provides the dependency-free host tests and CDP smoke.
- Real browser found and used by the tracked smoke: `google-chrome`.
- The Hackage index warning in the untouched baseline checkout said its package list was 96 days old; no dependency download was needed for the session worktree gates.

## Reproduction and command evidence

All commands below were run from the session worktree unless a different directory is stated.

### Static and manifest gates

```sh
./scripts/session/validate.sh SB2-20260727-001
git diff --check
find hosts/web/src hosts/web/test -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) -print0 | sort -z | xargs -0 -n1 node --check
cabal check  # each of the five changed Cabal packages
sha256sum packages/slideblaster-tikz/test/fixtures/common-noncanonical.tikz hosts/web/fixtures/common-noncanonical.tikz
wc -c packages/slideblaster-tikz/test/fixtures/common-noncanonical.tikz hosts/web/fixtures/common-noncanonical.tikz
```

Results:

- Session validator: pass, “Valid implementation session (active)”.
- `git diff --check`: pass.
- Every host JS source/test file parses: pass.
- Fixture hashes and 119-byte sizes match exactly.
- `cabal check` parses all changed manifests but reports existing repository packaging debt: missing category/maintainer/description, missing upper bounds for workspace packages, `license: NONE`, and test-component `-Werror` portability advice. These are packaging warnings/errors, not compilation failures and were not introduced as a new dependency by this slice.
- `cabal --project-file=cabal.project.native build all`: pass, zero `warning:` lines in the captured output.

### Focused native gates

```sh
cabal --project-file=cabal.project.native test \
  slideblaster-source-tests \
  slideblaster-tikz-tests \
  slideblaster-app-tests \
  slideblaster-engine-tests \
  slideblaster-protocol-tests \
  slideblaster-product-protocol-tests \
  slideblaster-product-v2-protocol-tests \
  --test-show-details=direct
```

Result: seven of seven suites passed. The captured output contains 59 explicit named `PASS:` lines plus successful source/App/Engine suite summaries.

Contract coverage observed in code and passing named tests:

- exact identity/locality and expected revision/bytes: source suite plus TikZ `prop_exactRoundTripPreservesBytes`, `prop_moveChangesOnlyCoordinateSlots`, `prop_singleFieldMovePreservesOtherSpelling`, and `prop_staleRevisionCannotCommit`;
- candidate reparse/intended semantic equality and atomic verification: `prop_verificationFailureIsAtomic` and the private bounded inverse used by the common adapter;
- malformed/unsupported/ambiguous/syntax-only authority: recovery, direct-invalid, ambiguous/unsupported, and common syntax-only laws;
- no-op: TikZ common/no-op, product/2 “no-op move creates no revision or history”;
- exactly one history record and exact undo/fresh revision: App `canvasEditCheck`, replayed-completion rejection, and product/2 undo/redo laws;
- paint lease/fence: App lease/update/canvas-edit checks and product/2 acknowledgement/stale-fence laws;
- connector source unchanged and geometry follows: TikZ common connector law, Engine common render check, product/2 verified move law;
- closed/source-redacted JSON: protocol v1, unchanged product/1, product/2 closed-schema and redacted-error laws.

Focused named totals visible in direct output:

- TikZ/common adapter: 22 pass.
- engine protocol v1: 18 pass.
- product/1: 8 pass; this confirms compatibility behavior while its source remains unchanged.
- product/2: 11 pass.
- source, App, and Engine suites each passed; those harnesses do not print every internal check as a separate `PASS:` line.

### Broad native gates

```sh
cabal --project-file=cabal.project.native test all --test-show-details=direct
```

The broad run passed 12 suites before Cabal stopped on one failure:

```text
FAIL: draw.io snapshot: InvalidDrawIOPath "sports.camper-1"
      (InvalidStencilPathStructure PathSubpathNeedsDrawnSegment)
Test suite slideblaster-catalog-tests: FAIL
```

The not-yet-reached suites were run separately. `slideblaster-ports-tests` and `slideblaster-adapter-native-tests` passed. A concurrent `cabal build all` briefly caused a missing ephemeral CLI package database; serial rerun of `slideblaster-cli-tests` passed. Final broad accounting is therefore 15 of 16 native suites passed, one failed.

The catalog failure was reproduced with this command in the untouched adjacent `dev` checkout at the same revision:

```sh
cabal --project-file=cabal.project.native test slideblaster-catalog-tests --test-show-details=direct
```

It failed identically on `sports.camper-1`. Because the session diff changes no catalog/root-project path, this is a confirmed pre-existing unrelated product failure, not a regression caused by this slice. It nevertheless means the broad native gate is not wholly green.

### Host boundary

```sh
npm test  # in hosts/web
```

Result: 12/12 dependency-free Node tests passed, zero failures/skips. They cover complete closed decoding, malformed/extra/missing/nested fields, enums/safe integers, plan/fence/source/surface/element correlation, typed geometry, bounded exact-number conversion, lower-case bounded base16 including hostile text, source-redacted errors, stale-response reduction, and bounded finite y-up pointer conversion.

Static boundary inspection found:

- no `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write`, `eval`, `new Function`, or `DOMParser` in the active host source;
- only pre-existing capability modules use `localStorage`; active product/2 exact-source/history policy does not;
- no `GHC.Wasm.Prim`, JSFFI, browser, native process, filesystem, or network imports in shared package Haskell;
- WebAssembly/WASI and `sb_product_v2_dispatch` are confined to the browser loader/Wasm composition;
- product/2 host validates and paints closed projections and converts finite pointer coordinates; it contains no TikZ parser, semantic connector resolver, source revision increment, or browser history stack.

### Real Wasm, serving, and browser

```sh
./scripts/build-wasm.sh
```

Pass, zero `warning:` lines. It produced the real 5,929,184-byte reactor and 5,342-byte generated JSFFI listed above. `load-reactor.js` requires `sb_product_v2_dispatch`, instantiates the Wasm module, initializes WASI, and invokes that exported function. The browser test below therefore proves the export by actual instantiation and invocation, not by a static symbol search or mock.

A fresh `./scripts/serve-web.sh 42817` returned HTTP 200 for:

```text
/                                      13257 bytes
/src/main.js                           11910 bytes
/src/protocol/product-v2.js            21119 bytes
/src/ui/product-v2-renderer.js         10903 bytes
/fixtures/common-noncanonical.tikz       119 bytes
/dist/slideblaster-web-wasm.wasm     5929184 bytes
/dist/slideblaster-web-wasm.js          5342 bytes
```

```sh
npm run test:browser  # in hosts/web
```

Pass:

```text
PASS browser smoke (google-chrome): ready+writable revision 0;
selected alpha; dragged to (4,5) revision 1; undo restored 119 exact
bytes at revision 2; 0 page/console errors
```

Inspection confirms this is not a mock: the test starts a local static server, starts real headless Chrome, uses CDP `Input.dispatchMouseEvent`, reads Haskell protocol output and actual SVG/DOM geometry, and compares authoritative base16 source. It calculates the exact expected moved bytes by replacing only `+001.5000` and `-000.00`; therefore the unchanged connector statement is included in the equality check. It separately checks connector geometry `{x1:"4", y1:"5", x2:"9", y2:"8"}`. Its `finally` block closes CDP/server, terminates Chrome, and removes the temporary profile. Post-run process and `/tmp/slideblaster-browser-smoke-*` scans were empty.

### Cross-target conformance checked

- Both native and browser use the same tracked 119-byte fixture hash.
- Native product/2 reports `source_opened`, ready common render, writable only after acknowledgement, `node_moved` at revision 1, exact local successor, connector start following, `undo` restoring the original at revision 2, and source-redacted closed errors.
- Actual Wasm/browser reports the corresponding ready/writable revision 0 state, actual move to `(4,5)` at revision 1, connector `(4,5)->(9,8)`, and exact original bytes after undo at revision 2.
- Native’s named move fixture uses `(6,7)`, while browser acceptance deliberately uses `(4,5)`; no claim is made that those moved byte strings are identical. Conformance is limited to shared fixture identity, decoded outcome/revision/authority fields, locality law, connector-following law, and fresh-revision exact undo.

## Material product finding: preview/commit authority mismatch

### Contract

`SPEC.md` requires:

1. “Preview and commit use the same `MoveNode` operation.”
2. A gesture captures the paint fence and monotonic gesture ID.
3. Haskell resolves pointer samples to a common `MoveElement`, returns a non-authoritative preview, and stores that exact operation.
4. Commit carries only the gesture key and consumes that stored operation.

These requirements prevent browser preview policy from diverging from the operation eventually verified and committed.

### Observed implementation

There are no `Gesture`, `gesture`, `preview`, pointer-sample, or commit-key symbols in:

```text
packages/slideblaster-protocol/src/SlideBlaster/Protocol/ProductV2.hs
packages/slideblaster-app/src/SlideBlaster/App/CanvasEdit.hs
apps/slideblaster-web-wasm/src/SlideBlaster/Adapter/Web/ProductV2.hs
```

The closed request ADT contains only:

```text
OpenSource
ProductV2WorkspaceSnapshot
AcknowledgePaint
SelectAdmittedNode
MoveAdmittedNode revision fence node point
UndoProduct
RedoProduct
ReplaceProductSource
```

`hosts/web/src/ui/product-v2-renderer.js` creates and positions `.product-v2-node-ghost` directly during `pointermove`. On `pointerup` it calls `options.onMove(identity, point)`. `hosts/web/src/main.js` then constructs `requestMoveNode(revision, displayedFence, identity, centre)`. Haskell first constructs/captures the common `MoveElement` only while executing that pointer-up request.

### Reproduction

```sh
grep -RInE 'Gesture|gesture|preview|commit.*key|pointer.*sample' \
  packages/slideblaster-protocol/src/SlideBlaster/Protocol/ProductV2.hs \
  packages/slideblaster-app/src/SlideBlaster/App/CanvasEdit.hs \
  apps/slideblaster-web-wasm/src/SlideBlaster/Adapter/Web/ProductV2.hs

grep -nE 'ghost|pointermove|pointerup|onMove|requestMoveNode' \
  hosts/web/src/ui/product-v2-renderer.js hosts/web/src/main.js
```

The first command returns no matches; the second locates browser ghost ownership and fresh move construction on release.

### Required repair

Introduce the specified lease-fenced gesture state and closed commands: Haskell receives/validates pointer samples, constructs and stores the exact common operation under a monotonic gesture identity, exposes its non-authoritative preview projection, and commit consumes only that identity. Direct source changes, undo/redo, replacement analysis, newer paint authority, cancellation, and stale responses must invalidate the gesture atomically. Add pure protocol/App laws and a real-browser assertion that the operation previewed is the operation committed; do not merely rename the current pointer-up request.

## SPEC acceptance matrix

| Requirement | Status | Evidence |
| --- | --- | --- |
| `make dev`/packaged real Wasm editor loads tracked fixture | PASS | Full Wasm build; active static resources all HTTP 200; real Chrome opens it. |
| Exact authored bytes/revision are sole persistence authority | PASS | Source/TikZ/App/product/2 laws; browser compares protocol base16, not textarea alone. |
| Common Canvas/Presentation/Render model is used; bounded TikZ remains adapter | PASS | `TikZ.Adapter`, `App.CanvasEdit`, `Engine.CommonTikz`; native focused tests. |
| Haskell owns typed edit, projection, semantic verification, history, leases, acceptance | PASS for final move/commit | Common `MoveElement`, private verified inverse, opaque App successor, one history transition, paint fences. Preview exception is separately FAIL below. |
| Preview and commit use the same Haskell-owned stored operation | **FAIL** | Browser owns ghost preview; no gesture ID/preview command/stored operation/commit key exists. |
| Candidate edits check revision, bounds, expected bytes, ordering/non-overlap/locality | PASS within bounded inverse | Existing source/TikZ laws plus common locality and browser exact moved bytes. |
| Reparse and intended-semantic equality precede history | PASS | Bounded verified inverse and semantic-verification atomicity law; App accepts opaque verified successor. |
| One accepted drag creates one source/history revision | PASS | Browser revision 0→1; App replayed-completion rejection and undo availability. |
| No-op creates no patch/history/revision | PASS | TikZ common and product/2 no-op laws. |
| Exact undo restores original bytes at fresh revision | PASS | Native product/2 law and Chrome 119-byte revision-2 result. |
| Paint fenced by session/revision/ticket/surface | PASS | App/product/2 laws and closed fence validation. |
| Connector source remains unchanged and successor geometry follows | PASS | Native byte/geometry laws; browser exact source equality and connector `(4,5)->(9,8)`. |
| Stale revision/paint/session and delayed response reject atomically | PASS for implemented request model | Native stale tests, host stale reducer; browser serializes operations. Gesture-key cancellation model is absent. |
| Unsupported/ambiguous/syntax-only canvas edits reject atomically | PASS | TikZ and product/2 laws. |
| Invalid direct source keeps last-good paint inert | PASS at native protocol/host projection level | Product/2 direct invalidation law; host deactivation logic inspected. Not exercised by tracked Chrome smoke. |
| Closed, source-redacted product/2 JSON | PASS | Haskell product/2 and Node validator tests. |
| Product/1 remains unchanged | PASS | No product/1 source/test diff; its 8 laws pass. |
| Shared packages remain native/Wasm portable | PASS | Native build/focused tests, real Wasm build, forbidden-import scan. |
| JavaScript is validator/painter/pointer adapter only | **FAIL for preview authority as specified** | No parsing/history/revision policy, but browser owns drag preview and does not consume a Haskell preview operation. |
| Real pointer path to exact target `(4,5)` | PASS | CDP mouse events and exact resulting protocol/geometry assertions. |
| Zero page/console errors and cleanup | PASS | Browser assertion; no residual process/profile/server. |
| Broad native suite | **FAIL (pre-existing, unrelated)** | 15/16 pass; unchanged catalog suite fails identically on baseline `dev`. |
| Root manifests/current docs/legacy untouched in implementation stage | PASS | Exact changed-path inventory. |
| Generated artifacts ignored and untracked | PASS | `dist-newstyle`, Wasm dist-newstyle, and `hosts/web/dist` are `!!`; `git ls-files` returns none. |
| No new external dependency | PASS | Existing workspace/Cabal dependencies only; dependency-free host; no lockfile/node_modules. |
| Complete user-visible product-owner demonstration/acceptance | UNVERIFIED by role | Technical browser smoke passed, but product-owner observation and acceptance remain pending in `REVIEW.md`. |

## Residual risks and deferred scope

- Repair of the Haskell-owned preview/commit gesture transaction is required before V1 can be verified.
- The unrelated catalog failure leaves the repository-wide native matrix red and should be handled in its own ownership scope; this verifier did not modify catalog files.
- The tracked Chrome smoke does not exercise stale in-flight gesture cancellation, pointer cancel, direct-invalid last-good DOM identity/inertness, unsupported browser action, redo, malformed wire data in-browser, or a delayed render race. Pure/Node tests cover parts of those boundaries, but end-to-end coverage remains incomplete.
- Structured node text is intentionally not painted because exact font measurement is excluded; the UI labels the source identity instead.
- General TikZ, resize, properties, content editing, insertion/catalog, collaboration, Git persistence, presenter/export, deployment, and legacy migration remain deliberately deferred.
- Product-owner observation, specification acceptance, exact-diff approval, integration authorization, and closure are all pending and cannot be inferred from this evidence.

## Conclusion

The implementation proves a substantial real vertical path: exact noncanonical fixture bytes enter one App-rooted product/2 runtime, common geometry is painted by real GHC-Wasm, a real pointer drag commits a verified local source edit, the connector follows without source rewrite, and exact undo succeeds. Nevertheless, Stage V1 is `NEEDS_REPAIR` because the accepted Haskell-owned preview/commit transaction is absent. The broad native matrix also retains a confirmed pre-existing catalog failure.

This report is evidence, not product acceptance and not an accepted architectural or product decision.
