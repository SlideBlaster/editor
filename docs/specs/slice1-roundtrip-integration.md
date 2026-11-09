---
status: proposed
updated: 2026-07-23
---

# Slice 1 node-and-connector round-trip integration

## Purpose

This specification defines the thinnest complete integration of the frozen
literal TikZ core in
[`slice1-tikz-subset.md`](slice1-tikz-subset.md). It turns that pure package
into one native and browser proof:

```text
exact bare TikZ bytes
  -> Haskell analysis
  -> typed renderer-neutral plan
  -> browser DOM/SVG
  -> pointer drag
  -> typed Haskell MoveNode
  -> provenance-guided candidate
  -> reparse, elaborate, and compare
  -> exact verified successor bytes
```

The source remains authoritative throughout. JavaScript translates a closed
render plan and pointer events; it does not parse TikZ, infer a document model,
select source spans, construct source text, or decide whether an edit is
semantically valid.

This integration deliberately uses the current stateless engine boundary. It
does not introduce the stateful source-history package proposed by
[`p2-source-history-slice.md`](p2-source-history-slice.md). The later app
session may internalize analysis and rendering, but it must preserve the
observable laws defined here.

## Frozen semantic boundary

The integration accepts exactly the grammar already implemented by
`slideblaster-tikz`:

```text
picture   ::= trivia node trivia connector trivia EOF
node      ::= "\node" trivia "(" id ")" trivia "at" trivia point
              trivia "{" content "}" trivia ";"
connector ::= "\draw" trivia "(" id ")" trivia "--" trivia point
              trivia ";"
point     ::= "(" trivia decimal trivia "," trivia decimal trivia ")"
```

There is one named, direct-position node followed by one straight connector
from that same node to one absolute point. Options, wrappers, additional
statements, alternate connector operators, nested content, units, relative
coordinates, and every other TikZ construct remain syntax-only exact source.

No implementation task in this document may widen that grammar. A grammar
change belongs first in `slice1-tikz-subset.md`, requires new pure laws, and is
not an incidental protocol or renderer change.

## User-visible proof

Given the exact noncanonical fixture defined below:

1. `slideblaster tikz analyze` reports one ready node and connector without
   changing the file.
2. The browser sends the same source through the real GHC-Wasm reactor and
   paints one content node plus one straight SVG connector.
3. Dragging the node to `(4,5)` sends a typed `MoveNode` intent to Haskell.
4. Haskell changes only the two owned coordinate tokens, reparses the candidate,
   verifies semantic equality, and returns the exact successor snapshot.
5. The source pane shows the verified successor, the connector start follows
   the moved node, and the connector statement remains byte-identical.
6. The native CLI produces the same successor as a dry run and persists those
   bytes only with `--write`.
7. Direct source authored during a gesture or pending move always wins. A
   stale gesture or response cannot overwrite it.
8. Malformed direct source stays exact and savable. The latest good canvas
   remains visible but inert until a current ready analysis is painted.

## End-to-end ownership of meaning

| Value | Owner | Authority |
| --- | --- | --- |
| Exact bytes and revision | `SourceBufferSnapshot` in Haskell; transported as base16 | Sole persistence authority |
| CST, diagnostics, picture, and provenance | `slideblaster-tikz` | Derived for exactly one source revision |
| `RenderPlan` | `slideblaster-tikz`, encoded by the engine protocol | Disposable drawing instructions |
| Painted DOM/SVG | browser renderer | Disposable last-good view; never source or semantic state |
| Pointer sample and capture state | browser event adapter | Ephemeral host input only |
| `MoveNode` and its acceptance | Haskell | Sole semantic edit authority |

The browser may remember the latest exact textarea value and current request
correlation because the existing stateless composition requires them. It may
not use DOM state to recreate `Picture`, derive connector behavior, or bypass
the Haskell revision and semantic-verification checks.

The pure composition belongs behind a new `SlideBlaster.Engine.TikZ` wrapper.
That wrapper alone opens a TikZ document, derives its plan, constructs the
typed `MoveNode`, applies it, and pairs a ready plan with its source revision
and fixed coordinate-space tag. `SlideBlaster.Protocol` only decodes closed
wire values into that engine input, delegates to the wrapper, and encodes its
result. The protocol must not duplicate opening, projection, or verification
logic.

