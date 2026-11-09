---
status: proposed
updated: 2026-07-23
---

# P2 Haskell source-session history

This specification proposes the smallest browser-visible vertical slice that
makes shared Haskell, rather than browser JavaScript, own source revision and
Undo/Redo policy.

It is not a claim of general editor parity. The slice covers one in-memory
session over the bounded TikZ document from
[`slice1-tikz-subset.md`](slice1-tikz-subset.md), direct authored source
changes, exact source history, invalid-source recovery, and the authority fence
between current source and derived canvas DOM. Git, durable history, deck
structure, collaboration, and semantic canvas edits remain later slices.

## User-visible proof

Starting with one valid bounded TikZ fixture, the real browser and GHC-Wasm
composition must demonstrate all of the following:

1. Haskell opens exact authored bytes as session revision 0; Undo and Redo are
   disabled.
2. A changed textarea input is admitted by Haskell as revision 1, creates one
   exact source-history entry, enables Undo, and clears Redo.
3. Undo restores the exact revision-0 bytes at a new monotonic revision 2.
   Redo restores the exact edited bytes at revision 3.
4. Undo followed by a changed direct edit creates a new branch and clears Redo.
   A byte-identical admission advances neither revision nor history and does not
   clear Redo.
5. Malformed source is accepted as exact current source, remains editable and
   savable, reports Haskell diagnostics, and enables Undo. The last successfully
   painted canvas stays visible but inert.
6. Undo from malformed source restores the prior valid bytes at a new revision
   and only re-enables the canvas after that revision is painted. Redo can
   restore the malformed bytes at another new revision.
7. Two source inputs issued before the first Wasm response completes cannot
   cause the older response or paint to overwrite or authorize the newer
   textarea value.
8. Toolbar and source-focused keyboard history commands use the same Haskell
   transition. No JavaScript revision counter or history stack decides the
   result.

P2 is complete only when this path runs through a shared Haskell state
transition, a versioned application protocol, the real Wasm reactor, host DOM
translation, and a real-browser assertion. A source-only Haskell package or
enabled toolbar without that end-to-end proof is an intermediate checkpoint.

## Evidence and intentional migration difference

The useful legacy behavior is concentrated in:

- `editor/packages/app/src/createApp.ts:453-500`, where source revisions fence
  canvas authority;
- `editor/packages/app/src/createApp.ts:780-805` and `:924-947`, where a
  successful generated edit snapshots exact pre-edit source and Undo/Redo swap
  whole-source values;
- `editor/packages/app/src/createApp.ts:1302-1405`, where render sequence and
  source revision prevent stale paint authorization;
- `editor/packages/app/src/createApp.ts:1449-1459`, where direct source remains
  authoritative and invalidates generated redo;
- `editor/packages/app/src/createApp.ts:1994-2000`, where opening another
  document clears in-memory history;
- `editor/e2e/browser-model.spec.ts:13-133` and
  `editor/e2e/model/state.ts:82-118`, which independently model branching,
  no-op, reload, and invalid-source behavior.

There is one deliberate behavior change. The legacy textarea owns native text
undo, so direct typing does **not** enter its generated `undoStack`; the comment
at `createApp.ts:1453-1455` states that explicitly. The P2 requirement instead
puts direct authored changes in shared Haskell history. Therefore the legacy
assertion at `editor/e2e/browser-model.spec.ts:112` that Undo is disabled after
malformed direct input is a migration counterexample. P2 must replace it with:
malformed source is an undoable Haskell source transaction.

There is also an ambiguity in that legacy evidence: the independent model's
`directSourceEdit` calls `recordMutation`, but the corresponding browser test
uses `assertDocumentOnly` and never asks the real controller to Undo that
direct edit. The concrete controller comment and malformed-source assertion
show the implemented browser behavior; the new requirement resolves the
ambiguity in favor of shared direct-source history.

The current host also is not the new oracle. It owns `sourceRevision` in
`slideBlaster2/hosts/web/src/main.js:25-55` and sends full stateless snapshots
through `slideblaster.engine/1`. P2 removes that revision authority from
JavaScript while retaining the existing engine protocol for its Slice 0
inspection/exact-replacement use cases.

