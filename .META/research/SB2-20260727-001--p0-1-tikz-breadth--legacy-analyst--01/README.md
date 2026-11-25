# Research artifact: p0-1-tikz-breadth (legacy oracle)

- Slug: `SB2-20260727-001--p0-1-tikz-breadth--legacy-analyst--01`
- Session: `SB2-20260727-001`
- Governing prompt: `slideBlaster2/.META/sessions/SB2-20260729-001/.prompt`
- Agent: `legacy-analyst`
- Created: `2026-07-29`
- Status: `complete`

## Question

What is the executable oracle for TikZ authoring breadth — parser, node/option model,
connector and arrow-tip model, anchors, relative positioning, node content rendering,
and the canvas-edit inverse — in the legacy TypeScript implementation and the accepted
design/knowledge trees; and which real TikZ fixtures already exist for P0.1?

## Source and provenance

Strictly read-only inspection. No file under `../editor`, `../design`, `../knowledge`,
or `../slideBlaster2` was modified; no git mutation, build, or network call was made.
This report is the only file written.

- Legacy worktree: `/home/t/Documents/slide/slideBlaster/editor` at
  `60dc20208f07c6e441c398fabac946d081b0594d` (`60dc202`, 2026-07-23,
  "feat(canvas): add verified multi-shape editing").
- Governed worktree: `/home/t/Documents/slide/slideBlaster/sb2-SB2-20260727-001`,
  branch `session/SB2-20260727-001`, registration baseline `cbe29eb`. `git status`
  showed 38 modified P0 files plus one untracked knowledge note; none were touched.

## Reproduction

Read the cited paths read-only. Legacy prose (`*.md` companion files) was not treated
as evidence for behaviour; every construct list below was read out of `.ts` code. The
coverage numbers in section 5 are assertions in a legacy test file and were read, not
executed (no build or test run was permitted in this task).

## 1. Legacy TikZ subsystem: exact paths and code-level construct lists

All paths relative to `../editor/packages/editor/src/` unless stated.

| Concern | File | Bytes |
| --- | --- | --- |
| Public surface | `tikz/index.ts` | 2031 |
| Structural TeX grammar (Parsimmon) | `tikz/full.ts` | 5923 |
| Lowering / macro / style / scope evaluation | `tikz/evaluate.ts` | 21590 |
| Statement parser | `tikz/parse.ts` | 6262 |
| Statement model | `model/tikz.ts` | 3742 |
| Node option semantics (derived views) | `tikz/options.ts` | 23243 |
| Editable connector grammar | `tikz/connector.ts` | 9517 |
| Arrow-tip token model | `tikz/arrows.ts` | 5997 |
| Render-only `to`/`edge` paths | `tikz/toPath.ts` | 18229 |
| Path primitives (rect/circle/grid/arc) | `tikz/geometryPath.ts` | 8330 |
| `node ... edge ...` chains (petri) | `tikz/nodeEdges.ts` | 2926 |
| `let ... in` paths | `tikz/pathLet.ts` | 4159 |
| Named/calc coordinate expressions | `tikz/coordinateExpression.ts` | 6837 |
| Dimensions/units, polar, transforms | `tikz/coordinates.ts` | 3441 |
| Snake decoration | `tikz/decorations.ts` | 2044 |
| `font=` semantics | `tikz/font.ts` | 2759 |
| xcolor names and `!` mixtures | `tikz/xcolor.ts` | 2178 |
| Canvas-edit inverse (source projection) | `tikz/sourceEdit.ts` | 14620 |
| Canonical serializer | `tikz/serialize.ts` | 1743 |
| Depth-aware tokenizer | `text/scanner.ts` | 4445 |
| Layout / placement / anchors | `layout/resolve.ts` | 21714 |
| Anchor resolution fold | `render/anchors.ts` | 3415 |
| Slide renderer (SVG + HTML layers) | `render/slide.ts` | 35074 |
| Node shape geometry | `render/shape.ts` | 8351 |
| Path-primitive SVG | `render/pathGeometry.ts` | 7091 |
| Node content model | `model/content.ts` | 5302 |
| Node content parser | `content/parse.ts` | 20764 |
| Node content HTML renderer | `render/html.ts` | 12356 |
| Pure edit operations | `edit/ops.ts` | 20702 |
| Typed edit transactions | `edit/transaction.ts` | 3582 |

### 1.1 Statement grammar (`tikz/parse.ts`)

Four statement kinds only. Anything that throws during statement parsing falls back to
`{ kind: 'verbatim', source }` — parsing never fails a document.

- `\node` — optional repeated `[...]` groups, optional `(name)`, optional
  `at (coordinate)`, terminal `{content}`; `PATH_ACTION = /^\\(filldraw|draw|fill|path)\b/`.