## Engine protocol decision

### Recommendation: additive `slideblaster.engine/1` commands

Add two commands to the existing protocol:

- `analyze_tikz`
- `move_tikz_node`

This is a backward-compatible extension:

- existing `inspect` and `replace` requests and responses do not change;
- existing clients continue to send only commands they understand;
- an older engine rejects either new command with the existing typed
  `unknown_command` error;
- the browser host and Wasm reactor ship as one artifact, so they do not
  negotiate independently deployed implementations; and
- removing the new variants before external publication leaves the existing v1
  behavior unchanged.

A new engine protocol version would be required if an existing command changed
meaning, an existing field changed type, success/error envelopes changed, or
snapshot revision/base16 encoding changed. None is needed for this slice.

The later stateful history protocol is not an engine v2. It remains the
separately proposed `slideblaster.app/1` boundary because it owns session
lifetime and history, while `slideblaster.engine/1` remains a pure function of
each complete request.

New clients must still handle `unknown_command` as capability absence. No
capability-discovery command is needed for this bundled vertical slice.

### Reversibility and decision gate

The additive command choice does not change presentation semantics or source
format. It is reversible while `engine/1` remains an internal pre-release
boundary and therefore fits delegated implementation authority. If
`slideblaster.engine/1` has already been promised as an external public
protocol, accepting the schemas below is a user gate under `AGENTS.md` before
implementation marks this document accepted.

## Closed command schemas

All objects are closed. Missing or unknown fields at any level produce
`invalid_field`. Existing source snapshots retain the v1 shape:

```json
{
  "revision": 0,
  "source": "256c6561640a",
  "encoding": "base16"
}
```

Source is lowercase base16 and may contain arbitrary bytes. The ready subset
itself necessarily has valid UTF-8 node content; syntax-only analysis still
preserves non-UTF-8 source exactly.

### Analyze request

```json
{
  "protocol": "slideblaster.engine/1",
  "command": "analyze_tikz",
  "snapshot": {
    "revision": 0,
    "source": "5c6e6f64652028616c706861292061742028312c3229207b68656c6c6f7d3b0a5c647261772028616c70686129202d2d2028392c38293b0a",
    "encoding": "base16"
  }
}
```

Opening is total. A supported source returns a ready analysis. Malformed,
unsupported, ambiguous, or non-UTF-8 source returns a successful
`syntax_only` analysis because exact recovery is an engine result, not a wire
failure.

Ready response:

```json
{
  "protocol": "slideblaster.engine/1",
  "ok": true,
  "response": "tikz_analysis",
  "snapshot": {
    "revision": 0,
    "source": "5c6e6f64652028616c706861292061742028312c3229207b68656c6c6f7d3b0a5c647261772028616c70686129202d2d2028392c38293b0a",
    "encoding": "base16"
  },
  "analysis": {
    "state": "ready",
    "renderPlan": {
      "sourceRevision": 0,
      "coordinateSpace": "slide_16x9_y_up",
      "node": {
        "kind": "content_node",
        "id": "alpha",
        "center": { "x": "1", "y": "2" },
        "content": "hello"
      },
      "connector": {
        "kind": "straight_connector",
        "start": { "x": "1", "y": "2" },
        "end": { "x": "9", "y": "8" }
      }
    }
  }
}
```

Syntax-only response:

```json
{
  "protocol": "slideblaster.engine/1",
  "ok": true,
  "response": "tikz_analysis",
  "snapshot": {
    "revision": 1,
    "source": "5c6e6f6465",
    "encoding": "base16"
  },
  "analysis": {
    "state": "syntax_only",
    "diagnostics": [
      {
        "category": "malformed",
        "code": "expected_syntax_token",
        "span": { "start": 5, "end": 5 },
        "message": "Expected '(' before the node identifier"
      }
    ]
  }
}
```

`span` is either an exact two-field `{ "start", "end" }` object denoting a
half-open byte range or `null` when the source exceeds the common portable span
domain. Diagnostic messages are static explanations and must not echo authored
source.

Diagnostic categories are exactly `malformed`, `unsupported`, and `ambiguous`.
Codes are stable snake-case projections of the frozen Haskell constructors:

- `expected_node_statement`
- `expected_connector_statement`
- `expected_syntax_token`
- `invalid_node_identifier`
- `invalid_connector_identifier`
- `invalid_coordinate_token`
- `invalid_utf8_content`
- `nested_node_content_unsupported` (retained in the wire vocabulary; no
  longer emitted, since balanced node-content groups are now admitted)
- `node_options_unsupported`
- `connector_options_unsupported`
- `connector_operation_unsupported`
- `connector_target_unsupported`
- `extra_construct_unsupported`
- `multiple_constructs_ambiguous`
- `source_span_domain_exceeded`

Ready analysis has exactly `state` and `renderPlan`. Syntax-only analysis has
exactly `state` and non-empty `diagnostics`. A response never carries both a
render plan and diagnostics.

### Move request

```json
{
  "protocol": "slideblaster.engine/1",
  "command": "move_tikz_node",
  "snapshot": {
    "revision": 0,
    "source": "5c6e6f64652028616c706861292061742028312c3229207b68656c6c6f7d3b0a5c647261772028616c70686129202d2d2028392c38293b0a",
    "encoding": "base16"
  },
  "intent": {
    "revision": 0,
    "nodeId": "alpha",
    "destination": { "x": "4", "y": "5" }
  }
}
```

`nodeId` is decoded only through `mkNodeId`. Destination values are JSON
strings decoded only through `coordinateFromDecimalText`; JSON numbers,
exponents, units, non-decimal values, excessive digits, and unknown fields are
rejected before `MoveNode` is constructed.

The intent revision and snapshot revision are deliberately separate fields.
The engine opens the supplied snapshot, constructs the typed intent, and lets
`applyMoveNode` compare them. A canvas painted from revision `r` therefore
cannot write through a newer snapshot `r + n`.

Changed response:

```json
{
  "protocol": "slideblaster.engine/1",
  "ok": true,
  "response": "tikz_move",
  "snapshot": {
    "revision": 1,
    "source": "5c6e6f64652028616c706861292061742028342c3529207b68656c6c6f7d3b0a5c647261772028616c70686129202d2d2028392c38293b0a",
    "encoding": "base16"
  },
  "move": {
    "outcome": "verified_change",
    "beforeRevision": 0,
    "afterRevision": 1,
    "nodeId": "alpha",
    "destination": { "x": "4", "y": "5" }
  },
  "analysis": {
    "state": "ready",
    "renderPlan": {
      "sourceRevision": 1,
      "coordinateSpace": "slide_16x9_y_up",
      "node": {
        "kind": "content_node",
        "id": "alpha",
        "center": { "x": "4", "y": "5" },
        "content": "hello"
      },
      "connector": {
        "kind": "straight_connector",
        "start": { "x": "4", "y": "5" },
        "end": { "x": "9", "y": "8" }
      }
    }
  }
}
```

`verified_change` means the private candidate passed exact source checks,
authoritative reparse/elaboration, and semantic equality. No candidate bytes
are exposed.

A semantic no-op is successful with:

```json
{
  "outcome": "unchanged",
  "beforeRevision": 0,
  "afterRevision": 0,
  "nodeId": "alpha",
  "destination": { "x": "1", "y": "2" }
}
```

The complete no-op response contains the exact original snapshot and its
current ready plan. It does not canonicalize coordinate spelling or advance
the revision.

### Typed protocol errors

The existing error envelope remains unchanged. New stable codes are:

| Code | Haskell cause | State effect |
| --- | --- | --- |
| `tikz_semantics_unavailable` | `MoveSemanticsUnavailable` | None |
| `tikz_target_missing` | `MoveTargetMissing` | None |
| `tikz_target_ambiguous` | `MoveTargetAmbiguous` | None |
| `tikz_projection_unsupported` | `MoveProjectionUnsupported` | None |
| `tikz_verification_failed` | `MoveVerificationFailed` | None |

`MoveStale` maps to the existing `stale_revision`. Nested source-check failures
reuse the existing exact-replacement codes. Invalid identifiers or destination
decimals map to `invalid_field`.