## Authority model

P2 distinguishes four values that must not be collapsed:

- **Draft source** is the newest UTF-8 value visible in the textarea. It may be
  waiting for admission and must never be overwritten by an older response.
- **Accepted source** is the exact `SourceBufferSnapshot` in the Haskell
  `AppSession`. It is the only input to shared history, parsing, persistence,
  and future semantic commands.
- **Current document** is the Haskell parse/elaboration result for the accepted
  snapshot. It may be semantically ready or syntax-only; invalid source still
  has an accepted exact snapshot.
- **Painted canvas** is disposable DOM derived from a revision-tagged
  `RenderPlan`. It never supplies source or semantic state back to Haskell.

While a draft differs from accepted source, source-dependent actions are
pending and the canvas is inert. Once an invalid draft is accepted it is
authoritative and savable, but the canvas remains inert because no writable
current document exists.

```text
textarea input
  -> capture exact UTF-8 draft
  -> immediately revoke the painted-canvas lease
  -> serialized ReplaceSource(expected session/revision, exact bytes)
  -> Haskell AppSession transition
       -> exact history + new monotonic snapshot
       -> recoverable parse/elaboration
       -> current diagnostics and optional RenderPlan
  -> correlated response
       -> stale relative to a newer draft: retain draft, continue queue
       -> syntax-only: retain last-good DOM, keep it inert
       -> ready: paint with a new render ticket
  -> authorize canvas only if session, revision, draft, and ticket are current
```

The browser may retain last-good DOM for continuity. Retention grants no
authority. Every future canvas intent must carry the revision from which its
DOM was painted, and Haskell must independently compare that revision with the
accepted snapshot before considering the intent.

## Proposed Haskell state

The public app API should expose domain operations, not stack constructors. Its
conceptual state is:

```text
AppSession
  session identity
  present DocumentSnapshot
  past    sequence of exact authored ByteString values
  future  sequence of exact authored ByteString values
```

Only exact source bytes are historical. CST nodes, semantic values,
diagnostics, provenance, and render plans are derived again from each restored
snapshot. This avoids reviving semantic objects whose provenance belongs to a
different revision.

The Haskell session does not retain a special “last painted” semantic object.
When the present document is ready it derives a current revision-tagged
`RenderPlan`; when it is syntax-only it returns diagnostics and no plan. The
browser may retain its latest successfully painted DOM as an inert visual, but
that effect state is never usable as Haskell document state.

The proposed initial limit is 100 past snapshots, matching the legacy
controller. The oldest past entry is discarded only after a successful changed
transaction exceeds that limit. `future` cannot exceed the same reachable
history. Compression or patch-backed storage may be introduced later if it is
observationally exact; it cannot change these laws.

A newly opened source receives a fresh session identity, revision 0, empty
history, and a new parse/elaboration. Session identity, rather than an
artificial revision bump, distinguishes a late response from a prior open of
the same bytes. History is in-memory for P2 and is cleared by open or reload.

## Source-history laws

**SB2-P2-001 Open.** Opening exact bytes creates a fresh session at revision 0
with empty past/future. The bytes may be malformed or outside the semantic
subset. A new session identity invalidates every prior request and paint.

**SB2-P2-002 Changed direct authorship.** `ReplaceSource` carries the current
session identity, expected revision, and complete proposed bytes. If session
and revision match and bytes differ, the transition:

1. advances the snapshot exactly once;
2. pushes the previous exact bytes to `past`;
3. clears `future`;
4. reparses/elaborates the successor, including syntax-only recovery; and
5. returns the exact successor plus authoritative history availability.

Textarea input, paste, cut, the existing selection replacement action, and any
later source-pane transform all use this operation. None may bypass it through
the stateless engine replacement path.

**SB2-P2-003 No-op.** If proposed bytes equal present bytes, `ReplaceSource`
returns an unchanged result. Revision, past, future, diagnostics, and current
render authorization are unchanged. In particular, a no-op after Undo does not
clear Redo.

**SB2-P2-004 Undo.** `Undo` carries current session identity and expected
revision. With a non-empty `past`, it pops the newest exact bytes, pushes
current exact bytes to `future`, and reparses those restored bytes as a new
snapshot at `current revision + 1`. It does not resurrect the historical
revision number.

