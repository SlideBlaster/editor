---
status: proposed
updated: 2026-07-23
---

# Slice 2 bounded LaTeX/Beamer subset

## Purpose and authority

This specification proposes the smallest browser-first LaTeX/Beamer vertical
slice required by the accepted sequence in
[`vertical-slices.md`](../architecture/vertical-slices.md):

```text
exact authored .tex bytes
  -> recoverable structural TeX syntax
  -> one supported Beamer frame
  -> the already-bounded Slice 1 TikZ picture
  -> browser render
  -> one direct-coordinate node move
  -> verified local source change
  -> an explicit clean writer for a new document
```

It is a format proof, not a TeX engine. It does not execute macros, load
packages, apply catcode changes, or claim arbitrary LaTeX or Beamer
compatibility.

The legacy TypeScript structural parser in
`editor/packages/editor/src/tikz/full.ts` is useful evidence for control
sequences, recursive groups, comments, and matched environments. Its spans are
JavaScript string offsets, it throws on malformed input, and it is not an exact
byte-preserving Beamer reader. The projector in
`editor/packages/editor/src/tikz/sourceEdit.ts` is evidence for locating a
wrapped `tikzpicture` and verifying a semantic transaction, but it is not the
new implementation.

The legacy `toTeX` design is also not the writer oracle for this slice.
`design/format/tex-export.md` describes a future multi-file export from the
SlideBlaster format, with themes, content conversion, assets, and multiple
frames. This slice instead reads one authored `.tex` source and can explicitly
generate one new, bounded `.tex` document from its semantic presentation. It
does not implement or weaken the export contract.

## Decision classification

The accepted architecture already requires an early bounded Beamer reader and
writer. The exact admitted source form and canonical writer spelling below are
nevertheless a new user-visible document-format contract. Under `AGENTS.md`,
changing or accepting that contract is a **user decision gate**. Implementation
may prepare fixtures and internal modules, but this document must remain
`status: proposed` and production must not claim the format until the user
accepts:

1. the literal one-frame grammar;
2. the whole-document read-only response to syntax outside that grammar; and
3. the canonical spelling emitted only by the explicit new-document writer.

The following remain delegated, reversible implementation choices after that
gate:

- private CST constructors and parser combinators;
- package-internal module splits;
- exact diagnostic prose, while stable codes and redaction laws hold;
- an additive command extension to an internal, pre-release engine protocol;
- DOM element choices beneath the typed render-plan contract; and
- test generators and fixture organization.

If `slideblaster.engine/1` becomes an externally promised protocol before this
slice lands, adding commands to it becomes a separate user gate.

## User-visible proof

The browser demonstration opens a noncanonical but supported full Beamer source,
renders its one node and connector, and moves the node from its current direct
coordinate to `(4,5)`.

One representative authored fixture is:

```latex
% keep this header
\documentclass % class trivia
 [ aspectratio = 169 ] {beamer}
\usepackage {tikz}
\begin {document}
  \begin {frame}
    \begin {tikzpicture}
% keep this node comment
\node % identity trivia
 (alpha) at ( +001.00 , 02.500 ) {hello};
\draw (alpha) -- (9,8);
    \end {tikzpicture}
  \end {frame}
\end {document}
% keep this tail
```

After the move, only `+001.00` and `02.500` become `4` and `5`. The document
class, package declaration, comments, whitespace, delimiters, environment
spelling, node content, connector statement, and final newline remain
byte-identical.

The same fixture is analyzed and moved by the native CLI. Native and Wasm
return the same semantic values, diagnostic codes, global byte spans, and exact
successor bytes.

An explicit Generate action produces canonical source for a new document from
the ready semantic presentation. It previews or downloads a separate artifact;
it never silently replaces or normalizes the authored source.

For malformed or unsupported input, the newest full source remains visible,
saveable, and exact. Diagnostics identify the source-backed unsupported region.
The last good canvas may remain visible, but it is inert and cannot issue a
move against the newer revision.

## Why each pipeline layer exists

The public client receives one coherent Beamer document analysis. The following
are internal responsibilities, not independently persistent models.

