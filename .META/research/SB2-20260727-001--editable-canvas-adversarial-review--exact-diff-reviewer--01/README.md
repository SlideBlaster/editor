# Research artifact: editable-canvas-adversarial-review

- Slug: `SB2-20260727-001--editable-canvas-adversarial-review--exact-diff-reviewer--01`
- Session: `SB2-20260727-001`
- Task: `editable-canvas-adversarial-review`
- Agent: `exact-diff-reviewer`
- Run: `01`
- Created: `2026-07-27`
- Updated: `2026-07-27`
- Status: `complete`
- Disposition: `APPROVE WITH NOTES`

## Question

Does the exact current SB2-20260727-001 local diff, after the Haskell and browser repairs and the final rejected-preview smoke edit, preserve source authority and close prior findings H1–H4 and B1–B4 without introducing a material race, stale-state, closed-schema, unsafe-DOM, native/Wasm portability, browser-composition, or cleanup defect?

## Source and provenance

Review was read-only except for this assigned report and was performed in `/home/t/Documents/slide/slideBlaster/sb2-SB2-20260727-001`.

- Branch: `session/SB2-20260727-001`.
- HEAD and session registration baseline: `cbe29eb4f989f830b17157812e2c8180dbb690e0` (`chore: register editable canvas session`).
- Baseline branch: local `dev`, also at `cbe29eb4f989f830b17157812e2c8180dbb690e0` when initially reviewed. There are no configured Git remotes.
- Diff scope: all tracked changes against `cbe29eb4f989f830b17157812e2c8180dbb690e0`, plus every untracked implementation module, fixture, test, and prior research report. The only excluded untracked input was this report while it was being authored.
- Exact final input size before this report: tracked patch 2,611 lines / 105,611 bytes; untracked input 5,917 lines / 244,469 bytes; combined 8,528 lines / 350,080 bytes.
- Tracked implementation/session diff: 24 files, 1,463 insertions and 541 deletions. Untracked implementation includes Product/2 protocol/runtime, App/TikZ/common-render seams, host schema/policy/renderer, three host tests, and two identical fixture copies.
- Fixture identity from the initial complete review: both `packages/slideblaster-tikz/test/fixtures/common-noncanonical.tikz` and `hosts/web/fixtures/common-noncanonical.tikz` are 119 bytes with SHA-256 `4ec5d520dc220ec737c01c55b9c75f4dd4f5c193724d7a4141f5347b9f7dff6f`.
- Product/1 check: `git diff --quiet ...` over `Protocol/Product.hs`, the Product/1 Wasm adapter, Product/1 renderer, and Product/1 test returned success again; the focused Product/1 suite passed all eight named checks.
- Catalog and root project manifests are unchanged. The known `sports.camper-1` catalog failure was independently reproduced during the earlier complete review on the same untouched `dev` baseline; it is an unrelated baseline note, not a failure of this review diff.

## Final recheck reproduction and results

Commands ran from the session worktree unless a directory is stated otherwise.

### Provenance, syntax, diff, and session

```sh
git status --short --branch
git rev-parse HEAD
git branch --show-current
git diff --check cbe29eb4f989f830b17157812e2c8180dbb690e0 --
git diff --stat cbe29eb4f989f830b17157812e2c8180dbb690e0 --
git ls-files --others --exclude-standard
cd hosts/web
find src test -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) \
  -print0 | sort -z | xargs -0 -n1 node --check
cd ../..
./scripts/session/validate.sh SB2-20260727-001
```

Results: HEAD/branch remain exactly as recorded above; `git diff --check` is clean; all 21 discovered host source/test JavaScript files parse. The final session validator, run after this report update, reported `Valid implementation session (active): SB2-20260727-001`.

### Focused Haskell product/app/protocol path

```sh
cabal --project-file=cabal.project.native test \
  slideblaster-tikz-tests \
  slideblaster-app-tests \
  slideblaster-engine-tests \
  slideblaster-protocol-tests \
  slideblaster-product-protocol-tests \
  slideblaster-product-v2-protocol-tests \
  --test-show-details=direct
```