**SB2-P2-005 Redo.** `Redo` is symmetric: pop `future`, push current exact bytes
to `past`, and restore at one fresh monotonic revision. A successful changed
direct or future semantic transaction after Undo clears `future`.

**SB2-P2-006 Invalid source.** A malformed or unsupported replacement is a
successful source/history transition, not a rejected edit. Exact bytes and the
new revision become current; typed diagnostics and syntax-only state replace
writable semantics; the last-good render remains display-only. Undo and Redo
may cross valid and invalid snapshots repeatedly.

**SB2-P2-007 Atomic rejection.** A stale session, stale revision, exhausted
revision, unavailable Undo/Redo, malformed protocol message, or browser
text-to-byte fidelity failure changes no Haskell source, history, document, or
current derivation. Errors do not echo authored bytes.

**SB2-P2-008 Revision domain.** Revisions are the shared source package's
unsigned 64-bit values. App protocol v1 encodes them as canonical decimal
strings, so JavaScript compares and displays them without arithmetic or IEEE
754 truncation. Increment and exhaustion stay in Haskell.

**SB2-P2-009 Canvas lease.** Every accepted source change immediately invalidates
the old painted revision. A canvas becomes writable only after a ready
`RenderPlan` for the accepted revision completes a non-stale paint. Even if the
same exact bytes return through Undo, the new revision requires a fresh paint
lease.

**SB2-P2-010 Persistence.** P2 Save writes only accepted Haskell bytes. It is
disabled while a draft is pending or unencodable. Accepted invalid source is
savable. View preferences and canvas DOM never enter source history.

## Revision examples

Let `A` and `B` be different valid byte strings and `X` malformed bytes.

| Operation        | Present result | Revision | Past    | Future | Canvas result           |
| ---------------- | -------------- | -------: | ------- | ------ | ----------------------- |
| Open `A`         | `A`            |        0 | `[]`    | `[]`   | ready after paint       |
| Replace with `B` | `B`            |        1 | `[A]`   | `[]`   | pending, then ready     |
| Undo             | `A`            |        2 | `[]`    | `[B]`  | pending, then ready     |
| Replace with `A` | `A`            |        2 | `[]`    | `[B]`  | unchanged; Redo remains |
| Redo             | `B`            |        3 | `[A]`   | `[]`   | pending, then ready     |
| Replace with `X` | `X`            |        4 | `[A,B]` | `[]`   | last-good DOM inert     |
| Undo             | `B`            |        5 | `[A]`   | `[X]`  | fresh paint required    |
| Redo             | `X`            |        6 | `[A,B]` | `[]`   | last-good DOM inert     |

Opening another source, even byte-identical `X`, creates a new session at
revision 0 and clears both stacks. A response tagged with the old session is
stale.

## Browser admission and stale-response workflow

JavaScript owns event capture, transport ordering, focus/caret, DOM rendering,
and ephemeral pending state. It does not own accepted revision, history
branching, source interpretation, or semantic command authorization.

For P2, one non-composition DOM `input` event is proposed as one direct source
transaction. Paste and cut are each one transaction. IME input is buffered
while `isComposing` and the final composition value is one transaction at
`compositionend`. This event-grained rule is intentionally simple and
testable; coalesced typing is an unresolved product decision below.

The browser adapter uses this queue:

1. On input, capture the textarea string and validate a lossless UTF-8
   encode/decode round trip. Record a monotonically ordered client operation
   and immediately make canvas and source-dependent commands inert.
2. Preserve every committed event value in order. Do not coalesce two
   different input values while the previous Wasm call is in flight; otherwise
   an authored transaction would disappear from shared history.
3. Submit at most one source transition at a time, using the Haskell-accepted
   session and revision from the preceding response.
4. When a response arrives, validate protocol, request correlation, session,
   and the exact requested successor. Update the accepted Haskell state, but
   never assign its source into the textarea if a newer draft or queued event
   exists.
5. Continue with the next queued input using the returned revision. Until the
   queue drains, Undo/Redo, Save, source replacement, and canvas actions remain
   disabled. Additional textarea input remains allowed.