- `\coordinate` — repeated `[...]`, mandatory `(name)`, mandatory `at (...)`; recognises
  `name intersections=` to build a `namedIntersection` expression.
- `\draw` / `\fill` / `\filldraw` / `\path` — action plus one `[...]`; **the segment body
  is stored verbatim** (`PathStatement.body`) and is only parsed later by
  `connector.ts` / `toPath.ts` / `geometryPath.ts`.
- everything else — verbatim.

Statement identity for editing is `NodeStatement.name`. Provenance is
`TikzSourceOrigin { start, end, repeated? }`, set from `lowerTikzSource().origins`;
`repeated: true` marks one authored command that produced several semantic statements
(loops, `node ... edge ...` chains) and is a hard read-only marker.

### 1.2 Node option semantics — exact recognised keys (`tikz/options.ts`)

Options are stored as raw ordered string tokens; every structured view is *derived*, never
stored. `lastOption` implements pgfkeys last-wins.

Positioning and geometry:
- `isPlacementToken`: `/^(above|below|left|right)\b.*=.*\bof\b/`; `placement()` parses
  `<side>=<dist> of <ref>`, falling back to `node distance=<v>[ and <h>]`, then
  `DEFAULT_PLACEMENT_GAP = 0.5`.
- `on grid` — centre-to-centre instead of edge gap.
- `xshift=`, `yshift=` (`nodeShift`).
- `anchor=` restricted to `center, north, south, east, west, north east, north west,
  south east, south west`; positioning shorthands map `above→south`, `below→north`,
  `left→east`, `right→west`, `above left→south east`, `above right→south west`,
  `below left→north east`, `below right→north west`.
- `text width=`, `minimum height=`, `minimum size=`, `minimum width=`,
  `inner sep=`, `inner xsep=`, `inner ysep=`.
- `scale=`, `xscale=`, `yscale=`.
- `fit=(a)(b)(c)`, `circle through=(name)`, `name path=`.

Shape tokens (`SHAPE_TOKENS`, last match wins, `stencil=<id>` overrides all):
`ellipse`, `circle`, `diamond`, `isosceles triangle`, `triangle`, `trapezium`,
`parallelogram`, `regular polygon`, `cylinder`, `rounded rectangle`; plus
`regular polygon sides=` (default 5, clamped `>= 3`). Default shape `rectangle`.

Paint and stroke:
- `draw` (bare) or `draw=<color>` → `isDrawn`; `fill=<color>`; `text=<color>`;
  `color=<color>`.
- `LINE_WIDTHS` = `ultra thin, very thin, thin, semithick, thick, very thick, ultra thick`
  with pt table `0.1/0.2/0.4/0.6/0.8/1.2/1.6`; `line width=<pt>` overrides.
  `PT_TO_UNITS = 0.03 / 0.4`.
- `DASH_PATTERNS` = `dashed, densely dashed, loosely dashed, dotted, densely dotted,
  loosely dotted`, each with a fixed `stroke-dasharray`.
- `opacity=`, `fill opacity=`, `draw opacity=`.
- `rounded corners` (bare → `DEFAULT_ROUNDED_PT = 4`) or `rounded corners=<pt>`.
- `line cap=`, `line join=` (path options, in `render/pathGeometry.ts`).
- `on background layer` (paint order).

Typography (`tikz/font.ts`): the last `font=` declaration; named sizes
`tiny 5, scriptsize 7, footnotesize 8, small 9, normalsize 10, large 12, Large 14.4,
LARGE 17.28, huge 20.74, Huge 24.88`; plus `\fontsize{a}{b}`, `\fontfamily`,
`\fontencoding`, `\selectfont`, `\bfseries`, `\itshape`. Also a SlideBlaster-specific
`font size=<n>` key in `cqw`.

Other: `label=<pos>:<content>` with `label style=`, `overlay={spec}` (SlideBlaster
extension), `tokens=<n>` (petri, clamped 0..9), `stencil=<id>`.

`isStyleKnobToken` separates TikZ knobs from theme-role tokens: the knob set is
`draw, rectangle, rounded corners` plus all `SHAPE_TOKENS`, `LINE_WIDTHS`, and
`DASH_PATTERNS`. Every other bare identifier is treated as a *theme role class*.

### 1.3 Anchors

`layout/resolve.ts` defines the complete list, and it is the same nine names used by
`anchor=`:

```
center north south east west "north east" "north west" "south east" "south west"
```

`anchor(node, name)` returns the half-width/half-height corner point of the measured box.
`render/anchors.ts:clipImplicitNodeAnchor` implements TikZ's direction-sensitive
unqualified `(node)`: an ellipse clips by `1/sqrt(dx²/rx² + dy²/ry²)`, everything else by
`1/max(|dx|/rx, |dy|/ry)`. An explicit `(node.center)` or compass anchor is never clipped.