| Layer                 | Responsibility in this slice                                                                                                              | Why it is required                                                                                                                            |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Authored bytes        | `SourceBufferSnapshot` containing the complete `.tex` bytes and revision.                                                                 | The exact file, including unsupported and malformed regions, is the save authority.                                                           |
| Structural TeX CST    | Source-backed control sequences, comments, trivia, groups, option groups, environments, and opaque recovery regions.                      | The reader must match nested environment boundaries and diagnose unknown syntax without searching strings or losing bytes.                    |
| Beamer surface view   | Validates one document class, one package declaration, one `document`, one `frame`, and one `tikzpicture`; records the picture-body span. | Structural TeX syntax alone does not say which commands have supported Beamer meaning. This view is transient and never persisted separately. |
| Semantic presentation | One `Presentation` containing one anonymous `Frame` and the Slice 1 `Picture`.                                                            | Canvas commands and future writers need meaning independent of environment spelling and DOM structure.                                        |
| Provenance            | Links the frame picture to its exact parent body span and to a child TikZ analysis at the same revision.                                  | A verified TikZ edit must be lifted into the full `.tex` source without reparsing source in JavaScript or canonicalizing the envelope.        |
| Resolved layout       | Reuses Slice 1 direct coordinates and resolves the connector start from the moved node.                                                   | Authored meaning is not the browser's pixel geometry. Even this literal slice must derive connector geometry after a move.                    |
| Typed render plan     | Wraps the existing Slice 1 plan in one frame lease tied to the full source revision.                                                      | The browser can paint and hit-test a closed plan without knowing TeX, Beamer, TikZ, or source-projection policy.                              |

The reverse path keeps the same separation:

| Reverse step                 | Responsibility                                                                                                                 |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `MoveBeamerNode`             | Carries revision, the only frame index, validated node identity, and an exact decimal destination.                             |
| Intended presentation        | Computes the one semantic before/after value once. Preview and commit use that value.                                          |
| Embedded TikZ transaction    | Reuses the frozen Slice 1 parser, direct-coordinate provenance, canonical coordinate writer, reparse, and semantic comparison. |
| Lifted candidate             | Lifts only the already-verified child-source delta through the parent picture-body span.                                       |
| Parent source checks         | Checks the full-source revision, body bounds, and expected old bytes before applying the candidate.                            |
| Full reparse and elaboration | Reconstructs the complete Beamer snapshot and embedded TikZ analysis from the candidate bytes.                                 |
| Presentation verification    | Requires the actual full-document presentation to equal the intended after-value before returning a successor.                 |

The structural CST is not avoidable here. A byte search for
`\end{tikzpicture}` would mis-handle comments, nested groups, malformed
environments, and future opaque syntax. Conversely, the CST does not justify a
general TeX semantic evaluator; only the literal surface below is elaborated.

## Structural lexical boundary

The structural reader uses the ordinary initial TeX lexical conventions needed
by this subset:

- an ASCII control word is `\` followed by one or more ASCII letters or `@`;
- a control symbol is `\` followed by one byte;
- `%` starts a comment through LF or end of input;
- `{...}` and `[...]` are recursively balanced source-backed groups;
- `\begin{name}` and `\end{name}` form a matched environment when `name` is
  literal ASCII text; and
- all offsets are half-open byte offsets in the shared native/Wasm domain.

The reader does not interpret catcode changes, `\csname`, verbatim commands or
environments, conditional skipping, macro expansion, or package-defined
lexical behavior. Encountering a construct that could invalidate the fixed
lexical model yields `tex_lexical_mode_unsupported`, preserves the remaining
bytes in an opaque region, and makes the document read-only.

Every CST leaf denotes a span in the authoritative source. It does not copy a
normalized source string. Recovery is total: unexpected bytes, unmatched
delimiters, mismatched environments, and invalid UTF-8 never cause an
exception or discard input.

## Literal semantic grammar

`texTrivia` is zero or more spaces, horizontal tabs, CR, LF, or `%` comments.
It is permitted only at the positions shown and is always retained exactly.
`control(name)` requires a complete control word with the stated name.
`begin(name)` and `end(name)` are structurally matched environment delimiters
whose literal group body is exactly `name`.

```text
document ::=
  texTrivia documentClass
  texTrivia tikzPackage
  texTrivia begin("document")
  texTrivia frame
  texTrivia end("document")
  texTrivia EOF

documentClass ::=
  control("documentclass") texTrivia
  "[" texTrivia "aspectratio" texTrivia "=" texTrivia "169" texTrivia "]"
  texTrivia "{" "beamer" "}"