6. When the queue drains, require accepted response bytes to equal a fresh
   encoding of the current textarea value. Only then update revision/history
   chrome and begin current-document rendering.
7. On typed rejection, retain the draft visibly, retain the accepted state
   unchanged, keep source-dependent actions inert, and surface a non-source-
   echoing diagnostic plus an explicit way to retry or restore accepted source.

This serialization is transport policy, not history policy. The Haskell stale
session/revision checks remain mandatory even though a correct browser queue
normally prevents them.

Undo and Redo are accepted only when no source admission is pending. Their
correlated response is first checked for an exact textarea round trip, then
assigned programmatically under an input-suppression guard. The response's
revision and `canUndo`/`canRedo` values update the chrome; JavaScript never
derives those values from local arrays. Focus and caret placement are ephemeral
host concerns and do not change the source transition.

Toolbar Undo/Redo and `Ctrl`/`Cmd`+`Z`,
`Ctrl`/`Cmd`+`Shift`+`Z`, and `Ctrl`+`Y` dispatch Haskell history commands even
while the textarea is focused. The host must prevent native textarea history.
For Chromium, cancelable `beforeinput` events with `inputType` `historyUndo` or
`historyRedo` must also route to Haskell so the context-menu path cannot create
a second history owner. Programmatic source updates from Haskell must not emit a
new direct input transaction.

Async load is separately fenced. The host captures session, accepted revision,
and draft generation before reading storage. If any changes before the read
returns, the loaded result is ignored. A successful load issues `Open`, receives
a fresh Haskell session identity, clears pending input, and invalidates all old
render tickets.

## Invalid source and DOM rendering

The bounded TikZ parser already establishes the required source-side behavior:
`slideBlaster2/packages/slideblaster-tikz/src/SlideBlaster/TikZ/Document.hs:56-91`
opens revisioned exact snapshots and admits invalid direct source without
retaining writable semantics. Its focused evidence is
`slideBlaster2/packages/slideblaster-tikz/test/Main.hs:225-275`. That package is
an in-flight dependency of this proposed slice until its independent review is
complete.

On a ready response, the browser receives a renderer-neutral plan tagged with
session and source revision. Rendering receives an additional host-only render
ticket. It should build into a detached subtree and swap it into the live
canvas only after checking:

- response session still equals current session;
- plan revision still equals accepted source revision;
- no newer draft or source operation is pending;
- render ticket is still current; and
- current textarea bytes equal accepted source bytes.

If any check fails, discard the detached result. If parsing is syntax-only, do
not paint a fallback and do not clear last-good DOM. Mark that DOM `inert` and
`aria-disabled="true"`, clear transient canvas selection, expose the current
Haskell diagnostic, and reject canvas gestures. Undoing back to valid source
starts a fresh render; it cannot merely relabel old DOM with the new revision.

The browser renderer may translate typed plan fields to DOM/SVG and invoke DOM
measurement capabilities. It may not parse TikZ, infer semantic identity from
DOM, serialize DOM to source, or manufacture an editable fallback for
unsupported syntax.

If the bounded plan has not yet been integrated into the browser, the pure
history work may proceed, but P2 cannot claim the last-good-canvas acceptance
criteria. P2's browser gate therefore depends on accepted Slice 1 document and
render-plan integration rather than duplicating that model in JavaScript.

## Application protocol boundary

History is application-session state, not a host capability and not an
extension of the stateless `slideblaster.engine/1` request meaning. P2 proposes
a separate closed protocol identifier, `slideblaster.app/1`, with:

- `open`;
- `state`;
- `replace_source`;
- `undo`; and
- `redo`.

Every request has an opaque string request ID. Every command except `open`
carries an opaque Haskell-issued session identity; mutating commands also carry
the expected revision. Exact source is lowercase base16 with an explicit
`base16` encoding marker. Session identities and revisions are canonical
unsigned decimal strings on the wire.

A successful state response contains:

- the matching request and session identities;
- outcome (`opened`, `changed`, `unchanged`, `undone`, or `redone`);
- the exact current source snapshot;
- Haskell-derived `canUndo` and `canRedo`;
- current document state (`ready` or `syntax_only`) and typed diagnostics; and
- a current revision-tagged render plan only when current source is ready.