### 1.4 Coordinates, units, relative positioning provenance

`tikz/coordinates.ts` `UNIT_SCALE`: `'' → 1, cm → 1, mm → 0.1, pt → 2.54/72.27,
bp → 2.54/72, in → 2.54, em → (10*2.54)/72.27, ex → (4.3054*2.54)/72.27`. A **bare
number is therefore centimetres**, and one slide unit equals one centimetre. Cartesian
and polar (`30:1cm`) forms are both parsed.

`CoordinateExpression` (in `model/tikz.ts`) carries a `source` string for every case, and
this `source` is what the inverse writes back verbatim:
`reference`, `shift` (`[xshift=,yshift=]name`), `orthogonal` (`|-`, `-|`),
`partway` (`($(a)!f!(b)$)`), `jitter` (`rand`, hashed deterministically),
`projection` (`!dist!angle:`), `lineIntersection`, `namedIntersection`.

Relative *placement* provenance is the `placementToken`; relative *coordinate* provenance
is `AnchorRelative { delta, updates }` for `+`/`++`, resolved by the stateful fold in
`render/anchors.ts:resolveAnchors` (a `++` advances the running current point, a `+` does
not).

### 1.5 Connectors (`tikz/connector.ts`) — the editable subset

`ConnectorPath { anchors: Anchor[], segments: Segment[], closed?: boolean }`.

- Anchors: `(name)`, `(name.anchor)`, `(x,y)`, `+(dx,dy)`, `++(dx,dy)` (Cartesian delta
  only — `+(name)` and polar `+(30:1)` are rejected), and a `CoordinateExpression` when it
  is not a bare reference.
- Segments: `null` = straight `--`; `OrthoSegment { corner: 'hv' | 'vh' }` for `-|` / `|-`;
  `CurveControls { c1, c2 }` for `.. controls (c1) and (c2) ..`; terminal `cycle` sets
  `closed`.
- **Orthogonal elbows are never stored.** `-|` turns at the next anchor's x on this
  anchor's y; `|-` the reverse; the corner is derived at paint from the two resolved
  endpoints, so it re-routes free of charge when a node moves.
- Any token outside this grammar returns `null`; the body then stays verbatim.

Fallback ladder in `render/slide.ts:connectorsOf`: `parseConnector` →
`parseToPath` (render-only `to`/`edge`/`bend`/`loop`/`node {…}` labels) →
`connectorPoints` (naive `(name)`/`(x,y)` split on `--|-\||\|-`, straight polyline).
Only the first rung yields `editable !== null`.

### 1.6 Arrow tips (`tikz/arrows.ts`)

`Tip = none | to | latex | stealth | bar | circle | square | diamond`.
`TIP_NAMES` maps, case-insensitively, `to, latex, stealth, bar, circle, o, square,
diamond`. An unknown tip name falls back to `to`.

`isArrowToken` accepts tip pieces around a top-level `-` with no top-level `=`, where a
piece is `[<>|]`, `{Name}`, or a bare `[A-Za-z][\w ]*`. `>=<tip>` and `<=<tip>` set what
the `>`/`<` glyphs mean. `formatArrowToken` writes `<`/`>` for `to`, `|` for `bar`, and
`{Latex}`/`{Stealth}`/`{Circle}`/`{Square}`/`{Diamond}` otherwise. `setArrowSpec` drops the
old arrow token plus `>=`/`<=` keys and prepends the new token; `{none,none}` removes it.

Explicitly out of scope in code: arrows.meta per-tip options (`[length=,width=,round]`),
scaling, `reversed`, doubled `>>`, cap types, per-tip colour, and per-end tip kinds in the
panel.

## 2. How legacy renders node content, connectors, and arrow tips

### 2.1 Node content

`model/content.ts` is a **tri-dialect surface-faithful** model: each run stores the exact
form it was written in, so provenance is implicit in the run kind. `NodeContent` is
`empty | text{runs} | error{source, message}`. Run kinds: `text, linebreak, math,
latex, markdown, html, list, columns, matrix, fragment, overlay, image, include,
deferred, cite, citefootnote, printbibliography, vskip, color`.

`content/parse.ts` is recursive-descent with fixed precedence (markdown lists → math →
HTML → LaTeX macros/fragments → markdown emphasis → literal text). Allowed LaTeX inline
commands: `textbf, emph, textit, underline, hl`. Allowed HTML tags: `b, strong, i, em, u,
s, mark, div, span`. Anything else with a `{}` argument, any unlisted tag, or a malformed
overlay spec raises `OutOfSubsetError`, and the **whole body** becomes
`{ kind: 'error', source, message }` — preserved verbatim, rendered as
`<span class="sb-error">`.