tikzPackage ::=
  control("usepackage") texTrivia "{" "tikz" "}"

frame ::=
  begin("frame")
  texTrivia picture
  texTrivia end("frame")

picture ::=
  begin("tikzpicture")
  pictureBody
  end("tikzpicture")

pictureBody ::= exact byte span accepted as ready by Slice 1
```

The accepted frame is anonymous: it has no option group, title group, subtitle,
overlay specification, or body construct beside the one picture. The picture
has no option group. The complete `pictureBody`, including leading and trailing
TikZ trivia, is passed unmodified to the existing
`slideblaster-tikz` reader at the parent source revision.

The embedded grammar remains exactly the one frozen in
[`slice1-tikz-subset.md`](slice1-tikz-subset.md): one named direct-position node
followed by one straight connector to an absolute point. This specification
does not add a `tikzpicture` production to that package and does not widen its
identifier, coordinate, content, statement, option, or connector rules.

### Explicit exclusions

The first Beamer surface does not assign semantic meaning to:

- another document class or another/as additional document-class option;
- an additional package, preamble command, definition, or text;
- zero, multiple, nested, titled, or option-bearing frames;
- frame overlays, `fragile`, notes, columns, lists, or ordinary frame text;
- zero, multiple, nested, or option-bearing `tikzpicture` environments;
- any construct excluded by the embedded Slice 1 grammar;
- `\input`, `\include`, package loading beyond the literal TikZ declaration,
  macro definitions or calls, conditionals, catcode changes, or verbatim; or
- bytes after the one document environment other than `texTrivia`.

Recognition in the structural CST is not semantic support. A balanced unknown
command or environment remains an exact `OpaqueUnsupported` node with a
diagnostic; it does not enter the presentation. Multiple plausible frames or
pictures are `ambiguous`. Malformed delimiters or environment boundaries are
`malformed`.

The entire document is semantic read-only when any non-trivia construct lies
outside the literal grammar. This fail-closed rule prevents an ignored preamble
macro, option, or neighboring construct from changing the meaning of a canvas
edit. It is a Slice 2 coverage boundary, not a reclassification of the
project's eventual T1/T2 model. In particular, constructs such as `\foreach`
remain future supported/render-only work even though this literal reader
currently diagnoses them as outside the slice.

## Conceptual types and invariants

The exact names may change during delegated implementation review, but the
separation and invariants are required.

```haskell
data TeXDocumentCST = TeXDocumentCST
  { texPieces :: [TeXPiece]
  , texOpaqueRegions :: [OpaqueRegion]
  }

data TeXPiece
  = TeXLeaf TeXLeafKind SourceSpan
  | TeXGroup GroupDelimiter SourceSpan [TeXPiece]
  | TeXEnvironment
      EnvironmentName
      SourceSpan  -- complete environment
      SourceSpan  -- body only
      [TeXPiece]
  | TeXOpaque OpaqueKind (Maybe SourceSpan)

data Presentation = Presentation !Frame
data Frame = Frame !Picture

data BeamerProvenance = BeamerProvenance
  { pictureBodySpan :: !SourceSpan
  , pictureDocument :: !TikZ.DocumentSnapshot
  }

data BeamerAnalysis
  = BeamerReady !Presentation !BeamerProvenance
  | BeamerSyntaxOnly !(NonEmpty BeamerDiagnostic)

data BeamerDocumentSnapshot = BeamerDocumentSnapshot
  { source :: !SourceBufferSnapshot
  , syntax :: !TeXDocumentCST
  , analysis :: !BeamerAnalysis
  }
```

Required invariants:

1. every CST and diagnostic span addresses `source` at exactly its revision;
2. the ordered terminal `TeXLeaf` and `TeXOpaque` spans are non-overlapping and,
   when the portable span domain permits, partition every authored byte;
3. `pictureBodySpan` is contained by the one matched `tikzpicture` body;
4. `pictureDocument` contains exactly the bytes at that span and carries the
   same revision as the parent;
5. `BeamerReady` exists only when the outer grammar and embedded Slice 1
   analysis are both ready;
6. a `Presentation` contains semantic meaning only, not wrapper spelling,
   source copies, DOM values, or persistence state; and
7. a syntax-only snapshot has no writable render-plan lease.

`snapshotAtRevision` may be used only inside the trusted composition to create
the derived child snapshot. It does not establish a second live source
authority.

The renderer-neutral value is:

```haskell
data BeamerRenderPlan = BeamerRenderPlan
  { planRevision :: !Revision
  , frameIndex :: !SingleFrameIndex  -- only 0 is constructible
  , coordinateSpace :: !Slide16x9YUp
  , picturePlan :: !TikZ.RenderPlan
  }
