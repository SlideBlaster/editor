---
status: accepted
updated: 2026-07-23
---

# Source snapshot and presentation model

## Public model

The public engine should remain small:

```haskell
openSource
  :: Reader format
  -> ByteString
  -> Either OpenError (DocumentSnapshot format)

renderCanvas
  :: Measurements
  -> DocumentSnapshot format
  -> Either RenderError RenderPlan

replaceAuthoredSource
  :: Revision
  -> ByteString
  -> DocumentSnapshot format
  -> Either SourceEditError (DocumentSnapshot format)

applyEdit
  :: EditIntent
  -> DocumentSnapshot format
  -> Either EditError (DocumentSnapshot format)

writeAs
  :: ExportRequest target
  -> DocumentSnapshot source
  -> ExportReport
```

The implementation may use more phases, but clients hold one coherent
`DocumentSnapshot`. They do not assemble source, syntax, meaning, or provenance
independently.

`Presentation`, canvas/layout semantics, presenter beats, and the target-aware
`ExportReport` are defined in
[product-model.md](product-model.md). `ExportReport` carries artifacts and
fidelity diagnostics; writers never silently drop a feature.

## Document and source-buffer snapshots

`SourceBufferSnapshot`, owned by `slideblaster-source`, contains only exact bytes
and their process-local revision. It deliberately knows nothing about formats,
syntax, provenance, or presentations.

Conceptually, the source and syntax exist in both states while semantic meaning
exists only after successful elaboration:

```haskell
data DocumentSnapshot format = DocumentSnapshot
  { source      :: SourceBufferSnapshot
  , syntax      :: SyntaxTree format
  , semantic    :: SemanticState
  , diagnostics :: [Diagnostic]
  }

data SemanticState
  = SemanticallyReady Presentation ProvenanceMap
  | SyntaxOnly (NonEmpty Diagnostic)
```

During error recovery, the newest source and syntax remain authoritative even if
no current semantic presentation is available. The application may retain an
older rendered snapshot for display, but it is inert and cannot overwrite the
newer source revision. `renderCanvas`, semantic editing, and semantic writers
return a typed unavailable error for a syntax-only snapshot.

## Internal forward phases

```text
authored bytes
  -> lossless, recoverable CST
  -> semantic Presentation/Picture
  -> measured and resolved layout
  -> typed RenderPlan
```

This is more machinery than Pandoc's usual `Reader -> AST -> Writer` because
Pandoc primarily converts documents. SlideBlaster must also keep a hand-authored
source file synchronized with direct manipulation of a measured canvas. The
extra phases do not become five public models; they are internal boundaries held
together by one `DocumentSnapshot`.

| Phase                             | What it contains                                                                                 | Why it exists                                                                                                         | Authority and lifetime                                                                                 |
| --------------------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Authored bytes                    | Exact input bytes plus revision in `SourceBufferSnapshot`.                                       | This is the user's save value; decoded or normalized text is insufficient.                                            | Authoritative for persistence. Lives for the whole document revision.                                  |
| Lossless recoverable CST          | Tokens, comments, whitespace, delimiters, unknown constructs, malformed regions, and byte spans. | Precise edit slots and recovery require information a semantic AST normally discards.                                 | Authoritative for concrete spelling, never for semantic meaning. Lives with its exact source revision. |
| Surface AST, when earned          | A format-shaped view such as TeX commands or Markdown blocks.                                    | It can make a difficult grammar easier to elaborate, but a needless permanent layer adds synchronization risk.        | Optional and normally transient; never independently persisted.                                        |
| Semantic `Presentation`/`Picture` | Format-independent slide meaning, stable identities, and source provenance.                      | Canvas intents and writers need one domain vocabulary rather than separate Markdown, TikZ, LaTeX, and DOM behaviours. | Derived analysis valid only for its source revision. It may be absent after a bad direct source edit.  |
| Resolved layout                   | Styles, constraints, references, and supplied measurements resolved to geometry.                 | Meaning is not geometry: target measurements may change without changing authored semantics.                          | Recomputable cache tied to semantic revision and measurement inputs.                                   |
| Typed `RenderPlan`                | Validated renderer-neutral drawing and interaction instructions.                                 | The browser renders a closed plan without learning source grammar or semantic policy; other renderers can share it.   | Ephemeral output. It never gains source or persistence authority.                                      |