`render/html.ts` maps each run to its semantic element, so `\textbf{x}`, `**x**` and
`<b>x</b>` all render `<strong>x</strong>`. Math is a seam: `renderMath(source, display)`,
defaulting to `<span class="sb-math" data-mode="…">source</span>` — **KaTeX is injected by
the app, not by the engine**. Tables (`tabular`) are `deferred` and require the Compile
port; absent it they render `"table — render pending"`. `\cat{…}` becomes `include` and
renders its path. Citations and the bibliography are the same seam pattern.

Node boxes are HTML `<div class="sb-node">` absolutely positioned by percentage over an
SVG `viewBox="0 0 W 9"` geometry layer (`render/slide.ts:nodeDiv`), with inline styles for
`min-height`, `transform: scale`, `opacity`, `font-size` (cqw), `line-height`,
`font-family`, `font-weight`, `font-style`, `color`, and padding. The two layers register
by construction because both use the same slide-unit box. Node identity is stamped as
`data-node="<name>"` and `data-layout-index`.

Box **sizes** come from an injected measurer (`layout/measure.ts`: `naiveMeasurer` for
headless, `app/domMeasurer.ts` for the browser), never from constants.

### 2.2 Connectors and arrow tips

`connectorsOf` resolves anchors, applies `clipImplicitNodeAnchor`, and emits
`<path class="sb-arrow" data-arrow="<index>" d="…">` on the SVG geometry layer. Connector
identity for editing is the **index among path statements**, which is what `data-arrow`
carries and what `deleteConnector` / `updateConnector` / `setConnectorOptions` target.

Paint is compiled by `render/pathGeometry.ts:pathPaintStyle`. A bare `\path` stays
invisible unless it carries `draw`, `draw=`, or the `edge` operation. A path decorated
with `decorate, decoration={snake,…}` is re-emitted as a polyline approximation.

Arrow tips are SVG `<marker>` elements in a `0..6` box, `markerWidth/Height=6`, `refY=3`,
`orient="auto"` for the end and `orient="auto-start-reverse"` for the start, with per-tip
`refX` (`to 5, latex 5.5, stealth 5.5, bar 4.6, circle 3, square 3, diamond 3`). `to` and
`bar` are stroked with `context-stroke`; `latex`, `stealth`, `diamond` are filled paths;
`circle`/`square` are shapes. `markerDefs` emits `<defs>` for **only the tips the slide
actually uses**, sorted for stable output, and emits nothing when no connector has a head.

## 3. Editable vs read-only, and how an edit is written back

### 3.1 The decision is made at projection time, not gesture time

`edit/ops.ts` transforms are total and permissive: `moveNodeTo` will happily convert *any*
uniquely named node to absolute, stripping `isPlacementToken` options and neutralising
`anchor=`/`xshift`/`yshift` with explicit `anchor=center`, `xshift=0`, `yshift=0`
overrides. The canvas gate in `app/canvas.ts` is only `data-node` presence — i.e. *named*,
not *writable*.

Read-only is enforced afterwards, in `tikz/sourceEdit.ts`. `projectNodeEdit` returns
`null` (unsupported) unless **all** of:

1. `oldStatement.name !== undefined` and unchanged;
2. `oldStatement.origin` exists;
3. `origin.repeated !== true`;
4. the authored fragment reparses with the strict `authoredNode` Parsimmon production
   (`\node`, optional leading `[...]`, optional `(name)`, trailing `[...]` groups, optional
   `at (...)`, `{…}`, `;`, EOF);
5. the recovered `(name)` is a valid identifier and equals the model name.

`projectPathEdit` requires matching action, present non-repeated origin, and a successful
`authoredPath` parse. `projectDeletion` requires every removed statement to have a
non-repeated origin. Anything else is `null`.

**Consequence to carry forward:** legacy lets the user start a drag on an unwritable node
and then fails the commit with a status message. The new repo's accepted note
`.META/knowledge/source-authoritative-product-v2-canvas.md` requires the opposite —
read-only forms "receive no drag interaction projection". Do not port the legacy ordering.

### 3.2 The write-back mechanism

`projectTikzPictureEdit(source, before, after)`:

- more statements → `projectInsertion`: exactly one new statement, appended at
  `findPicture(parseTex(source)).bodySpan.end` with newline hygiene, serialized canonically.
- fewer statements → `projectDeletion`: blank out each removed origin span.
- equal → per-index diff, sorted **descending by `origin.start`** so earlier offsets stay
  valid while one gesture patches several statements.

`projectNodeEdit` builds field-grained `Replacement { start, end, value }` records against
the authored fragment:

- content: replaces only the inside of the `{…}` group when `serializeBody` differs;
- position: replaces only the coordinate group inside `at (...)`; removes the whole `at`
  clause when the new point is absent; inserts `" at (…) "` before the content group when
  there was no `at`;
- options: `projectedOptionTokens` computes a key-level delta (`optionKey` = text before the
  first `=`), rewrites a changed key **in the option group where it last appeared**, drops
  removed keys, appends genuinely new keys to the first group, and synthesises a new
  `[...]` right after `\node` when the node had no option group.

`apply` then splices replacements from the end of the string backwards.

`projectTikzEditTransaction(source, transaction)` is the verified wrapper and the exact
oracle for the new repo's laws:

1. reparse the authoritative source, compare with `transaction.before` via
   `sameTikzSemantics` → `conflict` on mismatch (stale-source rejection);
2. project → `unsupported` on `null`;
3. reparse the projected candidate and compare with `transaction.after` →
   `verification-failed` on mismatch;
4. only then `{ status: 'applied', source }`.

`sameTikzSemantics` (`edit/transaction.ts`) strips `origin` and canonicalises JSON key
order, so provenance is explicitly syntax metadata and not semantics.

### 3.3 The other legacy path is canonicalizing — do not port it

`text/scanner.ts:splitStatements` **discards inter-statement whitespace**, and
`evaluate.ts:sourceOfNode` returns `''` for comments. `tikz/serialize.ts:serializePicture`
emits one canonical statement per line. So `parsePicture → serializePicture` is *not*
byte-preserving; only the span-splice path in `sourceEdit.ts` is.

`app/createApp.ts:serializeSource` still takes the canonicalizing route when the figure
body has no `\begin{tikzpicture}`:

```ts
if (!authored.includes('\\begin{tikzpicture}')) {
  return { status: 'applied',
           source: writeFigureDirective(codec.serialize(doc), readFigureDirective(state.source)) }
}
```

This directly violates the new repo's law "Ordinary edits never canonicalize the whole
document" (`AGENTS.md` source-editing invariant 8; prompt "Non-negotiable source and
architecture laws"). The legacy knowledge note `knowledge/concepts/tikz-figure-file.md`
states the behaviour as intended: "`serializePicture` canonicalizes, so a hand-authored
`.tikz` normalizes on first edit." **State this as a conflict; do not reconcile it.** The
oracle for P0.1 is `projectTikzEditTransaction`, not `serializeSource`.

## 4. Accepted contracts found (with status, exactly as written)

Legacy `../design/`:

| File | Status header | Relevance |
| --- | --- | --- |
| `design/format/tikz-subset.md` | **"Status: draft — the per-tier construct lists are a v1 proposal, not final."** | The T0/T1/T2/Out tier table; span-preserving parse + splice mechanism; requirements SB-V004, SB-V005, SB-V011. **Draft, not accepted.** |
| `design/decisions/0003-tikz-native-drawing.md` | accepted, 2026-07-04 | Own renderer; TikZ is the native drawing surface; all arrows are TikZ. |
| `design/decisions/0004-slide-is-a-tikz-picture.md` | accepted, 2026-07-04 | A slide body is one TikZ picture; supersedes 0002. |
| `design/decisions/0015-out-of-subset-is-a-hard-error.md` | accepted | No TeX fallback; source preserved, node enters error state. |
| `design/decisions/0016-incremental-per-construct-editing.md` | accepted | Per-construct promotion, not whole-figure opacity. |
| `design/decisions/0006-positioning-and-snapping.md` | accepted | Relative positioning is first-class and the snapping target. |
| `design/decisions/0007-node-content-tri-dialect.md` | accepted | Node content is not a TikZ picture. |
| `design/decisions/0014-layered-dom-render-surface.md` | accepted | SVG geometry under HTML content. |
| `design/decisions/0017-theme-style-layout-furniture.md` | accepted | Node distance default, aspect ratio, class < node precedence. |
| `design/decisions/0021-tikz-figure-files.md` | accepted, 2026-07-07 | `.tikz` is a standalone picture body. |
| `design/decisions/0023-opt-in-compiled-figure-view-only.md` | accepted | Compiled mode is an explicit view-only escape hatch. |
| `design/format/shapes-inventory.md`, `design/format/node-content.md`, `design/ux/font-size.md`, `design/ux/positioning-snapping.md`, `design/ux/tikz-files.md` | — | Shape list, content grammar, font-size precedence, snapping UX, figure UX. |

Legacy `../knowledge/concepts/` (all `status: current`):

- `editable-connector-subset.md` — the T1 connector contract: anchors + typed segments,
  "cubic control points are absolute and stored; orthogonal corners are never stored",
  stateful `+`/`++` fold, `to[bend]` and polar relative explicitly out.