```

The browser reuses the existing Slice 1 node/connector renderer. The outer plan
adds only the full-source revision and the frame lease; it does not introduce a
second picture or layout model.

## Diagnostics and recovery

Every diagnostic contains:

- `layer`: `tex`, `beamer`, or `tikz`;
- category: `malformed`, `unsupported`, or `ambiguous`;
- a stable code;
- a global half-open byte span, or `null` only when the portable span domain is
  exceeded; and
- a static human message that never echoes authored source.

Outer stable codes are:

- `expected_document_class`;
- `document_class_unsupported`;
- `document_class_options_unsupported`;
- `expected_tikz_package`;
- `preamble_construct_unsupported`;
- `expected_document_environment`;
- `environment_mismatch`;
- `expected_single_frame`;
- `frame_options_unsupported`;
- `frame_title_unsupported`;
- `frame_construct_unsupported`;
- `expected_single_tikzpicture`;
- `tikzpicture_options_unsupported`;
- `multiple_frames_ambiguous`;
- `multiple_tikzpictures_ambiguous`;
- `trailing_construct_unsupported`;
- `tex_lexical_mode_unsupported`; and
- `source_span_domain_exceeded`.

Embedded diagnostics retain the existing Slice 1 code and category, use
`layer: "tikz"`, and have their child spans lifted by the picture-body start.
No adapter invents a second mapping.

A ready analysis has no hard diagnostics. A syntax-only analysis has a
non-empty diagnostic list and one or more exact source-backed opaque regions.
Diagnostics are ordered by source start, then layer and code, identically on
native and Wasm.

## Verified parent edit

```haskell
data MoveBeamerNode = MoveBeamerNode
  { requestedRevision :: !Revision
  , requestedFrame :: !SingleFrameIndex
  , requestedNode :: !NodeId
  , destination :: !Point
  }
```

Applying a move:

1. checks the intent revision against the full-source snapshot;
2. requires `BeamerReady` and frame index `0`;
3. computes the intended after-presentation;
4. creates the derived child snapshot at the same revision from
   `pictureBodySpan`;
5. calls the existing Slice 1 `applyMoveNode`, which alone owns direct
   coordinate provenance, candidate construction, child reparse, and child
   semantic verification;
6. if the child is unchanged, returns the original parent snapshot;
7. otherwise derives the smallest mechanically checked contiguous delta between
   the old child bytes and the already-verified child successor;
8. lifts that delta by the parent body start and checks that applying it to the
   old body reconstructs the verified child bytes exactly;
9. applies one revision-fenced, expected-byte-checked replacement to the full
   parent source;
10. reparses and elaborates the complete Beamer candidate; and
11. returns it only when the actual presentation equals the intended
    after-presentation.

The delta derivation does not parse or interpret TikZ. The Slice 1 verified
successor is its authority. A later additive Slice 1 receipt may expose its
verified changed span directly, but this slice does not require or justify
widening the Slice 1 grammar or exporting candidate constructors.

Typed edit errors are:

| Error                           | Meaning                                                           | State effect |
| ------------------------------- | ----------------------------------------------------------------- | ------------ |
| `BeamerMoveStale`               | Intent revision differs from full source.                         | None         |
| `BeamerSemanticsUnavailable`    | The parent is syntax-only.                                        | None         |
| `BeamerFrameUnavailable`        | The requested frame is not the sole frame.                        | None         |
| `BeamerEmbeddedMoveFailed`      | A typed Slice 1 move error occurred.                              | None         |
| `BeamerChildDeltaInvalid`       | The lifted delta cannot reconstruct the verified child successor. | None         |
| `BeamerParentSourceCheckFailed` | Parent revision, bounds, or expected bytes failed.                | None         |
| `BeamerVerificationFailed`      | Full reparse/elaboration failed or its presentation differs.      | None         |

Candidate bytes are private. A failure response never contains a successor
snapshot and never changes source, history, canvas authority, or persistence.

## Clean new-document writer

`writeNewBeamer` is an explicit semantic writer:

```haskell
writeNewBeamer
  :: Presentation
  -> Either BeamerWriteError ByteString
