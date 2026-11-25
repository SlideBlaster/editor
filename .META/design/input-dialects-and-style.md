---
status: proposed
updated: 2026-07-29
---

# Mixed input dialects, unified style, and bidirectional editing

## Purpose

A slide's authored source mixes TeX/TikZ, HTML, and Markdown. This document
defines how SlideBlaster reads that mixture, represents style once, and edits it
from both the source pane and the canvas while preserving the dialect each
construct was authored in.

The governing requirement is stated as a user-visible law:

> Increasing the font size or changing the colour of text authored in LaTeX
> changes it the LaTeX way. Doing the same to text authored in HTML changes it
> the HTML way. Neither operation rewrites the other dialect, and neither
> normalizes the document.

## Relationship to existing decisions

This design requires product-owner acceptance because it changes three accepted
cross-cutting decisions. Until accepted it remains `proposed`.

| Decision | Change | Reason |
| --- | --- | --- |
| `../../design/decisions/0015-out-of-subset-is-a-hard-error.md` | Superseded | Hard error blocking commit is incompatible with a deliberately growing subset, and already contradicts this repository's `AGENTS.md` source-editing invariants 2 and 7, which require unsupported syntax to be preserved and read-only rather than fatal. |
| `../../design/decisions/0007-node-content-tri-dialect.md` | Amended | Its rule that content never re-embeds a TikZ picture is withdrawn. Its provenance-preserving tri-dialect core is retained and strengthened. |
| `../../design/decisions/0004-slide-is-a-tikz-picture.md` | Amended | A slide picture may contain a nested picture or scope as one bounded object. Its single-scene-model decision is retained; nesting reuses that model recursively rather than introducing a second one. |

ADR 0007's instinct against two competing scene models is correct and is
preserved. What is withdrawn is the conclusion that nesting would create one.

## Problem statement

The failure mode this design exists to avoid: parsing several dialects into one
unified abstract syntax tree erases which dialect authored each construct, then
reattaches dialect as descriptive metadata. That metadata cannot write anything
back, so every edit degrades into normalization and the product silently rewrites
the user's source.

The current code has already reached that wall. `SlideBlaster.Document.Provenance`
defines

```haskell
newtype ProjectionRule = ProjectionRule Text
```

which names an inverse rule whose implementation exists nowhere. There is
therefore no executable path from a semantic edit back to authored bytes.

## Architecture

Three layers, with dialect surviving in the middle layer rather than being
erased by it.

```text
per-dialect lossless CST
  exact bytes, spans, comments, delimiters, malformed regions
  one CST per dialect, faithful to that dialect's grammar
        |
        |  a single parse pass emits both products below
        v
semantic model                        slot table
  dialect-free meaning                  span + dialect + scope per construct
  plain comparable data                 write capability
        |
        v
render plan
```

The semantic model stays ordinary comparable data so the existing reparse-and-
compare verification law continues to work unchanged. The slot table carries the
ability to write, is fenced to one revision, and is disposable with the same
lifecycle as a render plan. It never crosses the protocol boundary.

### Total parse, bounded interpretation

Two distinct boundaries, which ADR 0015 conflated into one:

- **Syntactic parse is total.** The CST faithfully represents every input,
  including constructs with no semantic support. `\newcommand` parses: it is
  structurally a name, a parameter text, and a body.
- **Semantic interpretation is bounded and grows deliberately.** Which parsed
  constructs gain meaning, painting, and canvas editability is the subset, and
  the subset is what expands over time.

Consequences:

- Unsupported input is preserved byte-exactly, marked read-only, locatable in a
  diagnostics surface, and does not prevent the rest of the node from painting
  or the document from committing.
- Adding support later means adding a semantic mapping and a spelling row. It
  does not mean touching the parser.

**TeX is parsed structurally and never expanded.** Faithful parsing of TeX
groups, tokens, and macro definitions is tractable; macro expansion is
implementing TeX. A construct whose meaning depends on expansion is exactly the
case `AGENTS.md` invariant 7 makes read-only. The boundary is therefore a
property of the design rather than an apology for a limitation.

## Unified style representation

### Defects in the current model

`SlideBlaster.Canvas.Property` cannot express the governing requirement. The
specific defects this design removes:

1. **Fixed arity.** `NodePropertyPatch` has thirteen hardcoded fields. Adding one
   option requires editing the patch record, `emptyNodePropertyPatch`,
   `mergeNodePropertyPatch`, `NodeProperties`, `defaultNodeProperties`, and
   `applyNodePropertyPatch`. Roughly two hundred of the module's lines are
   hand-written `prefer` and `maybe` boilerplate, duplicated for connectors.