`tikz_verification_failed.details.reason` is exactly
`parse_or_elaboration_failed` or `semantic_mismatch`. Semantics-unavailable
details may contain diagnostic categories, codes, and spans, but never source
bytes or substrings. Every rejected move returns no successor snapshot.

The JavaScript response decoder validates the exact success variant and every
nested field before rendering or assigning source. Unknown fields, wrong
discriminators, invalid decimal strings, non-safe revision values, and malformed
base16 fail closed as a transport error; the current source and last-good canvas
remain unchanged and inert.

## Typed render-plan wire contract

The wire plan is the engine wrapper's typed lease around the Haskell
`RenderPlan`, not a second picture model. `sourceRevision` and
`coordinateSpace` are integration metadata; the node and connector fields are
encoded directly from the core plan.

| Field | Contract |
| --- | --- |
| `sourceRevision` | Must equal the response snapshot revision and the revision painted into the canvas lease |
| `coordinateSpace` | Fixed closed enum `slide_16x9_y_up`: origin at lower left, width 16, height 9 |
| `node.kind` | Fixed `content_node` |
| `node.id` | Already validated `[A-Za-z_][A-Za-z0-9_-]*` identity |
| `node.center` | Canonical exact decimal strings from `coordinateToText` |
| `node.content` | Decoded plain Unicode text; never HTML |
| `connector.kind` | Fixed `straight_connector` |
| `connector.start` | Canonical point resolved by Haskell from the current node |
| `connector.end` | Canonical absolute endpoint |

Coordinates remain strings on the wire so exact decimal values do not pass
through IEEE-754 before schema validation. The DOM renderer may derive finite
pixel values for display, but those approximations never return as source or
semantic state.

The plan contains no source spans, CST nodes, provenance constructors,
candidate patch, DOM selector, CSS text, HTML, persistence instruction, or
history authority.

## DOM/SVG renderer contract

Add one dependency-free module, conceptually
`hosts/web/src/ui/tikz-renderer.js`, whose input is only a validated ready plan.
It builds a detached subtree before touching the live canvas:

```text
div.slice1-render-surface
  data-source-revision
  svg.slice1-geometry        viewBox="0 0 16 9"
    line[data-kind=straight-connector]
  div.slice1-content
    button[data-node-id]
```

The SVG layer renders the connector. The content layer renders the node as an
ordinary positioned HTML button so it is focusable and can own pointer capture.
The connector begins at the node center in this first slice; measured node
boxes and border intersection are explicitly deferred.

Renderer rules:

1. Set node content with `textContent`, never `innerHTML`.
2. Assign source-derived identity with DOM properties/dataset after the closed
   protocol validator accepts it; do not concatenate source into selectors,
   HTML, CSS, or element names.
3. Convert y-up slide coordinates only through the fixed coordinate-space
   adapter. SVG may use a `translate(0 9) scale(1 -1)` geometry group; HTML top
   position is `(9 - y) / 9`.
4. Require every display conversion to be finite. A host-render failure leaves
   the prior canvas inert and reports a typed host diagnostic; it never changes
   source.
5. Preserve canonical plan coordinates in `data-*` evidence fields so browser
   tests assert the received Haskell plan rather than only rounded pixels.
6. Swap the detached subtree into the canvas only after the response
   revision/text fence is still current.
7. Tag the live surface with its painted source revision. Removing `inert` is
   the final paint step.

The renderer draws exactly the two plan instructions. It does not infer that a
connector follows a node; Haskell has already supplied the resolved start point.

## Pointer drag to typed `MoveNode`

The browser owns pointer capture and coordinate-space translation only.

1. `pointerdown` is accepted only on the rendered node while the canvas lease is
   current and no source-dependent request is pending.
2. Capture the painted revision, validated node ID, pointer ID, and surface
   rectangle. This is an ephemeral gesture value, not a document snapshot.
3. `pointermove` may update a host-only drag ghost. It must not rewrite the live
   semantic node, connector, source, or render plan.
4. Releasing outside the surface cancels without an engine request.
5. Releasing inside maps the pointer through the fixed 16-by-9 y-up transform.
   The adapter emits a non-exponent decimal with at most six fractional digits.
   This reversible input-precision choice is below the core's nine-digit
   fractional limit; Haskell still validates and owns the resulting `Point`.