```

It does not read concrete provenance and is never called by Save, direct source
replacement, a canvas move, or ordinary undo/redo. Those paths retain or patch
authored bytes. The writer creates a separate artifact with LF line endings,
one final LF, and this exact envelope:

```latex
\documentclass[aspectratio=169]{beamer}
\usepackage{tikz}

\begin{document}
\begin{frame}
\begin{tikzpicture}
\node (alpha) at (1,2) {hello};
\draw (alpha) -- (9,8);
\end{tikzpicture}
\end{frame}
\end{document}
```

Node identity and coordinates use the validated Slice 1 values and canonical
decimal spelling. The connector start uses the semantic node identity.

The Slice 1 reader currently treats node content as literal decoded text rather
than a TeX content model. To keep writer/readback equality honest, this writer
accepts only content with no control characters and none of TeX's special
characters:

```text
\  {  }  %  #  $  &  _  ^  ~
```

Other content returns `BeamerWriteUnsafeNodeContent` without echoing it in
diagnostics. For the one-frame/one-picture semantic type, that is the only
expected writer failure. Escaping arbitrary content belongs to the later
tri-dialect content slice; this writer must not invent that semantics early.
Writing or downloading the returned artifact is an adapter responsibility.

“Clean” means deterministic, structurally well-formed, accepted by this reader,
and semantically equal on readback. A development machine with `lualatex` may
compile the golden fixture as an additional smoke check, but no TeX executable,
Wasm TeX engine, CDN, or render service is a product dependency or acceptance
authority.

## Executable laws

**SB2-S2-001 Exact full-source identity.** Opening, analyzing, rendering, or
reporting diagnostics returns the original full `.tex` bytes and revision
unchanged. Exact output reads `SourceBufferSnapshot`; it never prints the CST
or presentation.

**SB2-S2-002 Total recovery.** Every byte string produces a coherent document
snapshot. Malformed, unsupported, ambiguous, non-UTF-8, and over-domain input
is exact, source-backed, diagnosed, and syntax-only.

**SB2-S2-003 Literal readiness.** A source is ready if and only if its outer
surface matches the grammar and its exact picture body is ready under the
frozen Slice 1 reader. Outer trivia never changes its presentation.

**SB2-S2-004 Global diagnostic provenance.** Every representable diagnostic
span slices the complete parent source at the construct that caused it.
Embedded TikZ spans equal the child span plus `pictureBodySpan.start`.

**SB2-S2-005 Direct authorship.** A revision-fenced direct source replacement
advances and remains authoritative even when it produces syntax-only Beamer.
The last-good plan is inert until a ready plan for the new revision is painted.

**SB2-S2-006 Verified lifted move.** A successful non-no-op move passes the
existing Slice 1 verified transaction, reconstructs that exact child successor
through a lifted parent patch, reparses the full document, and equals the
intended after-presentation.

**SB2-S2-007 Parent locality.** A move changes only the direct x and/or y
decimal token admitted by Slice 1. Every byte before, between, and after those
owned tokens in the full `.tex` source is identical. Wrapper and connector
bytes are never regenerated.

**SB2-S2-008 Atomic failure.** Stale, syntax-only, wrong-frame, embedded,
delta-lift, source-check, and verification failure return no successor. Input
source and all derived state remain unchanged.

**SB2-S2-009 Semantic no-op.** Moving to the existing semantic point returns the
same parent snapshot, preserves noncanonical coordinate spelling, and does not
advance revision or create history.

**SB2-S2-010 Writer determinism.** For any writer-admissible presentation,
`writeNewBeamer` returns byte-identical output on repeated calls.

**SB2-S2-011 Writer readback.** Opening `writeNewBeamer(p)` is ready and yields
the same presentation `p`. The writer output itself satisfies exact identity.

**SB2-S2-012 No implicit canonicalization.** No authored-source operation calls
the clean writer. Generate returns a separate artifact and does not mutate the
current snapshot, revision, history, or persistence.

**SB2-S2-013 Cross-target equivalence.** For identical requests, native and
Wasm agree on readiness, semantic/render-plan values, ordered diagnostics,
edit acceptance, move outcome, generated bytes, and exact successor source.

## Engine protocol

While the engine protocol remains an internal pre-release boundary, add three
closed commands to `slideblaster.engine/1`:

- `analyze_beamer`;
- `move_beamer_node`; and
- `generate_beamer`.

They retain the existing exact base16 snapshot shape. Move coordinates remain
canonical decimal strings, never JSON floating-point values.

Conceptual requests are:

```json
{
  "protocol": "slideblaster.engine/1",
  "command": "analyze_beamer",
  "snapshot": { "revision": 0, "source": "...", "encoding": "base16" }
}
```

```json
{
  "protocol": "slideblaster.engine/1",
  "command": "move_beamer_node",
  "snapshot": { "revision": 0, "source": "...", "encoding": "base16" },
  "intent": {
    "revision": 0,
    "frame": 0,
    "nodeId": "alpha",
    "destination": { "x": "4", "y": "5" }
  }
}
```

```json
{
  "protocol": "slideblaster.engine/1",
  "command": "generate_beamer",
  "snapshot": { "revision": 0, "source": "...", "encoding": "base16" }
}
```

Ready analysis wraps the existing validated picture render plan:

```json
{
  "state": "ready",
  "documentKind": "beamer",
  "frame": 0,
  "renderPlan": {
    "sourceRevision": 0,
    "coordinateSpace": "slide_16x9_y_up",
    "node": {},
    "connector": {}
  }
}
```

The nested node and connector schema is exactly the Slice 1 schema. A
syntax-only response contains ordered global diagnostics and no plan. A move
returns the exact successor snapshot, `verified_change` or `unchanged`, and its
authoritative analysis.

Generate requires ready semantics and writer-safe content. Its success contains:

```json
{
  "response": "beamer_artifact",
  "sourceRevision": 0,
  "artifact": {
    "mediaType": "application/x-tex",
    "encoding": "base16",
    "source": "..."
  }
}
```

The artifact is deliberately not a `SourceBufferSnapshot`: it has no live
revision or persistence authority. Unknown fields, nonzero frame indices,
numeric coordinates, malformed base16, and invalid nested objects fail closed.
Protocol errors never echo authored or generated source.

## Session and history implications

This slice does not decide the open P2 source-history questions and does not add
a second JavaScript document state.

If implemented against the current stateless engine boundary, the browser uses
the same joint `(revision, exact textarea bytes)` request/response fences as
Slice 1. A response cannot replace text authored after its request began.

When the proposed Haskell `AppSession` lands, it owns the
`BeamerDocumentSnapshot`, source history, last-good plan, and format tag.
Direct invalid source is accepted into that Haskell session; a semantic move is
one verified history transaction; Generate creates no history entry. The app
protocol may wrap these engine operations, but it must not duplicate parsing,
projection, or writing.

## Browser and native composition

The browser host may:

- transport exact bytes to Wasm;
- validate the closed response;
- reuse the existing Slice 1 DOM/SVG renderer;
- translate pointer coordinates to exact decimal intent strings;
- show global diagnostics and the generated artifact preview; and
- download the generated artifact on an explicit user action.

It may not:

- parse TeX, Beamer, or TikZ;
- locate a picture body or coordinate token;
- infer a frame or picture model from the DOM;
- generate LaTeX source;
- authorize a stale or syntax-only move; or
- replace authored source with generated output implicitly.

The native CLI proof is:

```text
slideblaster beamer analyze FILE
slideblaster beamer move-node FILE 0 NODE_ID X Y [--write]
slideblaster beamer generate FILE
```

`analyze` and `move-node` follow the existing TikZ CLI exit, dry-run, and safe
conditional-persistence behavior. `generate` writes only the exact generated
artifact bytes to stdout on success and never modifies `FILE`; diagnostics go
to stderr and failure writes no partial artifact.

## Vertical implementation increments

Each increment ends at the real browser and native boundaries. A parser-only or
writer-only package checkpoint is not a completed increment.

### S2.1 — open and render one authored frame

```text
full .tex source
  -> structural CST and Beamer analysis
  -> embedded Slice 1 plan
  -> native analyze
  -> Wasm response
  -> real browser frame render