Protocol errors are typed, closed, and never include authored bytes. At minimum
they distinguish malformed/unknown messages, stale session, stale revision,
revision exhaustion, and unavailable history direction. The protocol
specification and codecs must be tested independently of the browser.

The existing `sb_dispatch` engine export may remain for Slice 0 inspection.
The Wasm composition adds an explicit stateful app-session dispatcher. Its
state is allocated and mutated in Haskell; JavaScript receives only an opaque
runtime/session handle and protocol values. Shared packages must not use an
unsafe process-global session. The exact GHC-Wasm handle/lifetime mechanism is
a required bounded spike before implementation.

## Explicit exclusions

P2 does not include:

- history persistence across reload, browser working-copy history, Git
  commit/history, or collaboration;
- cursor, selection, scroll, canvas selection, or view-preference snapshots in
  source history;
- native GUI or interactive CLI Undo/Redo commands; the shared package still
  builds and is tested under native GHC;
- semantic canvas mutations or `VerifiedPatch`; P2 only fences the canvas and
  prepares the shared history transaction boundary;
- general TikZ, deck/frame history, source formatting, Monaco, or typing
  coalescence;
- arbitrary byte editing through a browser textarea.

The Haskell state and protocol preserve arbitrary bytes. The P2 browser edit
surface is narrower: only a DOM string whose UTF-8 encode/fatal-decode round
trip is exact may be admitted. On open, bytes that cannot be represented
byte-for-byte by the textarea, including non-UTF-8 and any browser-normalized
line-ending case, must fail closed into a diagnostic/read-only byte-preserving
mode rather than silently normalize. P2 browser fixtures use valid UTF-8 with
LF endings.

## Browser acceptance matrix

The real-browser test must assert source bytes through protocol output or a
Haskell state query, not only `textarea.value`.

| Scenario           | Required assertions                                                                                                                        |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Initial open       | Revision `0`; exact fixture bytes; Undo/Redo disabled; canvas becomes current only after paint                                             |
| Direct valid input | Haskell returns revision `1`; exact bytes; Undo enabled; Redo disabled                                                                     |
| Undo/Redo          | Exact `A -> B -> A -> B`; displayed revisions `0 -> 1 -> 2 -> 3`; toolbar and source-focused keyboard paths agree                          |
| Branch             | Undo, then changed direct input; Haskell reports Redo unavailable                                                                          |
| No-op              | Re-admit identical bytes after Undo; revision and both history directions remain unchanged                                                 |
| Invalid input      | Invalid bytes and new revision are accepted; diagnostic visible; Save and Undo enabled; last-good canvas DOM identity remains but is inert |
| Invalid recovery   | Undo yields exact previous valid bytes at a fresh revision; only a fresh current paint removes inertness; Redo restores invalid bytes      |
| Fast input         | Two same-task input events produce two ordered Haskell transitions; first response never overwrites the second draft                       |
| Stale paint        | A delayed earlier render cannot replace DOM or acquire the canvas lease after a newer source revision                                      |
| Load race          | Source input during an async read wins; a completed accepted load creates a fresh session at revision `0` and clears history               |
| Failure            | Stale revision/session and revision exhaustion leave exact source and both stacks unchanged and do not echo source in diagnostics          |
| Encoding boundary  | Emoji survives exact UTF-8 history; an unpaired surrogate or non-round-trippable opened source is not silently admitted                    |

## Implementation and test file map

These are proposed ownership boundaries for the implementation slice. The files
do not yet exist unless identified as current.