Result: all six suites passed under native GHC 9.10.3 with profile `-O1`. Visible named coverage included 22 TikZ/common adapter laws, 18 protocol-v1 checks, eight unchanged Product/1 checks, and 15 Product/2 checks. Product/2 again passed distinct/redacted session exhaustion, closed gesture JSON, monotonic IDs, Haskell-owned latest-preview commit, no-op, gesture races, transition invalidation, unsupported-preview atomicity, exact undo/redo, and invalid-source last-good inertness. App and Engine suites passed.

### Host Node tests

```sh
cd hosts/web
npm test
```

Result: 22/22 tests passed, zero failures/skips. Coverage includes preview-rejection cancellation and atomicity; validation failures for any gesture, preview, source, revision, history, or displayed-paint mutation; dirty-draft adoption policy; source-redacted trace policy; closed gesture schema; all gesture success/error enums including `drag_preview_rejected`, `drag_cancelled`, and `session_id_exhausted`; stale response reduction; and exact pointer conversion.

### Full Wasm packaging

```sh
./scripts/build-wasm.sh
sha256sum hosts/web/dist/slideblaster-web-wasm.wasm \
  hosts/web/dist/slideblaster-web-wasm.js
wc -c hosts/web/dist/slideblaster-web-wasm.wasm \
  hosts/web/dist/slideblaster-web-wasm.js
```

Result: pass. Cabal reported the reactor `Up to date`; the script copied/generated and packaged the complete host artifact. Cabal emitted its known tool-version warning that Cabal 3.14.2.0 does not recognize GHC 9.14.1.20260330, not a build failure. Wasm: 6,013,327 bytes, SHA-256 `87edfe52c59688c5627bc44e300a9e11677896dd226797a345b866503f50cf3a`. Generated JSFFI: 5,342 bytes, SHA-256 `1160ffc16acda33c88122f797dee973ca89e155fe8b0a56205e5e18736c486f5`. Generated build/dist paths remain ignored and untracked.

### Real Chrome plus production Wasm smoke

```sh
cd hosts/web
npm run test:browser
```

Result against real `google-chrome`:

```text
PASS browser smoke (google-chrome): isolated real-Wasm rejected preview
preserved source/history/render and cancelled old commit; ready+writable
revision 0; selected alpha; one begin/commit dragged to (4,5) revision 1;
undo restored 119 exact bytes at revision 2; dirty draft preserved with
inert canvas; 0 page/console errors
```

The rejected-preview probe is meaningful browser+Wasm composition evidence rather than a mock or production backdoor:

1. The normal page startup first calls production `loadSlideBlasterReactor()` in `main.js`, creating the live UI reactor.
2. Inside Chrome, `runIsolatedRejectedPreview` dynamically imports the same production `src/wasm/load-reactor.js`, `src/protocol/product-v2.js`, and `src/product-v2-policy.js`, then calls `loadSlideBlasterReactor()` again. The loader fetches and instantiates the packaged production `.wasm`, ties the production JSFFI/WASI imports, calls `sb_start`, and exposes the real `sb_product_v2_dispatch` export. Each loader call creates fresh exports, WASI, and `WebAssembly.Instance`; therefore this is an isolated second real production reactor, not the live UI state and not a JavaScript model.
3. Every isolated response crosses production `decodeProductV2Response`, which validates and defensively copies the exact closed Haskell response schema. The rejection then crosses production `decidePreviewTransition`; no alternate test decoder or cancellation policy exists.
4. The sequence is exactly open fixture, acknowledge the offered paint, select `alpha`, begin drag, valid preview `(4,5)`, unsupported preview `(1/3,7)`, attempt commit with the old gesture ID, then request a workspace snapshot.
5. Assertions prove `drag_preview_rejected`; policy `{kind:"rejected", sendCommit:false, clearGesture:true}`; null gesture and preview; exact source base16 and revision preservation; unchanged `canUndo`/`canRedo`; byte-for-byte JSON equality of displayed paint; old commit rejected as `gesture_not_active`; and a final snapshot preserving exact source, revision, history availability, and displayed paint.
6. The live UI is compared before and after the isolated probe: its authoritative source/revision remain unchanged and its ghost count remains zero. The probe has no reference to live `reactor`, `clientState`, `gestureFlow`, render controller, or DOM mutation hooks. Production source inspection found no smoke/test global, test-only Wasm export, state injection seam, or unsafe DOM/eval primitive.
7. The separate live CDP pointer drag still proves exactly one `begin_drag` and exactly one `commit_drag`, preview-before-commit ordering, latest preview centre `(4,5)`, exact commit request keys, one source revision, exact moved bytes, connector `(4,5)->(9,8)`, and source-redacted trace. Thus the isolated failure proof does not replace or weaken the real live event-pump proof.
8. Page/runtime error collectors remained empty through both reactors and the later live UI drag, undo, and dirty-draft checks.