- `arrow-tip-rendering.md` — the curated seven-tip set, one owning token, `<marker>`
  rendering, explicit arrows.meta exclusions.
- `to-path-render-only.md` — `to`/`edge` is render-only, never canvas-edited.
- `bidirectional-tikz-edit-transaction.md` — one semantic IR, typed intent, preview by the
  ordinary layout solver, commit by projection + reparse + semantic equality; "Unsupported,
  stale, ambiguous, or unverifiable projections do not alter source or history."
- `native-tikz-interpreter.md` — structural TeX AST first, TikZ meaning in explicit
  evaluator passes; "parsing a token alone does not make the construct supported".
- `out-of-subset-hard-error.md` — hard surfaced error, no WASM-TeX fallback; T2 constructs
  are supported-but-not-editable, which is a different thing.
- `shapes-as-option-presets.md` — a shape is a preset of node option tokens, not a model
  concept; `isStyleKnobToken` keeps role and knob apart; size lever is
  `minimum width`/`minimum height`, not `text width`.
- `theme-anchor-points.md` — theme anchors are editor-only snap targets and never position.
- `tri-dialect-node-content.md`, `per-node-font-size.md`, `overlays.md`,
  `layered-dom-render-surface.md`, `source-to-dom-validation-boundary.md`,
  `showcase-landing-benchmark.md`, `tikz-figure-file.md`, `compiled-figure-view-only.md`.

Governed worktree `.META/` and `docs/`:

- `.META/design/README.md` and `.META/knowledge/README.md` — legacy trees are **not yet
  migrated**; both must be searched and neither may be treated as superseded.
- `.META/knowledge/source-authoritative-product-v2-canvas.md` (`status: current`,
  2026-07-28) — the current accepted canvas contract: recognized anchors such as
  `north west` are writable; "relative, expanded, unknown, or ambiguous placement forms
  remain read-only and receive no drag interaction projection"; only the two coordinate
  lexemes are replaced; `FreeDrag` retry; "broader TikZ, structured text/font measurement,
  notes editing, and general authoring remain deferred".
- `.META/knowledge/provisional-str-007-implicit-canvas-deck.md` — the P0 subset is
  explicitly provisional; complex TikZ paths and unsupported placements are read-only.
- `docs/specs/slice1-tikz-subset.md` — **`status: proposed`**, one node + one straight
  connector, no options at all; laws SB2-S1-001..007 (exact identity, recovery, direct
  authorship, verified move, token locality, atomic failure, no-op without
  canonicalization).
- `docs/specs/str-007-implicit-canvas-slide-trial.md` — the P0 baseline: repeated
  direct-position nodes and simple node-to-node `--` paths admitted; everything else
  retained exactly and read-only/syntax-only.

**No accepted (as opposed to draft/proposed/provisional) contract exists in either tree for
the P0.1 breadth targets** — node option semantics beyond `anchor`/`text width`, shapes,
arrow tips, orthogonal connectors, or relative-positioning provenance. `tikz-subset.md` is
draft; `slice1-tikz-subset.md` is proposed. The legacy `knowledge/concepts/*` notes are
`status: current` but describe the legacy implementation, and the legacy trees are
explicitly unmigrated. This is a user-gated decision surface, not a delegated one.

Additional conflicts to surface rather than reconcile:

1. **Canonicalization** (section 3.3) — legacy normalizes hand-authored figures on first
   edit; the new law forbids it.
2. **Drag-then-fail vs no-projection** (section 3.1).
3. **Non-standard TikZ in the legacy examples** — `examples/*.tikz` use `fill=#dbeafe`
   (hex literals, not xcolor) and unitless `minimum width=3` read as centimetres. These are
   SlideBlaster dialect, not portable TikZ, and are unsuitable as a "real-world" fixture.
4. **`overlay=`/`font size=` are SlideBlaster keys**, not TikZ; `overlay` in real TikZ is a
   bounding-box option. Promoting them into a "TikZ breadth" claim would be dishonest.
5. **Companion-`.md`-per-source-file** is the legacy documentation convention; the new
   `AGENTS.md` forbids it for `.hs` (explicit export lists plus module Haddock instead).

## 5. Real TikZ fixtures already present in the legacy tree

Base: `../editor/packages/app/src/`.