| Layer                | Proposed files                                                                                                                                                             | Responsibility and focused evidence                                                                                                                                                                                                         |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shared app state     | `packages/slideblaster-app/slideblaster-app.cabal`; `src/SlideBlaster/App.hs`; `src/SlideBlaster/App/SourceHistory.hs`; `src/SlideBlaster/App/Session.hs`; `test/Main.hs`  | Pure session transitions, exact history, revision/session fences, and current document/plan derivation. State-machine tests cover branching, no-op, exhaustion, cap, arbitrary bytes, and valid/invalid Undo/Redo.                          |
| App protocol         | current `packages/slideblaster-protocol`, adding `src/SlideBlaster/Protocol/App/Types.hs`, `App/Codec.hs`, and `App/Run.hs`, plus its facade/Cabal/test updates            | Closed `slideblaster.app/1` wire ADTs, base16 bytes, decimal-string revisions, correlation, typed errors, and native golden transitions. Add `docs/specs/app-protocol.md` only when the schema is accepted.                                 |
| Wasm composition     | current `apps/slideblaster-web-wasm/app/Main.hs`, adding `src/SlideBlaster/Adapter/Web/AppRuntime.hs` and `AppDispatch.hs`; current Cabal file                             | Allocate/dispose explicit Haskell app runtime, serialize state transitions, and expose app dispatch without weakening `sb_dispatch`. Add a Wasm golden sequence matching the native protocol fixture.                                       |
| Reactor loader       | current `hosts/web/src/wasm/load-reactor.js`                                                                                                                               | Validate the new exports and expose an opaque session dispatcher/lifetime; no source/history policy.                                                                                                                                        |
| Browser transport/UI | add `hosts/web/src/ui/source-history.js`; update current `hosts/web/src/main.js`, `index.html`, and `styles.css`                                                           | UTF-8 fidelity check, ordered input/IME queue, shortcuts, request/session/render correlation, button/status/diagnostic projection, accepted-source persistence, and inert last-good DOM. No JavaScript history stack or revision increment. |
| Render integration   | consume the accepted `packages/slideblaster-tikz` render plan and add one narrowly named host renderer under `hosts/web/src/ui/`                                           | Paint the bounded node/connector plan into detached DOM, tag it by session/revision/ticket, retain last-good DOM on syntax-only state, and never interpret source. This should be the same browser increment, not a mock canvas.            |
| Browser evidence     | add `.sessions/slideblaster2-web-parity/source-history-smoke.cjs` during parity work; promote a packaged runner under `hosts/web/test/` when its dependencies are packaged | Real GHC-Wasm scenarios from the acceptance matrix, deterministic same-task response race, stale render, invalid last-good canvas, exact protocol bytes, keyboard/toolbar parity, and no page/console errors.                               |
| Project wiring       | current `cabal.project.native`, `cabal.project.wasm`, `PROJECT.md`, Wasm build script if required, and package manifests                                                   | Add only packages consumed by this end-to-end slice; update the canonical graph and run both targets.                                                                                                                                       |

The verification ladder is:

1. focused pure `slideblaster-app` state-machine tests under native GHC;
2. app-protocol codec/golden tests under native GHC;
3. complete native test/build;
4. Wasm build plus the same golden app command sequence;
5. real-browser source-history smoke against the real Wasm artifact;
6. adversarial review of queue, stale response, stale paint, and invalid-source
   authority before promotion from `proposed`.

## Decisions required before implementation

1. **Typing transaction grain.** This spec proposes one non-composition input
   event per history entry and one entry per completed IME composition. Native-
   style word/time coalescing may be preferable, but it needs an explicit,
   deterministic shared transaction rule and new tests.
2. **Wasm state lifetime.** Confirm the supported GHC-Wasm mechanism for an
   explicit Haskell runtime handle/closure plus disposal. Do not fall back to a
   shared-package global or a JavaScript-owned serialized history.
3. **Browser byte surface.** Accept the fail-closed valid-UTF-8/exact-textarea
   boundary for P2, or choose a byte-capable editor representation now. Silent
   CRLF or non-UTF-8 normalization is not an option.
4. **History budget.** Confirm the proposed 100 exact snapshots and in-memory-
   only lifetime. A later compact representation must preserve the same
   observable bytes and revision laws.
5. **Canvas dependency.** P2 source state can be implemented before browser
   rendering, but the slice is not browser-complete until the independently
   reviewed bounded TikZ plan is painted and its invalid/stale lease behavior
   passes.
6. **Native textarea history coverage.** Chromium's cancelable
   `beforeinput(historyUndo/historyRedo)` path is the P2 target. Broader browser
   behavior and accessibility need a compatibility decision before claiming
   multi-browser parity.