### Profile cleanup and active-path safety checks

```sh
find /tmp -maxdepth 1 -type d -name 'slideblaster-browser-smoke-*' -print
ps -eo pid=,comm=,args= | \
  awk '$2 ~ /^(chrome|chromium|google-chrome)$/ && \
       $0 ~ /slideblaster-browser-smoke-/ {print}'

git diff --quiet cbe29eb4f989f830b17157812e2c8180dbb690e0 -- \
  packages/slideblaster-protocol/src/SlideBlaster/Protocol/Product.hs \
  apps/slideblaster-web-wasm/src/SlideBlaster/Adapter/Web/Product.hs \
  hosts/web/src/ui/product-renderer.js \
  packages/slideblaster-protocol/test/ProductMain.hs

grep -RInE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function|DOMParser' \
  hosts/web/src/main.js hosts/web/src/product-v2-policy.js \
  hosts/web/src/protocol/product-v2.js hosts/web/src/ui/product-v2-renderer.js

grep -RInE 'GHC\.Wasm\.Prim|JavaScriptFFI|foreign (import|export) javascript|System\.Process|System\.Directory|System\.FilePath|Network\.' \
  packages/slideblaster-app/src/SlideBlaster/App/CanvasEdit.hs \
  packages/slideblaster-engine/src/SlideBlaster/Engine/CommonTikz.hs \
  packages/slideblaster-protocol/src/SlideBlaster/Protocol/ProductV2.hs \
  packages/slideblaster-tikz/src/SlideBlaster/TikZ/Adapter.hs
```

Results: profile scan was empty before the browser run and empty after it; the process scan found no actual Chrome/Chromium process using a smoke profile. `removeProfile` now retries removal, waits, checks for recreation, and fails the smoke if the path remains after 20 attempts. The prior low cleanup finding is resolved in this run. Product/1 remained unchanged. Unsafe DOM/eval and target-specific shared-import scans returned no matches.

## Prior finding recheck