2. **No authorship.** A patch records the value and never which key spelled it or
   where in source. There is no path back to `text=red` versus `\textcolor{red}{}`
   versus `style="color:red"`.
3. **Minimal edits are unrepresentable.** `nodePatchTypography :: Maybe Typography`
   wraps a ten-field total record, so changing only the colour requires supplying
   family, size, weight, posture, decoration, both alignments, wrap width, and
   line spacing.
4. **Duplication.** Nine of thirteen node fields repeat for connectors, with two
   parallel copies of merge and apply.
5. **A third disjoint vocabulary.** `Canvas.Content` carries
   `InlineColour !Text`, untyped, while `Canvas.Property` carries a structured
   `ColourRef` with palette resolution. Same concept, two encodings, no
   conversion.

### The model

One fact type per semantic property, each carrying its own value type, plus a
value-free key:

```haskell
data StyleFact
  = Fill        !Paint
  | Stroke      !Paint
  | StrokeWidth !Length
  | Dash        !DashPattern
  | Opacity     !UnitInterval
  | TextColour  !ColourRef
  | FontSize    !Length
  | FontWeight  !Weight
  | FontPosture !Posture
  | Decoration  !Decoration
  | Corners     !CornerTreatment

data StyleKey
  = KFill | KStroke | KStrokeWidth | KDash | KOpacity
  | KTextColour | KFontSize | KFontWeight | KFontPosture
  | KDecoration | KCorners
  deriving stock (Eq, Ord, Show, Enum, Bounded)

styleFactKey :: StyleFact -> StyleKey

newtype StylePatch = StylePatch (Map StyleKey StyleFact)
```

`StylePatch` construction enforces that each map key equals its fact's key, so
the redundancy cannot desynchronize.

Properties of this shape:

- Merge is `Map.union higher lower`. The duplicated field-by-field boilerplate
  disappears.
- Adding an option is one `StyleFact` constructor, one `StyleKey`, and one
  spelling row.
- A minimal edit is a single-entry map, which removes defect 3.
- Node and connector share one representation; applicability is a predicate
  rather than a duplicated record.
- `Enum` and `Bounded` on `StyleKey` make exhaustiveness executable: every key
  must have a spelling or an explicit inexpressible marker in every dialect.

`NodeProperties` and `Typography` survive as a derived total view computed by
folding the resolution chain for the renderer. They stop being the model.

### Scope unifies node and span styling

```haskell
data StyleScope
  = PictureScope
  | ObjectScope !ElementId
  | SpanScope   !ElementId !SourceSpan
```

Node-level colour and inline-span colour become the same `TextColour` fact at
different scopes. Only the surface spelling differs. This resolves the current
split in which node font and colour live in `Canvas.Property` while inline
colour lives in `Canvas.Content`.

## Dialect projection

Spelling is data, not control flow:

```haskell
data Spelling
  = LatexOption   !Text   -- text=red, inside a TikZ option list
  | LatexMacro    !Text   -- \textcolor{red}{...}
  | HtmlAttribute !Text   -- style="color:red"
  | HtmlElement   !Text   -- <b>...</b>
  | MarkdownFence !Text   -- **...**
  | Inexpressible         -- this dialect cannot state this fact

spelling :: Dialect -> StyleScope -> StyleKey -> Spelling
```

A total function, exhaustively testable, and the single place support grows.
`spelling Markdown _ KTextColour = Inexpressible` is a recorded fact rather than
a special case buried in editor code.

The write path is then uniform: read the target construct's dialect and scope
from its slot, look up the spelling, splice into the slot's span. There is no
dialect dispatch scattered through the editor, so a dialect cannot be forgotten
at one call site.

## Promotion

When the target dialect returns `Inexpressible`, or a selection spans dialects,
promote minimally and visibly, in this order:

1. The construct's own dialect can express the fact. Use it. Dialect preserved.
   This is the common path and the governing requirement.
2. Otherwise, if the enclosing container's dialect can express the fact without
   modifying the inner construct, wrap in the enclosing dialect.
3. Otherwise wrap in the project's configured fallback dialect (HTML, which
   alone covers colour and underline) and record the result as promoted, naming
   the dialect and the key.

Recolouring `**bold**` therefore yields
`<span style="color:red">**bold**</span>`: the Markdown is preserved inside and a
minimal HTML wrapper is added, rather than rewriting the run to `<b>`.

Step 3's visibility is a product requirement, not a diagnostic nicety. Silent
promotion is what makes users distrust a source-preserving editor.