6. Send `move_tikz_node` with the current exact snapshot and the revision/ID
   captured at pointerdown.
7. Adopt a successful response only if the request base revision and exact
   textarea bytes are still current. Assign the returned exact snapshot under
   an input-suppression guard, then paint the returned plan.

The pointer transform is host event translation permitted by ADR 0025. Snapping,
constraint solving, relative placement, target lookup, provenance, source
projection, canonical coordinate spelling, and semantic acceptance remain
Haskell responsibilities.

## Stale direct-source and gesture behavior

Three fences are mandatory and independently tested:

### Painted-lease fence

Every pointer gesture carries the revision that produced its DOM. The Haskell
move request independently compares that revision with the supplied current
snapshot. A mismatch returns `stale_revision` and no successor.

### Direct-authorship fence

On every direct textarea input:

- advance the current stateless browser snapshot using the existing P1 rule;
- immediately set the canvas `inert` and `aria-disabled="true"`;
- cancel any active pointer capture/drag ghost; and
- request current Haskell analysis.

If input happens between pointerdown and pointerup, no move should be submitted.
If transport ordering still submits it, the Haskell revision fence must reject
it.

### Response fence

Analyze and move requests capture `(revision, exact textarea text)`. A response
may assign source, diagnostics, or DOM only while both still match. Newer direct
authorship wins even if the older operation completed successfully in Haskell.

Stale response reporting contains only operation and revision metadata, never
source text. This is the same source-authority rule already proven for P1
Inspect, Replace, and Load.

## Invalid source and last-good inert canvas

Direct invalid or unsupported source is accepted as the newest exact browser
snapshot and may be saved. Its current Haskell analysis is `syntax_only`.

Browser behavior:

1. Inert the current canvas immediately on input, before awaiting Wasm.
2. If the current analysis is syntax-only, show its typed diagnostics.
3. Retain the existing rendered subtree by object identity; do not clear it,
   synthesize fallback geometry, or repaint from old semantic values.
4. Keep every node/gesture affordance inert and clear transient selection.
5. On a later current ready analysis, build a fresh detached render and only
   then replace the last-good subtree and authorize its new revision.

If no ready render has ever existed, retain the honest empty/unsupported
placeholder in an inert state.

The last-good DOM is a visual cache only. Neither the browser nor Haskell uses
it as the input to a move. A `MoveNode` request always includes current exact
source and a painted revision.

## Native CLI composition

Add two commands:

```text
slideblaster tikz analyze FILE
slideblaster tikz move-node FILE NODE_ID X Y [--write]
```

`analyze` loads exact bytes through the native adapter and runs
`AnalyzeTikz` through the shared pure interpreter. It never writes. Ready
analysis exits `0`; syntax-only analysis prints stable diagnostic
category/code/span fields without source and exits `1`.

`move-node`:

- parses `NODE_ID`, `X`, and `Y` through the same public Haskell constructors
  used by the protocol;
- loads one revision-0 exact snapshot;
- runs `MoveTikzNode` through the shared interpreter;
- is a dry run unless `--write` is present;
- prints stable move outcome/revision/target/destination and plan fields without
  echoing source;
- skips persistence for `unchanged`;
- with `--write`, invokes the existing native
  `saveSnapshotIfUnchanged` conditional-save capability using the exact
  loaded bytes and verified successor; and
- preserves the native adapter's best-effort conflict check, portable
  permission copying, and exit-status behavior.

Usage errors exit `2`; typed analysis/move/storage failures exit `1`. A
successful dry run prints `host.persisted=false`; a successful changed write
prints `host.persisted=true`.

The CLI must not reproduce coordinate projection or verification. It receives
only an already verified successor from the shared engine response.

## Exact acceptance fixtures

The shared LF/UTF-8 fixture is the exact encoding of:

```text
"% lead\n\\node % command\n (alpha)\t at ( +001.5000 % x\n ,\t -000.00 ) {π 😀}; % between\n\\draw\t(alpha) -- (9.0 , 8);\n"
```

Moving `alpha` to `(4,5)` must produce exactly:

```text
"% lead\n\\node % command\n (alpha)\t at ( 4 % x\n ,\t 5 ) {π 😀}; % between\n\\draw\t(alpha) -- (9.0 , 8);\n"
```