| Path | Bytes | Lines | MD5 | Features exercised |
| --- | --- | --- | --- | --- |
| `showcase/p4checkarch.tikz` | 9104 | 236 | `c3db57d59170df31c9d64fdd080f4642` | Author's own SIGCOMM-style architecture diagram: 20+ named nodes, `/.style` definitions incl. style inheritance, `>=Latex`, `-{Latex[length=2mm]}`, `shorten >=/<=`, `anchor=north/west/east`, `text width`, `inner xsep/ysep`, `minimum width/height`, `align=center`, `ellipse`, `fill=gray!7`/`black!70` mixtures, `\def` macros as dimensions, `([xshift=,yshift=]name.anchor)`, `($(a)!0.5!(b)$)`, `(a.center |- b.center)`, `-\|`/`\|-` elbows, `++(dx,dy)`, `scope[on background layer]`, `let \p1=… in`, `\pgfresetboundingbox`, `use as bounding box`, `\ding{51}`, per-node `font=` with `\fontsize`. |
| `showcase/petri-net.tikz` | 3990 | 90 | `2d381bbe9d4a0bcd4279f670c0321702` | PGF manual "A Petri-Net for Hagen", verbatim. `node distance=1.3cm`, `>={Stealth[round]}`, `bend angle`, `auto`, `on grid`, `/.style` with inheritance, `circle`/`rectangle`, `minimum size=6mm`, `tokens=`, `label=above:$…$`, `every label/.style`, **`[below=of x]` relative positioning throughout**, `node … edge [pre/post,bend left] (t)` chains, `node[swap] {2}` hop labels, two `scope`s with `xshift=6cm`, `fit=(a)(b)…` with `rounded corners` on the background layer, `decorate, decoration={snake,…}` with `shorten >=`, `\textcolor`, `text width`/`align=center` on a midway label, primed identifiers (`w1'`). |
| `showcase/euclid-proposition-2.tikz` | 3498 | 76 | `a35df4b608f04ad978559d37794f9352` | PGF manual "Euclid's Elements", verbatim. Heavy `calc`: `($ (0,0) + .1*(rand,rand) $)`, `($ (A)!.5!(B) ! {sin(60)*2} ! 90:(B) $)`, `($ (D)!3.75!(A) $)`; `intersections` library (`name path=`, `name intersections={of=H and B--F}`, `(intersection-1)`); `through` library (`circle through=(C)`); `\colorlet`; `\def` content macros; `label=left:` / `label=-135:`; `help lines/.style`; `\pgfmathsetseed`; `backgrounds`. |
| `showcase/karls-unit-circle.tikz` | 2797 | 77 | `0a1e8575f5d1dd2a3165de66c0ee1e4e` | PGF manual "A Picture for Karl's Students", verbatim. `scale=3`, `line cap=round`, `/.style` incl. an empty style, `\def`, `\colorlet` aliases, `help lines, step=0.5cm` `grid`, `circle [radius=1cm]`, `arc(0:30:3mm)`, polar `(30:1cm)` / `(15:2mm)`, two `\foreach` loops with `\x/\xtext` patterns and `xshift=\x cm`, `intersection of a--b and c--d`, `coordinate (t)`, `node[left=1pt,fill=white]` path labels, `text width=6cm` with display math, `information text/.style={rounded corners,fill=red!10,inner sep=1ex}`, nested `{\color{…}…}` in text and math. |
| `examples/flowchart.tikz` | 866 | 14 | `b2a423bfe0265a61fd14f3bc204676d8` | SlideBlaster dialect. 9 named nodes, `draw`, `diamond`, `rounded corners=10pt`, `minimum width/height`, hex `fill=#dbeafe`, five `\draw[->] (a) -- (b)` connectors. Unitless dimensions. |
| `examples/pipeline.tikz` | 695 | 9 | `a6c340cfd370a5e12bca830afa752506` | SlideBlaster dialect. 5 named nodes in a row, three `->` connectors, one `text width=13` caption with inline math. |
| `examples/shapes.tikz` | 916 | 9 | `6765afd44af78276e25ee49dcc02ad26` | SlideBlaster dialect shape tour: `rectangle, ellipse, diamond, circle, regular polygon (sides=6), cylinder, trapezium, rounded corners`. No connectors. |

Licensing and provenance: the three PGF-manual fixtures each carry a two-to-four-line
comment header naming the exact upstream file
(`doc/generic/pgf/pgfmanual-en-tutorial-nodes.tex`, `pgfmanual-en-tutorial.tex`,
`pgfmanual-en-tutorial-Euclid.tex`), the authors (Till Tantau et al.), the licence
("LPPL 1.3c / GNU FDL 1.2 / GPLv2 (PGF is triple-licensed)"), and the libraries used.
`p4checkarch.tikz` is described in `knowledge/concepts/showcase-landing-benchmark.md` as
"author-provided" and "the flagship native benchmark"; it carries no licence header, so its
usability rests on the product owner being the author. Upstream PGF manual sources are also
present read-only under `../sources/tikz/manual-src/` (including
`pgfmanual-en-tutorial-map.tex`, 61358 bytes) if a different excerpt is preferred.