## Bidirectional editing

The two directions are asymmetric, and conflating them is the second classic
failure mode.

**Source pane to canvas.** Reparse the dirty region, rebuild the semantic model,
diff, repaint. Source is frequently invalid mid-keystroke, so the last-good
semantic model remains the paint source and the canvas becomes inert but visible
rather than blank. This reuses the existing syntax-only snapshot and inert
last-good canvas behaviour.

**Canvas to source.** A verified transaction under the existing law: propose a
patch, splice bytes, reparse, compare the semantic result against the stated
intent, then commit or abort atomically with no state effect on failure.

Simultaneous editing requires nothing new. Source bytes plus one revision remain
the sole authority and canvas edits are revision-fenced, so a stale canvas patch
is rejected rather than merged.

### Laws

The two directions compose into a round-trip property:

```text
parse (project (edit (parse s))) == edit (parse s)
```

The executable law suite is:

- `prop_exactRoundTripPreservesBytes` over the normative corpus in
  `../../design/format/node-content.md`, cases 1 to 5, byte-identical.
- `prop_dialectPreservedUnderRestyle`: restyling a LaTeX run emits LaTeX,
  an HTML run emits HTML, and a Markdown run promotes visibly.
- `prop_unsupportedConstructPreservedAndReadOnly`: an unsupported construct keeps
  its bytes, is marked read-only, and does not prevent the remainder of the node
  from painting.
- `prop_unownedBytesRemainIdentical`.
- `prop_staleRevisionCannotCommit`.
- `prop_projectionFailureHasNoStateEffect`.
- `prop_spellingTableIsTotal` over `[minBound .. maxBound] :: [StyleKey]` for
  every dialect and scope.

## Nested pictures

```haskell
NestedPicture !Transform !Canvas
```

Positioning, moving, or scaling the unit edits only the wrapper: the node's `at`
coordinate, or a `\begin{scope}[shift={(x,y)}]`. Inner bytes are never touched by
an outer gesture. Editing inside the unit is recursive descent through the same
machinery.

This is one scene model applied recursively, which is what ADR 0004's
single-model decision protects. It admits the case that matters in practice:
pasting an existing self-contained `tikzpicture` and positioning it as one
object.

## Module plan

New modules in `slideblaster-canvas`, added additively so that existing
dependents keep compiling:

| Module | Responsibility |
| --- | --- |
| `SlideBlaster.Canvas.Dialect` | `Dialect`, `Spelling`, and the total `spelling` table. Leaf module. |
| `SlideBlaster.Canvas.Style` | `StyleFact`, `StyleKey`, `StylePatch`, `StyleScope`, resolution chain. |

`SlideBlaster.Canvas.Content` imports and re-exports `Dialect` from the new leaf
module so its public API is unchanged and the vocabulary is not duplicated.

Cutting `Canvas.Property` over to the derived-view role is a separate later step,
deliberately not bundled with this one, because `canvas`, `render`, `export`,
`catalog`, and `app` all depend on it.

Parsers are separate subsequent work and are not part of the first slice.

## Slice sequence

1. **Style core.** `StyleFact`, `StyleKey`, `StylePatch`, `StyleScope`,
   resolution, the `spelling` table, and totality tests. Pure, no parser, no
   browser, no contention with the active P0 session.
2. **Slot table and projection.** Spans, scopes, splice, promotion, verified
   transaction, and the round-trip law against hand-built semantic trees.
3. **Readers.** Markdown, then HTML, then TeX/TikZ, each producing the shared
   span-carrying CST and slot table.
4. **Nested pictures.**
5. **Property cutover.** `Canvas.Property` becomes the derived view.
6. **Wiring.** Protocol, host, and canvas surface.

## Open questions

- **Parser dependencies.** `commonmark` and `tagsoup` or `html-parse` are mature,
  but no Haskell library parses LaTeX losslessly with spans, so that reader is
  hand-written regardless. Mixing two library syntax trees with one hand-rolled
  tree may cost more than writing all three against the shared span-carrying
  CST. Current lean: write all three. Requires a dependency decision under
  `AGENTS.md`.
- **Configured fallback dialect.** HTML is proposed as the promotion target and
  the canvas-authoring default. Whether this is per project or per document is
  unsettled.
- **Incidental normalization.** Which within-dialect reformatting a first save
  may perform, inherited unresolved from
  `../../design/format/node-content.md`.
- **Nested picture coordinate contract.** Whether a nested picture's inner
  coordinates are independent or inherit the outer frame.