| Finding | Final status | Exact evidence |
| --- | --- | --- |
| H1: failed replacement preview retained an old committable operation | **Resolved; no regression** | Product/2 maps App capture or TikZ projection failure to `drag_preview_rejected` and clears gesture. Focused Haskell `unsupported preview is atomic` passed. The final Chrome probe now independently obtains a valid preview, rejects unsupported `(1/3,7)`, observes gesture/preview null, and proves the old commit returns `gesture_not_active` with source/history/paint unchanged. |
| H2: forgeable/public `VerifiedCanvasSuccessor` semantic claim | **Resolved; no regression** | The false proof symbol/sealer remain absent. The public App mechanical commit boundary is honestly documented; active Product/2 obtains successors only from the TikZ adapter's reparse/adopt/intended-semantic check. Active-path symbol inspection and all focused suites passed. |
| H3: Wasm `MVar` result/state not forced | **Resolved; no regression** | Product/2 Wasm dispatch evaluates next state and strict response before returning them through `modifyMVar`. Packaged Wasm build passed, and two independent stateful production reactor instances ran successfully in real Chrome. |
| H4: session ID exhaustion classified as analysis | **Resolved; no regression** | Product/2 retains the distinct `session_id_exhausted` boundary and stable redacted message. The named Haskell exhaustion test and closed Node error-enum test passed. |
| B1: JS schema omitted rejection/exhaustion and cancellation transition | **Resolved; no regression** | Production schema includes the closed outcomes/codes; production `decidePreviewTransition` verifies cancellation plus source/revision/history/displayed-paint preservation and forbids commit. Node tests passed, and the exact production decoder/policy ran against real Haskell responses in Chrome. |
| B2: dirty textarea draft could be overwritten | **Resolved; no regression** | Dirty policy still disables every workspace adopter and canvas while leaving Apply enabled. Chrome preserved the exact draft, retained authoritative Haskell bytes, and kept canvas inert. |
| B3: smoke lacked exact one-release/one-commit and rejected-preview coverage | **Resolved** | Live CDP pointer path asserts exactly one begin and one commit. The new isolated second production reactor in the same real Chrome run executes the complete unsupported-preview sequence and proves cancellation, no commit decision, old gesture inactivity, exact source/revision/history/displayed-paint preservation, no live ghost/authority mutation, and zero errors. This is real packaged browser+Wasm composition evidence without a production test backdoor. |
| B4: protocol trace duplicated source | **Resolved; no regression** | Production trace remains source-redacted. Node hostile-source tests passed; Chrome asserts commit trace has no workspace or moved source base16. |
| Low: Chrome profile could remain after successful smoke | **Resolved** | Cleanup now retries and verifies absence. Pre-run and post-run `/tmp/slideblaster-browser-smoke-*` scans were empty; no actual profile-using browser process remained. A failure to remove or a recreated profile now fails the test rather than reporting success. |

## New findings by severity

### High

None.

### Medium

None.

### Low

None newly introduced. The notes below are coverage boundaries or pre-existing design responsibilities, not defects in the final B3/profile repair.

## Limitations and residual risk

- The rejected-preview case deliberately uses an isolated second production reactor driven from browser JavaScript rather than synthesizing an unsupported coordinate through the live pointer geometry. This is accurate end-to-end evidence for packaged loader + real Wasm state machine + production wire decoder + production cancellation policy and proves no live state mutation. It does not claim that the live DOM gesture pump itself encountered rejection; Node policy tests cover that pump decision, while the separate live UI smoke covers its one-begin/one-commit success path.
- Real Chrome still does not cover pointer cancellation/lost capture, delayed-response races, malformed in-browser wire input, direct-invalid last-good DOM continuity, or redo. Pure Haskell/Node tests cover substantial portions, but not every complete browser composition.
- The broad all-package native suite was not rerun in this final recheck because the requested scope was the affected product/app/protocol and host/Wasm/Chrome path. Earlier independent evidence records the unchanged `slideblaster-catalog-tests` `sports.camper-1` failure on both session and untouched baseline; it remains unrelated.
- The Wasm build script reported the reactor up to date rather than recompiling every dependency, but it packaged the current artifact and real Chrome instantiated and exercised two instances of the current Product/2 export. Cabal's unsupported-new-GHC-version warning remains an infrastructure/tool-recognition note, not a failed build.
- The App mechanical commit API remains public and relies on a format adapter/caller to supply a semantically verified successor. Its documentation is honest and the active Product/2 wire cannot forge that state; future compositions must not treat `commitCanvasSuccessor` itself as semantic verification.
- Structured node text/font measurement and broader excluded syntax/product capabilities remain deliberately deferred by the session specification.
- Product-owner observation, specification acceptance, exact-diff approval, integration, and closure remain pending. They cannot be inferred from tests, this reviewer disposition, or session validation.

## Conclusion

`APPROVE WITH NOTES`.

H1–H4 and B1–B4 are resolved in the exact current implementation and tests, with no material regression found. B3 now has both halves of the required evidence: the live UI proves exactly one begin and one commit, while an isolated second real production Wasm reactor inside Chrome proves the complete valid-then-unsupported preview cancellation path through production decoding and policy without mutating live authority. The prior profile-cleanup finding is also resolved and fail-closed. Remaining items are accurately bounded coverage/design notes, not material blockers.

This review report is evidence, not product-owner acceptance and not an accepted architectural or product decision.