The byte prefix/suffix around the changed x/y token range, the comment between
those tokens, Unicode content, tabs, connector statement, and final LF are
identical. The existing pure CRLF fixture remains an additional native and
Wasm protocol golden; the browser textarea fixture uses LF because DOM textarea
line-ending normalization is outside this slice's byte surface.

### Required laws

**SB2-S1I-001 Analyze exactness.** Native and Wasm analysis return the supplied
snapshot byte-for-byte. Ready plans and syntax-only diagnostics agree by JSON
value on both targets.

**SB2-S1I-002 Closed render plan.** The ready wire plan contains exactly the
fields specified above; canonical decimal strings, validated ID, plain content,
source revision, and connector endpoints equal the pure Haskell plan.

**SB2-S1I-003 Renderer faithfulness.** The browser paints one HTML node and one
SVG connector from the plan. Typed DOM evidence fields equal the Haskell plan;
no source parser or semantic fallback exists in JavaScript.

**SB2-S1I-004 Verified gesture.** A real pointer drag to `(4,5)` yields the
exact expected bytes, one revision advance, `verified_change`, a node center and
connector start of `(4,5)`, and an unchanged connector endpoint/statement.

**SB2-S1I-005 Native parity.** CLI dry run leaves the file exact and reports the
same move. `--write` installs exactly the expected bytes. A no-op performs no
persistence mutation.

**SB2-S1I-006 Stale atomicity.** A direct source input during a gesture and a
direct input while the move response is pending both win. Source bytes and
revision stay at the newer direct edit; no stale response or old DOM gains a
lease.

**SB2-S1I-007 Invalid-source continuity.** Malformed direct source remains exact,
produces current Haskell diagnostics, retains the last-good DOM by identity, and
makes it non-interactive. A fresh valid current analysis is required to
reauthorize the canvas.

**SB2-S1I-008 Protocol closure.** Unknown commands/fields, invalid ID/decimal,
wrong discriminators, malformed base16, unavailable semantics, missing target,
stale revision, and verification failure are typed, non-source-echoing, and
atomic.

**SB2-S1I-009 Cross-target response parity.** The same analyze, move, no-op,
syntax-only, and stale requests produce equal decoded JSON through the native
interpreter and real Wasm `sb_dispatch`.

### Focused evidence

| Level | Fixtures and assertions |
| --- | --- |
| Pure core | Keep all existing `slideblaster-tikz` exactness, recovery, locality, stale, no-op, connector-following, and injected-verification laws green |
| Protocol codec | Closed request keys at every level; exact base16; decimal-string and ID validation; ready/syntax-only unions; stable error mapping |
| Native interpreter | Golden decoded JSON for analyze, verified move, no-op, invalid source, and stale move |
| CLI | Temporary real files for dry-run identity, exact `--write`, no-op, syntax-only exit, and native persistence conflict behavior |
| Wasm | Send the same golden requests through the built reactor and compare decoded JSON values with native |
| Browser | Real pointer drag, exact textarea/protocol bytes, connector following, same-task source/response races, inert last-good DOM, recovery paint, keyboard/focus sanity, and zero page/console errors |

Screenshots are optional visual review evidence and never replace these
behavioral assertions.

## Vertical implementation increments

Implementation remains vertical even though ownership is split:

### S1a: exact analysis to real browser paint

Add `analyze_tikz`, include the frozen core in native/Wasm manifests, expose the
ready/syntax-only response, render the real plan in the browser, and make
`tikz analyze` exercise the same interpreter. Demonstration: edit valid/invalid
source and observe a current or inert last-good canvas.

### S1b: verified move through both targets

Add `move_tikz_node`, CLI dry-run/write, browser pointer translation, exact
successor adoption, and connector-following repaint. Demonstration: one drag
changes only the two coordinate tokens and the CLI produces identical bytes.

### S1c: adversarial closure

Complete nested-schema rejection, direct-edit/gesture and response races,
no-op, syntax-only move rejection, native persistence conflict, native/Wasm
goldens, and browser recovery. Only then may Slice 1 be called complete.

No increment may land a mock JavaScript parser or canvas model while waiting for
the next layer.

## Proposed implementation ownership and file map

