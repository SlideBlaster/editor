# Research artifact: p0-1-tikz-breadth (fixture)

- Slug: `SB2-20260727-001--p0-1-tikz-breadth--fixture-analyst--01`
- Session: `SB2-20260727-001`
- Agent: `fixture-analyst`
- Created: `2026-07-29`
- Status: `complete`

# P0.1 Core TikZ authoring breadth: candidate fixture

Session `SB2-20260727-001`, node 2 (fixture analyst), run 01.
Worktree `/home/t/Documents/slide/slideBlaster/sb2-SB2-20260727-001`,
branch `session/SB2-20260727-001`, registration baseline `cbe29eb`.

Research is evidence, not a decision. Nothing here is accepted; the designer
(node 3) and the orchestrator own the resulting contract.

## Question

Which single `.slide` document should P0.1 use as its representative real-world
TikZ authoring fixture, and exactly how far does the current implementation fall
short of admitting it?

## Deliverables

| Path | Role |
| --- | --- |
| `candidate.slide` | The candidate fixture (this run's only data artifact). |
| `README.md` | This report. |

No product file was created, modified, or deleted by this run. `candidate.slide`
is deliberately **not** placed in `hosts/web/fixtures/` or any package test
directory; promotion is the implementer's governed action.

## Identity of the candidate

| Property | Value |
| --- | --- |
| Path | `.META/research/SB2-20260727-001--p0-1-tikz-breadth--fixture-analyst--01/candidate.slide` |
| Byte size | `6487` |
| SHA-256 | `6781123f2fc759aabc82872d775c0f05000d46e0facdd90073ceaec745895a5e` |
| Lines | 242 |
| Line ending | LF only (`0` carriage returns) |
| Encoding | UTF-8; one non-ASCII character (U+2014 em dash, line 106) |
| Slides | 2 (`architecture`, `backpressure`), each with a `note` surface |
| Named nodes | 10 on `architecture`, 6 on `backpressure` (16 total) |

Reproduce:

```sh
cd /home/t/Documents/slide/slideBlaster/sb2-SB2-20260727-001
wc -c .META/research/SB2-20260727-001--p0-1-tikz-breadth--fixture-analyst--01/candidate.slide
sha256sum .META/research/SB2-20260727-001--p0-1-tikz-breadth--fixture-analyst--01/candidate.slide
```

## Provenance and licence reasoning

`candidate.slide` is **original content authored in this run**. Nothing was
copied from an external document, book, tutorial, gallery, TeX Stack Exchange
answer, or the PGF/TikZ manual. No network upload of project data occurred; no
external source text was pasted in.

What was reused, and how:

- **Format.** The parent grammar (`deck` header, repeated
  `slide ID "title" (metadata) """body"""`, optional trailing `note """..."""`)
  is copied structurally from the in-repository fixture
  `hosts/web/fixtures/demo.slide` and the accepted provisional spec
  `docs/specs/str-007-implicit-canvas-slide-trial.md`. Both are project files.
- **Idiom vocabulary.** The TikZ constructs used (`\tikzset` with `foo/.style`,
  `\node[...] (id) at (x,y) {...}`, `right=12mm of x`, `\draw[-stealth]`,
  `-{Latex[length=...]}`, `|-`, `-|`, `\foreach ... in {...}`, `calc` `($...$)`
  expressions, `\begin{scope}[shift={...}, opacity=...]`, `\path ... rectangle
  ...`) are the standard public interface names of the PGF/TikZ package. Names
  of a public API are not copyrightable expression, and no example code carrying
  them was reproduced.
- **Structural inspiration only.** Legacy in-repository examples
  (`../editor/packages/app/src/examples/pipeline.tikz`, `flowchart.tikz`,
  `shapes.tikz`, `../editor/packages/app/src/showcase/p4checkarch.tikz`) were
  read to see how the previous implementation shaped real figures. None of their
  text was copied. `p4checkarch.tikz` was explicitly rejected as a candidate: it
  is a paper figure whose every coordinate is macro-computed or `calc`-derived,
  so it would produce a fixture with **zero** writable nodes and would therefore
  not exercise the editing half of P0.1.

Licence position: the candidate carries the same licence as the rest of this
repository, whatever the product owner sets. There is no third-party licence
obligation, no attribution requirement, and no provenance ambiguity to resolve
before promoting it into `hosts/web/fixtures/`. All person and organisation
names in the fixture are invented placeholders (`Dana Reyes`, "Platform guild
review"); no real PII is present.

## Why it is realistic

The subject is an event ingest platform review: edge collector, decode against a
schema registry, tenant/geo enrichment, a hot columnar store, a query surface, a
`p99` overflow gate, and an append-only audit log. This is the shape of diagram
that actually appears in internal architecture talks, and it is realistic in the
ways that matter to P0.1:

1. **The layout is mixed, not gridded.** Some boxes are pinned to absolute
   coordinates because the author cares where they sit; the ingest row is
   authored relatively (`right=12mm of ...`) because the author cares about
   spacing, not position. Real decks contain both in the same picture, and the
   product must distinguish them.
2. **The prose is real prose.** The contract card carries a Markdown ordered
   list with bold runs, an em dash, an HTML `div`, and inline LaTeX; the budget
   node carries display math; the backpressure card carries a Markdown bullet
   list plus an HTML `div` with inline math. This is exactly the mixed-content
   payload STR-007 admits, and it is the case that breaks placeholder rendering.
3. **The styles are style-defined, not inlined.** Five of the diagram nodes get
   their shape, fill, stroke, width, and font from `\tikzset` style names, while
   three nodes carry the same properties inline. That asymmetry is the realistic
   case, and it forces an honest answer about which geometry has a source
   inverse and which does not.
4. **The connectors are not all straight lines.** Storage to query surface and
   decode to audit log are routed orthogonally (`|-`, `-|`) because that is how
   people actually draw side channels. Arrow tips are both the shorthand
   (`-stealth`) and the parameterised arrows form (`-{Latex[length=2.4mm]}`).
5. **It contains regions no honest editor should touch.** A generated shard
   fan-out, a decorative shadow inside a transformed scope, worker lanes drawn
   by a loop, and two border-relative tag nodes. Real decks are full of these,
   and the product's credibility depends on preserving them exactly while making
   their read-only status visible.
6. **It is a deck, not a diagram.** Two slides with notes keep navigation, New
   Slide, and the notes surface exercisable, so P0.1 does not regress the
   observed P0 behaviours while proving breadth.

The second slide is deliberately simpler than the first. It is the fixture's
**working floor**: it is already fully admitted by today's parser (evidence
below), so the implementer has a green baseline while slide 1 drives the gap.

## Line map

| Lines | Region |
| --- | --- |
| 1-8 | `deck` header and opaque metadata |
| 10-13 | `slide architecture` header, metadata, body open |
| 14-15 | TikZ line comments |
| 16-55 | `\tikzset` custom style definitions |
| 57-59 | node `title` |
| 61 | comment |
| 62-65 | node `edge-collector` (absolute) |
| 67-70 | node `decode` (relative) |
| 72-75 | node `enrich` (relative) |
| 77 | node `overflow` (relative, circle, math-only content) |
| 79-82 | node `hot-store` (absolute) |
| 84-87 | node `query-api` (absolute) |
| 89-100 | node `audit-log` (absolute, multi-line inline options) |
| 102-112 | node `contract` (absolute, Markdown + HTML + inline math) |
| 114-120 | node `budget` (absolute, display math + HTML span) |
| 122-126 | straight connectors, one with a mid-path label node |
| 128-132 | orthogonal connectors (`\|-`, `-\|`) |
| 134-139 | `\foreach` shard fan-out with `calc` computed coordinate |
| 141-146 | `\begin{scope}[shift=..., opacity=...]` with `\path ... rectangle` |
| 148-150 | node `sla-tag` at a computed `([xshift=4mm]query-api.east)` |
| 151-162 | body close, `note` surface |
| 164-167 | `slide backpressure` header |
| 168-170 | node `heading` |
| 172-180 | node `queue` (circle, `anchor=center`) |
| 182-193 | node `consumer` |
| 195-206 | node `dead-letter` |
| 208-219 | node `reading` (Markdown list + HTML + inline math) |
| 221 | straight connector with `-stealth` |
| 222-223 | orthogonal connector with `-{Latex[length=2.4mm]}` |
| 225-230 | `\foreach` worker lanes over computed offsets |
| 232-234 | node `depth-tag` at a computed `([yshift=7mm]queue.north)` |
| 235-242 | body close, `note` surface |

## Capability coverage

The eleven capabilities are the breadth list in the governing prompt
`.META/sessions/SB2-20260729-001/.prompt`.

| # | Required capability | Exercised at (lines in `candidate.slide`) |
| --- | --- | --- |
| 1 | Multiple named nodes on one slide | `architecture`: 57, 62, 67, 72, 77, 79, 84, 89, 102, 114 (ten named nodes). `backpressure`: 168, 172, 182, 195, 208, 233 (six). |
| 2 | Real node text and structured content, not identity placeholders | Markdown bold plus `\\` line break 63-64, 68-69, 73-74, 80-81, 85-86, 191-192, 204-205; Markdown ordered list 105-107; Markdown bullet list 211-213; HTML block 109-111, 215-218; HTML inline span 119; inline LaTeX math 77, 110, 217; display LaTeX math 116-118; non-ASCII em dash 106; plain-text node 99, 180. |
| 3 | Common node options: anchor, text width, shape, fill, stroke, typography | Anchor: 57, 62, 79, 84, 97, 102, 114, 149, 168, 179, 189, 202, 208, 233. Text width: 22, 32, 50, 57, 94, 114, 187, 200, 208. Shape: `rounded corners` 20, 30, 48, 92, 185, 198; `circle` 40, 175; implicit rectangle 89-100, 182-193. Fill: 19, 29, 39, 47, 91, 174, 184, 197. Stroke colour: 18, 28, 38, 46, 53, 54, 90, 173, 183, 196, 221, 222, 228. Stroke weight: 21, 31, 41, 49, 53, 54, 93, 176, 186, 199, 221, 222, 228. Typography: 25, 35, 43, 51, 96, 137, 149, 178, 233; theme text styles `style=display` 57, 168 and `style=body` 114, 208. |
| 4 | Absolute and relative positioning with explicit writable or read-only provenance | Absolute `at (x,y)`: 57, 62, 79, 84, 98, 102, 114, 180, 190, 203, 208. Relative: 67 (`right=12mm of edge-collector`), 72 (`right=12mm of decode`), 77 (`below=14mm of enrich`). Computed/border-relative: 150 (`[xshift=4mm]query-api.east`), 234 (`[yshift=7mm]queue.north`), 138 (`calc` expression). |
| 5 | Straight and orthogonal connectors with visible arrow tips | Straight: 123, 124, 125, 126, 221. Orthogonal: 130 (`\|-`), 131 (`-\|`), 132 (`-\|`), 222-223 (`\|-`). Tips: `-stealth` 53, 221; `-{Latex[length=2.4mm]}` 54, 222; every connector inherits a tip through `flow`/`trace` or states one inline. |
| 6 | Connector geometry updates when an attached node moves | Every connector endpoint is a node-and-port reference, never a raw coordinate: 123-126, 130-132, 221-223. Moving the absolute nodes `hot-store` (79), `query-api` (84), `audit-log` (89), `dead-letter` (195), `consumer` (182), `queue` (172) must reroute the connectors that name them, including the orthogonal elbows at 130-132 and 222-223. |
| 7 | Selection and movement of any supported writable node | The eleven direct-coordinate nodes at 57, 62, 79, 84, 98, 102, 114, 180, 190, 203, 208 must all be selectable and movable, including the large mixed-content cards (102, 114, 208) and the circle (172). |
| 8 | Resize, create, duplicate, delete for the supported node subset | Direct literal size slots to resize: `text width=90mm` 57, `text width=22mm` 94, `text width=48mm` 114, `minimum size=18mm` 177, `text width=30mm` 187, `text width=30mm` 200, `text width=62mm` 208, `text width=90mm` 168. Whole-statement units to create, duplicate, or delete: each `\node ... ;` at 57-59, 62-65, 79-82, 84-87, 89-100, 102-112, 114-120, 168-170, 172-180, 182-193, 195-206, 208-219, and each `\draw ... ;` at 123-126, 130-132, 221-223. Nodes whose size comes only from a style name (62, 67, 72, 77, 79, 84, 102) have **no** literal width slot and must therefore be resize-read-only. |
| 9 | Exact source-local edits followed by complete reparse and intended-semantic verification | The coordinate lexeme pairs are the only bytes a move may touch: `(1,8.4)` 57, `(1,6.4)` 62, `(11.9,6.4)` 79, `(11.9,3.9)` 84, `(5.2,1.4)` 98, `(1,3.9)` 102, `(6.9,3.4)` 114, `(1,8.4)` 168, `(4,5.6)` 180, `(8.6,5.6)` 190, `(13.2,2.8)` 203, `(1,3.4)` 208. Mixed decimals and integers are present on purpose so the decimal round-trip law is exercised. Every unrelated byte, including the comments at 14-15, 61, 122, 128-129, 134-135, 141-142, 148, 225-226, 232, must be identical after any edit. |
| 10 | Exact preservation and visibly read-only treatment of unsupported or ambiguous TikZ | Custom style expansion 16-55; relative-positioned nodes 67-70, 72-75, 77; generated fan-out with `calc` coordinate and generated node names 136-139; transformed scope with computed rectangle 143-146; border-relative computed node placement 149-150, 233-234; generated decoration loop 227-230; mid-path label node 126; the `note` surfaces 153-162 and 237-242 (read-only in this trial per STR-007). |
| 11 | A meaningful real-world fixture rather than a specially minimal demonstration | The whole document; see "Why it is realistic". |

## Intended writable and read-only regions

These are proposals to the designer, expressed as the fixture's intent.

### Intended writable

| Node | Slide | Line | Writable because | Intended operations |
| --- | --- | --- | --- | --- |
| `title` | architecture | 57 | direct `at (1,8.4)`, `anchor=north west`, literal `text width=90mm` | move, resize, duplicate, delete |
| `edge-collector` | architecture | 62 | direct `at (1,6.4)`, `anchor=north west` | move, duplicate, delete |
| `hot-store` | architecture | 79 | direct `at (11.9,6.4)` | move, duplicate, delete |
| `query-api` | architecture | 84 | direct `at (11.9,3.9)` | move, duplicate, delete |
| `audit-log` | architecture | 89-100 | direct `at (5.2,1.4)`, `anchor=north`, literal `text width=22mm` | move, resize, duplicate, delete |
| `contract` | architecture | 102 | direct `at (1,3.9)`, `anchor=north west` | move, duplicate, delete |
| `budget` | architecture | 114 | direct `at (6.9,3.4)`, literal `text width=48mm` | move, resize, duplicate, delete |
| `heading` | backpressure | 168 | direct `at (1,8.4)`, literal `text width=90mm` | move, resize, duplicate, delete |
| `queue` | backpressure | 172-180 | direct `at (4,5.6)`, `anchor=center`, literal `minimum size=18mm` | move, resize, duplicate, delete |
| `consumer` | backpressure | 182-193 | direct `at (8.6,5.6)`, literal `text width=30mm` | move, resize, duplicate, delete |
| `dead-letter` | backpressure | 195-206 | direct `at (13.2,2.8)`, literal `text width=30mm` | move, resize, duplicate, delete |
| `reading` | backpressure | 208-219 | direct `at (1,3.4)`, literal `text width=62mm` | move, resize, duplicate, delete |

Resize is intended **only** where a literal dimension lexeme exists in the
node's own option list. `edge-collector`, `contract`, `hot-store` and
`query-api` take their width from a `\tikzset` style, so their width has no
source inverse and resize must fail closed there even though move succeeds.

### Intended read-only

| Region | Lines | Reason |
| --- | --- | --- |
| `\tikzset` style block | 16-55 | Style expansion. Editing a style silently rewrites every consumer, so it has no bounded inverse. |
| `decode`, `enrich`, `overflow` | 67-75, 77 | Relative placement. The authored intent is a gap from a neighbour, not a coordinate; writing a coordinate would destroy that intent. |
| Shard fan-out | 136-139 | Generated identities (`shard-\region`) and a `calc` coordinate. No authored node and no authored point exist. |
| Shadow scope | 143-146 | Scope transformation plus a node-relative `rectangle`. Geometry is derived from other nodes under a transform. |
| `sla-tag`, `depth-tag` | 149-150, 233-234 | Border-relative computed placement. |
| Worker lanes | 227-230 | Generated decoration over computed offsets. |
| Mid-path label node | 126 | Path-relative node with no independent placement. |
| Connector geometry | 123-126, 130-132, 221-223 | Derived from node ports; a connector is not independently placeable in this slice. |
| Colour, fill, stroke weight, font | throughout | Retained exactly; no inverse is proposed in P0.1. |
| `note` bodies | 153-162, 237-242 | STR-007 keeps notes non-editable in this trial. |
| Comments and blank lines | 14-15, 61, 122, 128-129, 134-135, 141-142, 148, 225-226, 232 | Authored source; must survive every edit byte-identical. |

The important asymmetry for the designer: **read-only must be visible.** A
region that is dropped from the model is not "read-only", it is invisible, and
the user cannot then understand why they may not touch it. Today the unsupported
regions of this fixture are invisible rather than read-only (see below).

## Current implementation behaviour

Two independent methods were used. Method A re-implemented the byte algorithms
of `packages/slideblaster-deck/src/SlideBlaster/Deck.hs` (`skipTriviaBounded`,
`statementEnd`, `balancedEnd`, `parseNode`, `optionPort`, `hasRelativeOption`,
`parseConnectors`) in a throwaway interpreter to predict chunking. Method B ran
the **compiled** parser through the existing prebuilt environment. Both agree.

Method B commands, run from the worktree root:

```sh
cabal repl slideblaster-deck -v0
# analyzeDeck (Source.snapshotFromBytes <candidate bytes>)
```

### Observed with the compiled parser

| Input | `documentSemantic` | Admitted slides | Diagnostic |
| --- | --- | --- | --- |
| `candidate.slide` (whole) | `Nothing` | 0 | `deck.node_at` |
| `hosts/web/fixtures/demo.slide` (control) | `Just` | 3 | none |
| candidate with slide 1 removed | `Just` | 1 | none |

On the slide-2-only variant the admitted picture entries were exactly:

```text
node "heading", node "queue", node "consumer", node "dead-letter",
node "reading", connector "path-1203-0"
```

and `writableNodePlacement` returned a placement for `heading`, `queue`,
`consumer`, `dead-letter`, `reading`, and nothing for `depth-tag`.

Two micro-decks isolated the remaining behaviours:

```text
\tikzset{ box/.style={draw} } \node (alpha) at (1,2){A}; \node (beta) at (4,2){B};
  -> admitted entries: node "beta" only
\node (alpha) at (1,2){A}; \node (beta) at (4,2){B};
\draw[->] (alpha.east) |- (beta.west);  \draw[->] (alpha.south) -- (beta.north);
  -> admitted entries: node "alpha", node "beta", connector "path-138-0"
```

### Expected rejections and degradations

Stated as gaps for the designer, not as fixture defects.

1. **Fatal, whole-document: relative nodes.** `parseNode` requires the literal
   sequence `\node[...] (id) at (x,y) {...};`. Lines 67, 72, and 77 are ordinary
   TikZ relative placements with no `at`, so `expectAscii "at"` fails with
   `deck.node_at`, `parseDeck` returns `Left`, and `analyzeDeck` produces a
   syntax-only document with **zero** admitted slides. The whole fixture,
   including the fully supported slide 2, becomes read-only. This is the single
   blocking gap: capability 4 cannot be demonstrated at all today.
2. **Silent loss: statement chunking swallows following statements.**
   `statementEnd` scans for the next `;` at brace depth zero, so any construct
   that is not semicolon-terminated absorbs whatever follows it. Confirmed:
   - `\tikzset{...}` (16-55) absorbs the `title` node (57-59), which then does
     not exist in the model at all;
   - `\foreach ... { ... }` (136-139) absorbs the `\path` inside the shadow
     scope (143-145);
   - `\end{scope}` (146) absorbs the `sla-tag` node (149-150);
   - `\foreach ... { ... }` (227-230) absorbs the `depth-tag` node (233-234).
   The bytes are preserved, but the user is given no object, no diagnostic, and
   no read-only affordance. This directly conflicts with capability 10 as the
   prompt words it ("visible enough for the user to understand their location
   and read-only status"). Note also that a body whose final statement lacks a
   `;` yields `deck.unclosed_statement` and fails the whole document.
3. **Silent loss: orthogonal connectors.** `parseConnectors` returns no
   connectors unless the statement contains `--`, so every `|-` and `-|`
   statement (130, 131, 132, 222-223) is dropped with no diagnostic. Confirmed
   on the slide-2-only variant, where only the straight connector at 221 was
   admitted. Capability 5's orthogonal half is entirely unimplemented.
4. **Arrow tips are not represented.** `connectorEntry` builds every connector
   with `[Canvas.StraightSegment]`, `OpenPath`, `connectorLabel = Nothing`, and
   `emptyConnectorPropertyPatch`. `-stealth`, `-{Latex[...]}`, dash pattern,
   colour, and weight are retained in source but absent from the model, so
   nothing downstream can paint a tip. The mid-path label at 126 is likewise
   dropped.
5. **Node styling is not represented.** `nodeEntry` hardcodes
   `PrimitiveGeometry RectangleOutline`, a single `TextRun` tagged `LaTeX`, and
   `emptyNodePropertyPatch`. Shape (`circle` at 40 and 175), fill, stroke,
   `text width`, `align`, `minimum height`, `minimum size`, and every font
   selection are invisible to the model. Capability 3 has no semantic carrier
   today, and capability 2 arrives as one undifferentiated LaTeX text run rather
   than structured mixed content.
6. **Connector identity is byte-offset derived.** `connectorId` is
   `"path-" <> show statementStart <> "-" <> show index`, an absolute byte
   offset in the whole document. The same statement produced `path-138-0` in a
   micro-deck and `path-1203-0` in the slide-2 variant. Any edit that changes
   the byte length of earlier text renames every later connector, which breaks
   stable selection across the very edits capability 6 demands.
7. **Resize has no writable surface.** `DeckFieldKey` exposes only
   `DeckAudienceX` and `DeckAudienceY`. There is no field key, provenance slot,
   or edit intent for `text width`, `minimum size`, creation, duplication, or
   deletion, so four of the five operations in capability 8 have no source
   inverse at all.
8. **Read-only detection has known false negatives.** `hasRelativeOption` only
   matches the exact top-level keys `above`, `below`, `left`, `right`, `of`
   immediately followed by `=`. It therefore misses `below right=of x`,
   `above left=1cm of x`, and the legacy `below of=x` spelling, and would mark
   such a node writable. The fixture deliberately avoids those spellings so it
   does not encode the bug, but the designer must close it before claiming
   capability 4.
9. **Anchor admission is narrow and fatal when unmet.** `optionPort` accepts
   only the eight compass names plus `center`/`centre`, rejects a node carrying
   two `anchor=` entries, and fails the whole document otherwise
   (`deck.node_anchor_unsupported`). It also splits the raw option text on every
   comma, so an `anchor=` nested inside a braced option value would be
   misdetected. The fixture stays inside the accepted set.
10. **Byte-level hazards to preserve in any successor parser.** `balancedEnd`
    treats `"` as a quote toggle inside node content and option lists, so a node
    body containing an odd number of double quotes would mis-balance braces; the
    fixture keeps every HTML attribute quote paired. Option text is decoded with
    `decodeLatin1`, so non-ASCII bytes in options would be misread; the fixture
    keeps options ASCII and confines its em dash to node content, which is
    decoded as UTF-8.

Order of work implied by the evidence: gap 1 unblocks the document, gap 2 makes
unsupported regions visible, gaps 3-5 make the diagram render as authored, gap 6
makes selection stable, gap 7 completes the operation set, and gaps 8-10 close
the correctness holes before any breadth claim is made.

## Deliberate exclusions

| Excluded construct | Why |
| --- | --- |
| `\begin{tikzpicture}` islands | The STR-007 refinement of 2026-07-28 13:49 superseded explicit picture islands; a slide body is one implicit canvas. |
| Literal `"""` inside any body | The trial spec states this is unsupported with no escaping convention. Including it would make the fixture unreadable rather than instructive. |
| `matrix`, `chains`, `pic`, `plot`, `pgfplots`, `decorations`, `patterns`, `\clip`, background layers | Each would enlarge the read-only surface without adding a new *editing* law. Four distinct unsupported kinds (style expansion, generation, transformation, computed placement) already cover capability 10. |
| A picture-wide `node distance=` default | It moves positional authority out of the node entirely, which is a separate design question from per-node relative placement. |
| `below right=of x`, `above left=of x`, legacy `below of=x` | The current relative detector misses these and would mark them writable, violating the read-only law. The fixture must not silently depend on that bug; gap 8 records it instead. |
| `anchor=base`, `anchor=text`, `anchor=mid`, two `anchor=` entries on one node | Currently fatal for the whole document. Keeping them out confines the fatal failure surface to one class (gap 1) so the designer can sequence work. |
| Duplicate node ids across the two slides | Per-slide namespacing is worth a targeted test, not a breadth demonstration; here it would only obscure which surface an object belongs to. |
| CRLF line endings, BOM, and a no-trailing-newline variant | Real concerns, but they belong to dedicated round-trip fixtures rather than the breadth fixture. This file is LF with a trailing newline, matching `demo.slide`. |
| Images, external assets, `\includegraphics` | Resource closure and asset loading are outside this slice. |
| Overlays, animation, `\only`, `\onslide` | Presenter and timeline behaviour are outside this slice. |
| Non-ASCII in titles or option lists | Option text is decoded with `decodeLatin1`; putting non-ASCII there would test an encoding bug rather than authoring breadth. One em dash sits in node content, which is UTF-8 decoded. |
| A third slide | Two slides keep navigation, New Slide, and notes exercisable while keeping the capability-to-line mapping auditable. |

## Limitations of this run

- The candidate is a **proposal**. It has not been reviewed, has not been
  promoted, and the designer may require changes before it becomes the slice
  fixture.
- Rendering, measurement, and browser behaviour were **not** exercised. Only the
  shared `slideblaster-deck` parser was run. Whether the mixed content at
  102-112, 114-120, and 208-219 can be measured and painted honestly is the
  designer's and verifier's question, and the README of this repository already
  records that the web measurement shim fails closed for structured content.
- The fixture has not been compiled by a real TeX toolchain, so its TikZ is
  idiomatic and self-consistent by inspection but not typeset-verified. If the
  slice needs a compiled oracle, that is a separate verification step.
- Method B used the existing `dist-newstyle` build cache through
  `cabal repl -v0`. No product source, manifest, or test file was written. The
  only filesystem writes attributable to this run are the two files in this
  directory, plus whatever transient cache `cabal repl` refreshed.
- `git status` before and after shows the same 39 pre-existing modified P0 files
  and the same untracked set apart from this run's directory. No git mutation
  was performed; `HEAD` remains `cbe29eb` on `session/SB2-20260727-001`.

## Conclusion

`candidate.slide` (6487 bytes, SHA-256
`6781123f2fc759aabc82872d775c0f05000d46e0facdd90073ceaec745895a5e`) is an
original, licence-clean, realistic two-slide architecture deck that exercises
all eleven P0.1 breadth capabilities, with twelve intended writable nodes and
seven distinct intended read-only regions.

The current implementation admits **none** of it: the compiled parser returns a
syntax-only document with zero slides and the diagnostic `deck.node_at`, caused
solely by the three ordinary relative-positioned nodes on slide 1. Removing
slide 1 yields a fully admitted single-slide document, which makes slide 2 a
usable green baseline and isolates the gap precisely. Beyond that blocker, the
evidence above documents nine further gaps, of which the two most consequential
for the product's honesty are the silent absorption of non-semicolon-terminated
constructs (which makes unsupported regions invisible instead of read-only) and
the silent dropping of every orthogonal connector.