```

Acceptance includes the noncanonical fixture, CRLF/Unicode/trivia identity,
global embedded spans, unsupported preamble/frame/picture diagnostics, an
inert last-good canvas, native/Wasm golden equality, and a real browser check.

### S2.2 — move one direct coordinate

```text
pointer drag
  -> MoveBeamerNode
  -> verified child move
  -> lifted parent patch
  -> full-document verification
  -> source and canvas successor
```

Acceptance includes x-only, y-only, both-coordinate, no-op, stale, source-race,
syntax-only, wrong-frame, injected child-delta failure, injected full-verifier
failure, native dry-run/write, Wasm parity, and exact full-source complement
properties.

### S2.3 — generate a clean new document

```text
ready presentation
  -> explicit Haskell writer
  -> native stdout artifact
  -> Wasm artifact response
  -> browser preview/download
```

Acceptance includes the canonical golden, determinism, readback semantic
equality, unsafe-content refusal, no current-source/history mutation,
native/Wasm byte equality, and a browser assertion that Generate cannot
overwrite the source pane. Optional `lualatex` compilation of the safe golden
is extra evidence only.

### S2.4 — adversarial closure and independent review

Run arbitrary-byte recovery, nested/mismatched environment, comment-delimiter,
duplicate frame/picture, portable-span, revision exhaustion, diagnostic
redaction, request-race, and full native/Wasm/browser gates. An independent
reviewer derives cases from this specification rather than from implementation
branches.

## Non-overlapping implementation ownership

After the user gate, the orchestrator should assign these disjoint paths:

| Work node           | Owned path                                                               | Depends on                     | Output                                                    |
| ------------------- | ------------------------------------------------------------------------ | ------------------------------ | --------------------------------------------------------- |
| Structural TeX      | `packages/slideblaster-tex/**`                                           | frozen source API              | recoverable CST, byte-span and recovery laws              |
| Beamer document     | `packages/slideblaster-document/**`                                      | Structural TeX, frozen Slice 1 | one-frame analysis, provenance lift, verified parent move |
| Beamer writer       | `packages/slideblaster-writers/**`                                       | Beamer semantic types          | explicit canonical new-document writer and goldens        |
| Engine/protocol     | engine and protocol Beamer modules/tests only                            | document and writer APIs       | closed commands, codecs, stable CLI rendering             |
| Native composition  | CLI Beamer command modules/tests only                                    | engine/protocol                | analyze, dry-run/write move, stdout generate              |
| Browser composition | `hosts/web/**` plus one S2 browser fixture                               | Wasm artifact/protocol frozen  | plan reuse, pointer adapter, diagnostics, generation UI   |
| Integration         | root Cabal project files, `PROJECT.md`, protocol docs, build runbook     | all implementation nodes       | one reconciled package graph and verification report      |
| Independent review  | read-only production scope; disposable probes and its own ledger section | frozen implementation          | approve, request changes, or raise a decision brief       |

Only the integrator edits shared manifests and module maps. Engine/protocol work
has one owner because their ADTs, codecs, interpreters, and renderers are a
single schema boundary. Native and browser work begin only after that schema is
frozen. No S2 agent edits the frozen Slice 1 grammar or private candidate
constructors.

The dependency graph is:

```text
[user accepts literal format]
             |
             v
   [structural TeX CST]
             |
             v
 [Beamer document + edit] <---- [frozen Slice 1]
             |
       +-----+------+
       |            |
       v            v
   [writer]   [engine/protocol]
       |            |
       +------+-----+
              v
       +------+------+
       |             |
       v             v
   [native CLI]  [Wasm/browser]
       |             |
       +------+------+
              v
      [independent review]
              |
              v
     [integration + docs]
```

## Deliberately deferred

- arbitrary LaTeX and Beamer macro expansion;
- a general TeX evaluator or compile service;
- multiple, titled, option-bearing, overlay, notes, columns, or text frames;
- additional packages or preamble declarations;
- TikZ options, styles, scopes, macros, loops, paths, or any widening of Slice
  1;
- tri-dialect content and general TeX escaping;
- themes, furniture, assets, bibliography, or the multi-file `toTeX` export;
- a whole-document formatter or “normalize current source” command;
- browser working-copy persistence and Git publication gates;
- a native GUI; and
- partial editing of a supported frame while an ignored surrounding construct
  could affect its meaning.

These exclusions are visible capability boundaries, not promises that the
excluded constructs are permanently outside SlideBlaster.