Each row is one write owner. Shared manifests remain with the integrator.

| Owner node | Files | Responsibility |
| --- | --- | --- |
| S1 engine wrapper | new `packages/slideblaster-engine/src/SlideBlaster/Engine/TikZ.hs`; engine facade/Cabal/test | Compose `openTikz`, `renderDocument`, typed `MoveNode`, verified application, and revisioned render leases behind one pure API; own TikZ result/error mapping without wire or host concerns |
| S1 protocol | `packages/slideblaster-protocol/src/SlideBlaster/Protocol/{Types,Codec,Run,Render}.hs`; optional new `Protocol/TikZ.hs`; protocol Cabal/test; `docs/specs/engine-protocol.md` | Add closed command/response variants, delegate only through the engine wrapper, encode plan/diagnostic values, map stable errors, render CLI output, and prove codec/golden laws |
| S1 CLI | `apps/slideblaster-cli/src/SlideBlaster/Cli.hs`; CLI Cabal/test | Add nested commands, shared constructors/interpreter, dry-run/write/no-op behavior, and native real-file tests |
| S1 Wasm composition | `apps/slideblaster-web-wasm/cabal.project`; Wasm Cabal only if direct dependency is needed; existing dispatch tests or session cross-target fixture | Include transitive TikZ package and prove unchanged `sb_dispatch` runs new commands; no new export or JSFFI |
| S1 browser protocol | new `hosts/web/src/protocol/engine-v1.js`; focused dependency-free tests | Closed success/error/plan validation and exact base16/decimal/revision checks; no document interpretation |
| S1 browser renderer | new `hosts/web/src/ui/tikz-renderer.js`; renderer tests | Detached DOM/SVG translation, coordinate-space mapping, inert lease, plain-text/id safety, and pointer event emission only |
| S1 browser composition | current `hosts/web/src/main.js`, `index.html`, `styles.css`, `README.md` | Correlate current snapshot/analyze/move responses, source fences, last-good canvas, diagnostics, and source adoption; no parser or semantic edit path |
| S1 browser evidence | `.sessions/slideblaster2-web-parity/slice1-roundtrip-smoke.cjs`, then a packaged test location when browser dependencies are packaged | Real reactor pointer/exact-source/stale/invalid/recovery assertions and cross-target JSON comparison |
| S1 integrator | `cabal.project.native`, `cabal.project.wasm`, `apps/slideblaster-web-wasm/cabal.project`, `PROJECT.md`, package dependency stanzas, build/runbook only if commands change | Promote the already reviewed package into both graphs, resolve non-overlapping changes, update module map, and run complete native/Wasm/browser gates |
| S1 independent reviewer | read-only production scope plus own session log | Adversarial source/protocol/DOM/gesture review and exact reproduction before approval |

The frozen `packages/slideblaster-tikz/**` and
`docs/specs/slice1-tikz-subset.md` remain owned by their core maintainer. An
integration issue must not be “fixed” by silently broadening or weakening the
pure grammar and laws.

## Verification ladder

Run in this order:

1. forced warning-as-error build and focused pure TikZ suite;
2. focused protocol codec/interpreter tests;
3. focused CLI real-file tests;
4. complete native `test all` and build;
5. Wasm build with the promoted TikZ dependency;
6. native-versus-real-Wasm decoded JSON goldens;
7. dependency-free browser protocol/renderer tests;
8. real-browser S1 pointer/source/invalid/stale smoke;
9. independent adversarial review;
10. update `PROJECT.md`, accepted protocol/spec status as authorized, and the
    knowledge graph.

## Deliberate exclusions

This slice does not add:

- source history, Undo/Redo, session identity, or a `slideblaster-app` package;
- working-copy Files/Git, autosave, or browser persistence claims;
- Beamer/tikzpicture wrappers, decks, frames, or multiple constructs;
- node options, shapes, styling, measured boxes, border anchors, or connector
  editing;
- snapping, constraints, relative coordinates, live semantic preview, or
  selection history;
- canonical whole-document output;
- arbitrary HTML/LaTeX content;
- a native GUI; or
- a second parser, picture model, inverse edit, or formatter in JavaScript.

These exclusions are visible boundaries, not silent fallbacks.