Related fixtures: `../editor/packages/editor/src/invariants/fixtures/intro.slideBlaster.md`
(230 bytes) is a minimal deck using `[title]`, `[body, below=0.7 of title, text width=12]`,
a markdown list, inline math, and one `->` connector. The governed worktree already contains
a sibling candidate at
`.META/research/SB2-20260727-001--p0-1-tikz-breadth--fixture-analyst--01/candidate.slide`
(6487 bytes); reconciling the two is the fixture analyst's and orchestrator's call, not
mine.

### Legacy's own executable coverage claims

`../editor/packages/app/src/showcase/nativeTikzCoverage.test.ts` (read, **not executed**)
is the closest thing to an executable oracle for breadth. It asserts:

- all four showcase figures parse through the structural grammar;
- lowering leaves no `\begin{tikzpicture}` and yields `statements === modeled` with **zero
  diagnostics**: `p4 64/64`, `karl 19/19`, `petri 50/50`, `euclid 24/24`;
- no node lands in the content `error` state;
- constructed intersections resolve numerically (Karl's `t`; Euclid's
  `|BG| == |BC|`, `|DL| == |DG|`, `|AL| == |BC|`);
- Petri renders exactly 7 tokens, a snake with >20 segments, a `stealth` head, a cubic
  `C`, and three red label divs; the two nets are 6 units apart and `below=of` gaps
  resolve to 1.3;
- P4's `let … in` produces exactly 4 `__sb_let_*` helper coordinates and paints the band on
  the background layer;
- Euclid's `name path=` paths are semantic but `stroke:none`;
- every figure renders with `<svg class="sb-geometry">`, `<div class="sb-content">`, no
  `sb-error`, no leaked `tikzpicture`;
- **`projectTikzEditTransaction(p4, moveNode)` returns `applied`, and every one of the
  15+ authored named P4 nodes can be moved by visual centre and verified round-trip
  through authored source.**

That last assertion is the single most useful oracle for P0.1: it is legacy's proof that a
real-world diagram with styles, scopes, macros, `let … in`, calc, and anchored boxes is
canvas-writable through span-local projection without flattening the authored program.

## Limitations

- Nothing was built or executed. Every coverage number in section 5 is a source-level
  assertion in a legacy test file, not an observed pass. The verifier must re-derive its own
  evidence against the Haskell implementation.
- I did not read `render/shape.ts`, `layout/measure.ts`, `theme/*`, or the
  `app/connectorEditor`/`resizeHandles` interaction code in full; the connector-handle and
  resize UX oracle is therefore only partially characterised here.
- `stencils.generated.ts` (2014272 bytes) was not inspected. Stencils are out of P0.1 scope.
- `tikz/evaluate.ts` was read only through its first 200 lines plus its exported surface;
  the complete `\foreach`, scope-transform, and `\colorlet` lowering rules are not
  exhaustively transcribed.
- I made no judgement on which fixture P0.1 should adopt, and no judgement on whether any
  legacy construct should be admitted to the new writable subset. Both are user-gated.

## Conclusion

The executable oracle for P0.1 is a narrow, well-identified slice of legacy, not the whole
editor:

1. **`tikz/sourceEdit.ts:projectTikzEditTransaction`** — the conflict → project →
   reparse → semantic-equality → apply ladder, with field-grained replacements and
   descending-offset splicing. This satisfies the new repo's laws and should be the
   behavioural model.
2. **`tikz/connector.ts`** — anchors + typed segments, with the invariant that orthogonal
   elbows are derived and never stored. This is what makes "connector geometry updates when
   an attached node moves" free rather than a synchronisation problem.
3. **`tikz/arrows.ts`** — one owning token, a curated seven-tip set, honest exclusions.
4. **`tikz/options.ts`** — options stay raw ordered tokens; every semantic view is derived.
   This is the pattern that keeps option spelling and order byte-stable.
5. **`showcase/p4checkarch.tikz` plus `nativeTikzCoverage.test.ts`** — a real 236-line
   diagram and the assertions that make it an acceptance target rather than a demo.

Three things must **not** be ported: the canonicalizing `serializeSource` fallback, the
drag-then-fail ordering for unwritable nodes, and the SlideBlaster-dialect
`examples/*.tikz` (hex colours, unitless dimensions) as a "real-world TikZ" fixture.

The decisive governance finding is that **no accepted contract defines the P0.1 supported
subset**. `design/format/tikz-subset.md` is draft, `docs/specs/slice1-tikz-subset.md` is
proposed, `str-007` is provisional, and the legacy knowledge notes describe an
implementation in an unmigrated tree. Choosing the P0.1 writable option set, shape set,
anchor set, arrow-tip set, and relative-positioning writability rule is a user decision
under `AGENTS.md` "changing the meaning of T0/T1/T2/unsupported constructs", and the
orchestrator should put it to the product owner as a decision brief before implementation
begins.