Pandoc can normally discard trivia, reject malformed input, and emit a newly
serialized target because conversion is its primary job. SlideBlaster promises
exact trivia preservation, recoverable malformed source, byte-local inverse
editing from a visual gesture, and revision-fenced synchronization with an
interactive code pane. Those promises are the reason for the extra internal
state.

The semantic model contains presentation meaning. It does not contain browser
DOM nodes and does not duplicate source strings merely for convenient printing.
Exact spellings remain in the CST and are reached through provenance.

Layout and render plans are derived caches. Writers consume presentation
meaning, not the DOM render plan.

## Internal reverse edit

The public operation is `applyEdit`. Internally:

```text
EditIntent
  -> intended semantic change
  -> provenance-authorized candidate source patch
  -> exact revision and expected-byte checks
  -> patch application
  -> reparse and elaborate
  -> semantic verification
  -> new DocumentSnapshot
```

Each step closes a different failure mode:

| Step                              | Responsibility                                                                                                         |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Typed `EditIntent`                | Describes what the user meant, such as moving a particular node, without smuggling source text through the canvas API. |
| Intended semantic change          | Computes the before/after domain value and rejects an invalid domain operation before touching source.                 |
| Provenance-authorized candidate   | Finds the exact authored slot whose inverse rule permits this edit; merely knowing a broad source span is not enough.  |
| Revision and expected-byte checks | Rejects stale gestures and concurrent changes before applying the local splice.                                        |
| Reparse and elaborate             | Proves the produced bytes are still accepted by the reader and determines their actual meaning.                        |
| Semantic verification             | Compares that actual meaning with the intended after-value, catching an incomplete or incorrect inverse projection.    |
| New snapshot                      | Crosses the atomic commit boundary only after every earlier check succeeds.                                            |

The candidate/verified distinction is an internal type-safety mechanism. A
checked byte replacement in bootstrap Slice 0 is deliberately not a
`VerifiedEdit`; that name is reserved for a patch that completes reparse,
elaboration, and semantic equivalence. The application does not manipulate
either internal phase.

Revision checking prevents a canvas drawn from source revision `r` from writing
over source revision `r + n`. Expected-byte checks additionally reject a patch
when its owned slot no longer contains what its projection inspected.

Semantic verification is required because TikZ inverse editing is partial.
Macros, loops, styles, scopes, and coordinate expressions may map one authored
construct to many semantic values or combine several authored values into one.
Knowing a source span does not by itself identify a correct inverse.

## Direct authored-source path

The code pane does not masquerade as a semantic canvas intent:

```text
new authored bytes + expected revision
  -> revision fence
  -> create next SourceBufferSnapshot
  -> lossless reparse
  -> elaborate when possible
  -> DocumentSnapshot (ready or syntax-only)
  -> source history / persistence
```

Malformed direct input remains the newest authoritative source so the user can
repair it. It may enter source undo/history and persistence. If elaboration is
unavailable, the application may display the last good render as an inert cache,
but that render cannot edit or overwrite the newer revision.

## Provenance and editability

Provenance is field-grained:

```haskell
data Origin value
  = DirectSlot (SlotRef value)
  | DerivedBy ProjectionRule
  | ExpandedFrom ExpansionSite
  | GeneratedAt InsertionSite
  | ReadOnly NonEditableReason
```

A direct position slot can be replaced automatically. Expanded or derived
values are canvas-read-only until an explicit inverse rule exists. An explicit
normalize or expand command may be added later, but normal editing never
silently flattens authored abstractions.

## Saving and writing

The accepted behaviour is:

- **Save direct source authorship:** persist the newest revision-fenced authored
  bytes, even when its document snapshot is syntax-only.
- **Save a canvas-derived change:** persist only the result of a verified
  semantic edit.
- **Write another format:** generate artifacts from semantic meaning and a
  target writer.

Ordinary editing never canonicalizes the entire document. Whether SlideBlaster
later offers an explicit whole-document formatter, and what its policy would be,
is deferred.

SlideBlaster Markdown, bare TikZ, wrapped TikZ, and LaTeX/Beamer enter through
vertical reader/writer slices. No format is declared fully bidirectional until
its exact-source and inverse-edit laws pass for a stated subset.
