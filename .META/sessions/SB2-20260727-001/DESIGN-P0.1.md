# SB2-20260727-001 P0.1 design: core TikZ authoring breadth

Node 3 (designer). Worktree `/home/t/Documents/slide/slideBlaster/sb2-SB2-20260727-001`,
branch `session/SB2-20260727-001`, registration baseline `cbe29eb`. Governing
prompt `.META/sessions/SB2-20260729-001/.prompt`; steering STR-009.

This document is the implementation contract for two lanes. It resolves every
question an implementer needs answered and states every deliberate exclusion.
Where breadth and honesty conflict it chooses honesty.

Citation convention, used on every entry in section 1:

- `[L …]` — grounded in the **legacy feature surface** at
  `/home/t/Documents/slide/slideBlaster/editor` (commit `60dc202`), read-only.
  The legacy tree is the authority for *which* features exist, never for *how*
  to implement them.
- `[R …]` — grounded in an **accepted contract of this repository**.
- `[D…]` — an orchestrator-resolved decision in the governing prompt.

Two legacy behaviours are deliberately **not** ported, per binding steering:
its canonicalizing serializer path (`text/scanner.ts:splitStatements`,
`tikz/serialize.ts`, `app/createApp.ts:serializeSource`), and its ordering in
which a drag is permitted on an unwritable node and rejected only at projection
time. In this repository a read-only form receives no drag interaction
projection at all.

---

## 1. Supported TikZ subset for P0.1

The subset below is what P0.1 **interprets**. Everything else in an audience
body is retained byte-exact and becomes a visible read-only region record
(section 8). Nothing is silently dropped.

### 1.1 Accepted statement forms

| Form | Semantics | Grounding |
| --- | --- | --- |
| `\node [opts]? (IDENT) at (COORD , COORD) { body } ;` | One admitted node with a direct literal coordinate. | `[R packages/slideblaster-deck/src/SlideBlaster/Deck.hs:parseNode]`, `[R docs/specs/str-007-implicit-canvas-slide-trial.md]` |
| `\node [opts] (IDENT) { body } ;` where `opts` contains a relative placement item | One admitted node with a resolved, read-only relative placement. **New in P0.1**: a missing `at (...)` is no longer a parse failure. | `[L tikz/options.ts:isPlacementToken, placement]`, `[D3]` |
| `\tikzset{ NAME/.style={ items } , … }` | One or more entries in the per-body style table. The region itself is read-only source. | `[L tikz/evaluate.ts]` style/macro evaluation; petri fixture lowers with zero diagnostics per `[L showcase/nativeTikzCoverage.test.ts]`; `[D5]` |
| `\draw [opts]? <endpoint> ( <segment> <endpoint> )+ ;` | One admitted connector per adjacent endpoint pair. | `[R Deck.hs:parseConnectors]` (straight only today), `[L tikz/connector.ts]` for the segment/anchor grammar |

`\coordinate`, `\fill`, `\filldraw`, `\path`, `\foreach`,
`\begin{scope}…\end{scope}`, `\def`, `\colorlet`, `\pgfmathsetseed`,
`\begin{tikzpicture}` and every other command are **not interpreted**. They are
bounded by the statement-boundary rule in 1.7, preserved exactly, and recorded.

`IDENT` is `[A-Za-z_][A-Za-z0-9_-]*` `[R packages/slideblaster-canvas/src/SlideBlaster/Canvas/Identifier.hs]`.

`COORD` is a signed decimal or a `p/q` rational `[R Deck.hs:coordinateAt, parseRationalBytes]`.
A **unit-bearing** or polar `at` coordinate (`at (1cm,2)`, `at (30:1cm)`) is
deliberately *not* admitted in P0.1: it becomes a read-only computed placement
(`computed_coordinate`). Reason: the move inverse must write back into the
authored unit, and `pt`/`bp`/`em`/`ex` conversions are not terminating decimals,
so admitting them would create a writable slot whose inverse can fail. Length
*options* do accept units (1.3) because their inverse is separately gated.

### 1.2 Accepted node option keys

Options are read as an ordered list of top-level items
(`[R Deck.hs:topLevelOptionItems]`, extended to return each item's exact span).
Last item wins per key `[L tikz/options.ts:lastOption]`. Every accepted key
below is *interpreted*; every other item is retained exactly and recorded as a
`option_key_unsupported` or `option_value_unsupported` rendering limitation
against that node, **without** removing coordinate writability `[D2]`.

Placement:

| Item | Semantics | Grounding |
| --- | --- | --- |
| `anchor=<compass>` | The authored placement port. Accepted values `center`, `centre`, `north`, `north east`, `east`, `south east`, `south`, `south west`, `west`, `north west`. Zero `anchor=` items means `center`. Two `anchor=` items on one node makes the whole document syntax-only. | `[R Deck.hs:optionPort]`, `[L layout/resolve.ts]` nine anchors |
| `<side>=<dist> of <ref>` | Relative placement, resolved for geometry, read-only for editing. `<side>` ∈ `above`, `below`, `left`, `right`, `above left`, `above right`, `below left`, `below right`. `<dist>` is a length (1.3); when absent the gap is `node distance` from the body style table, else `1/2` slide units. | `[L tikz/options.ts:isPlacementToken` = `/^(above\|below\|left\|right)\b.*=.*\bof\b/`, `placement`, `DEFAULT_PLACEMENT_GAP = 0.5]`, `[D3]` |
| `node distance=<len>` inside `\tikzset` | Default relative gap for the body. | `[L tikz/options.ts:placement]` fallback |

`on grid`, `xshift=`, `yshift=`, `fit=`, `circle through=`, `name path=`,
`label=`, `label style=`, `overlay=`, `tokens=`, `stencil=`, `scale=`,
`xscale=`, `yscale=`, `rotate=` are **excluded** (recorded, not honoured).

Geometry and sizing:

| Item | Semantics | Grounding |
| --- | --- | --- |
| `text width=<len>` | The content wraps to exactly `<len>`; the node's box width is `<len>` plus twice the horizontal inner separation. | `[L tikz/options.ts:textWidth]`, `[L layout/measure.ts:MeasureInput.textWidth]` |
| `minimum width=<len>` | Grow-only floor on total box width. | `[L tikz/options.ts:minWidth]` |
| `minimum height=<len>` | Grow-only floor on total box height. | `[L tikz/options.ts:minHeight]` |
| `minimum size=<len>` | Grow-only floor on **both** axes. | `[L tikz/options.ts:minWidth, minHeight]` both accept `minimum\s+(?:width\|height\|size)` |
| `inner sep=<len>` | Both inner separations. | `[L tikz/options.ts:innerPadding]` |
| `inner xsep=<len>` | Horizontal inner separation. | `[L tikz/options.ts:innerPadding]` |
| `inner ysep=<len>` | Vertical inner separation. | `[L tikz/options.ts:innerPadding]` |

Default inner separation is `1/5` slide units on both axes, grounded on
`[L layout/measure.ts:PADDING = 0.2]`.

Shape (bare tokens, last match wins) `[L tikz/options.ts:SHAPE_TOKENS, nodeShape]`:

| Token | P0.1 outline | Grounding |
| --- | --- | --- |
| absent, or `rectangle` | `Canvas.PrimitiveGeometry Canvas.RectangleOutline` | `[L nodeShape]` default `rectangle` |
| `rounded corners` / `rounded corners=<len>` | `Canvas.RoundedRectangleOutline r`, bare token uses `4pt` | `[L tikz/options.ts:DEFAULT_ROUNDED_PT = 4, cornerRadiusPt]` |
| `circle`, `ellipse` | `Canvas.EllipseOutline` | `[L SHAPE_TOKENS]` maps both to `ellipse` |
| `diamond` | `Canvas.PolygonOutline` with the four box mid-edge points | `[L SHAPE_TOKENS]` |
| `triangle`, `isosceles triangle` | `Canvas.PolygonOutline` with apex north and the two south corners | `[L SHAPE_TOKENS]` |

`trapezium`, `parallelogram`, `regular polygon`, `regular polygon sides=`,
`cylinder`, `rounded rectangle`, `stencil=` are **excluded**: the node paints
its rectangle box and carries a `shape_unsupported` limitation naming the token.
Reason: their exact legacy geometry lives in `render/shape.ts`, which was not
transcribed by the analyst, so honouring them would be invention.

Paint and stroke:

| Item | Semantics | Grounding |
| --- | --- | --- |
| `draw` (bare) | Stroke the outline with the current stroke colour. A node **without** `draw` gets no stroke. | `[L tikz/options.ts:isDrawn]` |
| `draw=<colour>` | Stroke, with that colour. | `[L isDrawn, strokeColor]` |
| `fill=<colour>` | Solid fill. | `[L fillColor]` |
| `color=<colour>` | Stroke and text colour when no more specific key applies. | `[L options.ts]` recognised key |
| `text=<colour>` | Content colour. | `[L textColor]` |
| `ultra thin`, `very thin`, `thin`, `semithick`, `thick`, `very thick`, `ultra thick` | Stroke width `0.1, 0.2, 0.4, 0.6, 0.8, 1.2, 1.6` pt. | `[L tikz/options.ts:LINE_WIDTHS, LINE_WIDTH_PT]` |
| `line width=<len in pt>` | Explicit stroke width; wins over a named width. | `[L lineWidthPt, strokeWidthUnits]` |
| `dashed`, `densely dashed`, `loosely dashed`, `dotted`, `densely dotted`, `loosely dotted` | Dash pattern; absent means solid. | `[L tikz/options.ts:DASH_PATTERNS]` |
| `opacity=<0..1>` | Whole-node opacity. | `[L opacity]` |

Stroke widths and corner radii convert pt to slide units with
`PT_TO_UNITS = 3/40` exactly (`0.03 / LINE_WIDTH_PT.thin`)
`[L tikz/options.ts:PT_TO_UNITS]`. This is the legacy stroke anchor, not a
physical conversion; it is used **only** for stroke width and corner radius.

Dash arrays are the exact legacy table in slide units
`[L tikz/options.ts:dashArray]`: `dashed 0.15,0.1`; `densely dashed 0.15,0.06`;
`loosely dashed 0.15,0.18`; `dotted 0.001,0.08` round caps;
`densely dotted 0.001,0.05` round caps; `loosely dotted 0.001,0.14` round caps.
They become `Canvas.CustomDash` and `Render.mkRenderCustomDash`.

`fill opacity=`, `draw opacity=`, `line cap=`, `line join=`,
`on background layer` are **excluded** (recorded).

Typography — the last `font=` declaration `[L tikz/font.ts:tikzFont]`:

| Construct | Semantics | Grounding |
| --- | --- | --- |
| `\tiny \scriptsize \footnotesize \small \normalsize \large \Large \LARGE \huge \Huge` | Size in points `5, 7, 8, 9, 10, 12, 14.4, 17.28, 20.74, 24.88`. | `[L tikz/font.ts:NAMED_SIZE_PT]` |
| `\fontsize{a}{b}` | Size `a` pt, line height `b` pt. | `[L tikz/font.ts]` |
| `\bfseries` / `\mdseries` | `Canvas.WeightBold` / `Canvas.WeightNormal`. | `[L tikz/font.ts]` |
| `\itshape` / `\upshape` | `Canvas.Italic` / `Canvas.Upright`. | `[L tikz/font.ts]` |

Font **size** converts pt to slide units with the length table (1.3), i.e.
`254/7227` slide units per pt exactly, because one slide unit is one centimetre
`[L tikz/coordinates.ts:UNIT_SCALE]`. A node with no `font=` uses
`Canvas.defaultTypography` `[R Canvas/Property.hs:defaultTypography]`, size
`3/10` slide units. Default content colour is black, TikZ's default; **P0.1
resolves no theme palette** so every colour in a plan comes from an authored
option or from that black default. `\fontfamily{…}` and `\fontencoding{…}` are
**excluded** (recorded): the legacy `FAMILY_STACKS` map is legacy-specific, and
the host's own default stack is used for both measurement and paint so the two
always agree.

`align=` on a node is **excluded and recorded**. Grounding for the exclusion:
`[L tikz/options.ts]` contains no `align` reader, and `[L render/slide.ts:416]`
honours `align=` only on a *path label*, never on a node. This is the primary
demonstration of `[D2]`: the adopted fixture keeps six `align=center` items, the
nodes stay coordinate-writable, and each item is surfaced as a visible
rendering limitation.

Style-name references (bare identifier tokens) `[D5]`:

1. If the token names an entry in this body's `\tikzset` style table, its items
   are spliced in place of the token and re-read by the same option reader,
   recursively, to a depth of 8. A cycle or depth overflow makes that reference
   an `style_unresolved` record.
2. Otherwise, if `[L tikz/options.ts:isStyleKnobToken]` classifies the token as a
   knob (`draw`, `rectangle`, `rounded corners`, every `SHAPE_TOKENS` entry,
   every `LINE_WIDTHS` entry, every `DASH_PATTERNS` entry) it is interpreted as
   that knob.
3. Otherwise it is a **theme-role token**, not a TikZ knob
   `[L tikz/options.ts:isStyleKnobToken` doc comment`]`. P0.1 resolves no theme,
   so a role token is recorded as `option_value_unsupported` and honoured only
   as `Canvas.nodePatchRole` in the semantic model.

`style=<name>` is **excluded and recorded**: `[L tikz/options.ts]` has no
`style=` reader, so honouring it would be invention.

### 1.3 Accepted length units

Exactly `[L tikz/coordinates.ts:UNIT_SCALE]`, as exact rationals in slide units:

| Suffix | Slide units per unit |
| --- | --- |
| none | `1` |
| `cm` | `1` |
| `mm` | `1/10` |
| `pt` | `254/7227` |
| `bp` | `127/3600` |
| `in` | `127/50` |
| `em` | `2540/7227` |
| `ex` | `1093571/3613500` (`4.3054 × 2.54 / 72.27`) |

A bare number is centimetres and one slide unit is one centimetre
`[L tikz/coordinates.ts]`. `em` and `ex` are relative to the legacy interpreter's
10 pt `\normalsize` baseline, not to the node's own font; that is exactly the
legacy behaviour and it is stated as a known limitation (section 14).

### 1.4 Accepted colour syntax

Grammar `[L tikz/xcolor.ts:colorExpression]`: `NAME ( '!' PERCENT ( '!' NAME )? )*`
where `NAME` is `[A-Za-z_][A-Za-z0-9_-]*` and `PERCENT` is `\d+(\.\d+)?`.

- `c` — the base colour.
- `c!p` — `p%` of `c` mixed with `(100−p)%` **white** (the omitted second
  operand defaults to `white`) `[L tikz/xcolor.ts:mix` fallback `'white']`.
- `c!p!d` — `p%` of `c` mixed with `(100−p)%` of `d`.
- Mixes apply left to right, each `p` clamped to `[0,100]`
  `[L tikz/xcolor.ts:tikzColorToCss]`.

Mixing is exact rational arithmetic per channel; the final channel is rounded
half away from zero to a `Word8`, matching `[L Math.round]` on non-negative
channels.

Exact colour base table `[L tikz/xcolor.ts:COLORS]`, the only 17 accepted names:

| Name | RGB | Name | RGB |
| --- | --- | --- | --- |
| `black` | 0,0,0 | `orange` | 255,165,0 |
| `white` | 255,255,255 | `violet` | 128,0,128 |
| `red` | 255,0,0 | `purple` | 128,0,128 |
| `green` | 0,128,0 | `brown` | 165,42,42 |
| `blue` | 0,0,255 | `lime` | 0,255,0 |
| `cyan` | 0,255,255 | `pink` | 255,192,203 |
| `magenta` | 255,0,255 | `teal` | 0,128,128 |
| `yellow` | 255,255,0 | `gray` | 128,128,128 |
| `grey` | 128,128,128 | | |

An unknown base or mix name is **not** admitted: the option becomes a
`colour_unsupported` limitation and the affected paint falls back to the
documented default (no fill; black stroke; black text). The legacy fallback that
passes an unrecognised identifier through as a raw CSS colour name
(`[L tikz/xcolor.ts:tikzColorToCss]` final branch) is **deliberately not
ported** — it silently invents a colour and would inject an unvalidated string
into paint. `#rrggbb` hex literals are **excluded**: the legacy analyst records
them as SlideBlaster dialect rather than portable TikZ.

### 1.5 Accepted path syntax and arrow-tip spellings

Endpoints, per `[L tikz/connector.ts]`:

| Endpoint | Semantics |
| --- | --- |
| `(name)` | Node anchor with implicit port. In P0.1 an implicit endpoint is clipped to the node outline (section 6). |
| `(name.<compass>)` | Node anchor with that explicit port; never clipped `[L render/anchors.ts:clipImplicitNodeAnchor]`. |
| `(name.center)` | Treated as `center` and **clipped**, a stated divergence from legacy (section 6). |

Literal `(x,y)`, `+(dx,dy)`, `++(dx,dy)`, `($…$)`, `([xshift=…]a.east)`,
`(a.center |- b.center)`, `intersection` and `let … in` endpoints are
**excluded**: the whole `\draw` statement becomes a read-only region
(`path_statement_unsupported`).

Segments:

| Spelling | Semantics | Grounding |
| --- | --- | --- |
| `--` | `Canvas.StraightSegment` | `[R Deck.hs:parseConnectors]`, `[L connector.ts]` |
| `-\|` | `Canvas.OrthogonalSegment Canvas.HorizontalThenVertical`; corner is `(next.x, this.y)` | `[L connector.ts]`, `[L render/slide.ts:renderPathData]` |
| `\|-` | `Canvas.OrthogonalSegment Canvas.VerticalThenHorizontal`; corner is `(this.x, next.y)` | same |

`.. controls (c1) and (c2) ..`, `cycle`, `to`, `edge`, `bend`, `loop`,
`shorten >=`, `decorate`/`decoration=` are **excluded**
(`path_segment_unsupported`; the statement stays a read-only region). Note that
a labelled path (`-- node[…] {…} (b)`) also falls out of the editable subset in
legacy `[L render/slide.ts:connectorsOf` fallback ladder`]`; P0.1 admits its
**geometry** as a read-only connector and records
`connector_label_unsupported` for the label span rather than painting a label.

Arrow spec `[L tikz/arrows.ts]`. One arrow token per option list, detected by
`isArrowToken`: tip pieces around a top-level `-`, no top-level `=`. A piece is
`[<>|]`, `{Name}`, or a bare `[A-Za-z][\w ]*`. `>=<tip>` and `<=<tip>` set what
`>` and `<` mean. Accepted tip names, case-insensitive
`[L tikz/arrows.ts:TIP_NAMES]`: `to`, `latex`, `stealth`, `bar`, `circle`, `o`,
`square`, `diamond`.

P0.1 **paints** exactly four: `to` (stroked chevron), `latex` (filled),
`stealth` (filled), `bar` (stroked crossbar). `circle`, `o`, `square` and
`diamond` are admitted as names but produce **no tip** plus an
`arrow_tip_unsupported` record. Legacy's silent fallback of an unknown tip name
to `to` `[L tikz/arrows.ts:nameToTip]` is **deliberately not ported**: it
changes meaning without telling the user. An unknown name is
`arrow_tip_unsupported` and paints no tip.

`arrows.meta` per-tip options are admitted only as far as the tip **name**:
`-{Latex[length=2.4mm]}` yields tip `latex` plus an
`arrow_tip_options_unsupported` record for the bracket span. That matches legacy,
which reads the first identifier word and ignores the options
`[L tikz/arrows.ts:nameToTip]`, and it is explicitly out of scope there.

Accepted `\draw` option items are the paint/stroke/dash subset of 1.2
(`draw`, `draw=`, the seven line widths, `line width=`, the six dash patterns,
`opacity=`), the arrow token, `>=`, `<=`, and style-name references resolved
through the same style table. Everything else is recorded.

### 1.6 Accepted content constructs

The node body between its balanced braces is read as mixed content. Accepted
constructs, all from `[L content/parse.ts]`:

| Construct | Lowered to | Grounding |
| --- | --- | --- |
| literal text | `Canvas.TextRun` | `[L content/parse.ts:parseRuns]` |
| `**x**` | `Canvas.StyledRun` with `Canvas.Strong` | `[L content/parse.ts:284]` |
| `*x*` | `Canvas.StyledRun` with `Canvas.Emphasis` | `[L content/parse.ts:284]` |
| `==x==` | `Canvas.StyledRun` with `Canvas.Highlight` | `[L content/parse.ts:297]` |
| `\\` | `Canvas.LineBreak` | `[L content/parse.ts:linebreak]` |
| Markdown list lines `- `, `+ `, `* `, `N. ` | `Canvas.ListContent` with `Canvas.UnorderedList` / `Canvas.OrderedList` | `[L content/parse.ts:LIST_ITEM_LINE]` |
| `\begin{itemize}` / `\begin{enumerate}` with `\item` | same | `[L content/parse.ts:LATEX_LIST_BEGIN]` |
| `<ul>` / `<ol>` with `<li>` | same | `[L content/parse.ts:HTML_LIST_OPEN]` |
| `$…$` | `Canvas.OpaqueMath Canvas.InlineMath` | `[L content/parse.ts:matchMath]` |
| `$$…$$` | `Canvas.OpaqueMath Canvas.DisplayMath` | `[L content/parse.ts:matchMath]` |
| `{ … }` | transparent scoping group; children re-enter parsing | `[L content/parse.ts:122]` |

Allowed inline LaTeX commands, and **only** these
`[L content/parse.ts:LATEX_INLINE]`: `\textbf{…}` → `Strong`,
`\emph{…}` → `Emphasis`, `\textit{…}` → `Emphasis`,
`\underline{…}` → `Underline`, `\hl{…}` → `Highlight`.

Allowed HTML tags, and **only** these `[L content/parse.ts:HTML_TAGS]`:
`b`, `strong` → `Strong`; `i`, `em` → `Emphasis`; `u` → `Underline`;
`s` → `Strike`; `mark` → `Highlight`; `div`, `span` →
`Canvas.TransparentContainer (Canvas.GenericContainer "div"/"span")`.

Tags must be **attribute-free**: `[L content/parse.ts:OPEN_TAG]` is
`/^<([a-zA-Z][a-zA-Z0-9]*)>/`, so `<div class="x">` is out of subset. This forces
a fixture change (section 2).

Out-of-subset behaviour is the legacy hard-error rule
`[L content/parse.ts:OutOfSubsetError]`, `[L design/decisions/0015]`: any
unlisted macro with a `{}` argument, any unlisted or attributed tag, any
unbalanced construct makes the **whole body** one
`Canvas.UnsupportedContent` value with `Canvas.UnsupportedSyntax`, the exact
bytes preserved, plus a `content_out_of_subset` record. The node still paints
its box and stays coordinate-writable.

Math is **not typeset** in P0.1. `Canvas.OpaqueMath` lowers to
`Render.RenderContainer Render.CodeFlow [Render.RenderText <exact math source>]`
plus a `math_not_typeset` record. Grounding: the render vocabulary offers only
`Render.RenderMath` over a closed `RenderMathPresentation` tree
`[R Render/Content.hs]`, and lowering TeX to that tree is a math parser P0.1
does not have; legacy itself renders the math *source* in a span and defers
typesetting to an injected renderer `[L render/html.ts:renderMath]`.

`\textcolor`, `\cite`, `\citefootnote`, `printbibliography`, `\vskip`,
`\cat{…}`, `tabular`, `matrix`, `columns`, images, overlays, `<appear/>`
fragments and colour declarations are **excluded**: they reach
`Canvas.UnsupportedContent` by the same whole-body rule.

### 1.7 Statement boundary detection

`[D6]`. The current rule scans to the next depth-0 `;`
(`[R Deck.hs:statementEnd]`), which mis-swallows `\tikzset{…}` (no trailing
semicolon) and `\foreach … { …; }`. The replacement, in
`SlideBlaster.Deck.Canvas`:

1. Skip trivia: ASCII whitespace and `%` to end of line
   (`[R Deck.hs:skipTriviaBounded]`, unchanged).
2. Dispatch on the leading token:
   - `\node`: parse structurally; the region ends at its required `;`.
   - `\draw`, `\fill`, `\filldraw`, `\path`, `\coordinate`: the region ends at
     the first `;` at depth zero, where depth counts `{}`, `[]` and `()`
     jointly and `\` escapes the next byte.
   - `\tikzset`, `\tikzstyle`, `\def`, `\colorlet`, `\pgfmathsetseed`: the
     region ends at the close of the single balanced `{…}` group that follows
     the command name and its optional `[…]`; **no** `;` is required or
     consumed.
   - `\foreach`: consume the variable list and optional `[…]`, require the
     depth-0 token `in`, consume the balanced `{…}` list group, skip trivia,
     then the body is either one balanced `{…}` group or one statement ending at
     a depth-0 `;`. The region ends there.
   - `\begin{NAME}`: the region ends after the matching `\end{NAME}`, counting
     nested `\begin{NAME}`.
   - `\end{NAME}` with no open `\begin`: the body cannot be bounded safely, so
     the whole document is syntax-only (`deck.unbalanced_environment`).
   - any other `\command`: the region ends at the first depth-0 `;`.
   - anything not starting with `\`: the region ends at the first depth-0 `;`.
3. If no terminator exists before the end of the body, the whole document is
   syntax-only (`deck.unclosed_statement`, existing law
   `[R Deck.hs:statementEnd]`). This is retained because an unboundable region
   cannot be preserved *and* described.

### 1.8 Deliberate exclusions and their fail-closed behaviour

| Excluded | Fail-closed behaviour |
| --- | --- |
| Unit-bearing or polar `at` coordinate | Node admitted, placement read-only, `computed_coordinate` record; no writable coordinate slot. |
| `\foreach`, `\begin{scope}`, `\path`, `\fill`, `\filldraw`, `\coordinate`, `\def`, `\colorlet`, unknown commands | Region preserved exactly; read-only region record (`foreach_expanded`, `scope_transformed`, `path_statement_unsupported`, `unknown_statement`); nothing painted. |
| Computed endpoints and `to`/`bend`/`controls`/`cycle` paths | Whole `\draw` statement is a read-only region; no connector painted. |
| Mid-path `node{…}` label | Connector geometry admitted read-only; `connector_label_unsupported` record; no label painted. |
| `circle`/`o`/`square`/`diamond` arrow tips, per-tip options | Connector painted; no tip for the unsupported name; `arrow_tip_unsupported` / `arrow_tip_options_unsupported` record. |
| Unsupported shape tokens | Rectangle box painted; `shape_unsupported` record. |
| `align=`, `style=`, `rotate=`, `scale=`, `xshift=`, `yshift=`, `on grid`, `label=`, `fit=`, `overlay=`, `tokens=`, `stencil=`, `fill opacity=`, `draw opacity=`, `line cap=`, `line join=`, `on background layer`, `\fontfamily`, `\fontencoding` | Item preserved exactly; `option_key_unsupported` record; **coordinate writability retained** `[D2]`. |
| Unknown colour name, hex colour | Documented default paint; `colour_unsupported` record. |
| Out-of-subset content, attributed HTML | Whole body one preserved unsupported value; `content_out_of_subset` record. |
| Math typesetting | Math source painted verbatim in a code container; `math_not_typeset` record. |
| Notes surfaces | Unchanged from P0: a distinct empty notes surface, read-only `[R docs/specs/str-007-implicit-canvas-slide-trial.md]`; one `notes_surface_read_only` record per note. |
| Literal `"""` in a raw body | Unchanged from P0: syntax-only, no escaping convention `[R str-007 spec]`. |
| `\tikzset` region editing | Read-only source; the canvas never rewrites or renames a style `[D5]`. |

Two whole-document atomic rejections are retained: duplicate slide IDs and
duplicate node IDs within one audience body `[R Deck.hs:parseCanvasBytes, ensureUniqueFrames]`.
One is **changed**: an unresolved connector endpoint no longer makes the whole
document syntax-only. See section 14, item U1.

---

## 2. Adopted fixture

### 2.1 Identity and tracked copies

Adopted filename: **`event-ingest-review.slide`**. It names the deck's subject
and claims nothing about coverage.

Exactly three tracked copies are required, and they must be **byte-identical**:

| Path | Purpose |
| --- | --- |
| `hosts/web/fixtures/event-ingest-review.slide` | Browser demonstration input. |
| `packages/slideblaster-deck/test/fixtures/event-ingest-review.slide` | Parser and inverse oracle. |
| `packages/slideblaster-product-runtime/test/fixtures/event-ingest-review.slide` | Runtime and wire oracle. |

No `temp/` copy is required. The two test copies must be added to the
`data-files` stanza of `slideblaster-deck.cabal` and
`slideblaster-product-runtime.cabal` (integrator-owned). The integrator records
the promoted file's byte length and SHA-256 in `SPEC.md` beside, not instead of,
the existing demo hash.

`[D4]` `hosts/web/fixtures/demo.slide`, its three byte-identical copies
(`packages/slideblaster-deck/test/fixtures/demo.slide`,
`packages/slideblaster-product-runtime/test/fixtures/demo.slide`,
`temp/demo.slide`) and its SHA-256
`d9d15951e4331345cb68c51dbecd3a15f3ac935190fd27c150019bc682428fd1` in `SPEC.md`
are **not** rewritten. Every existing byte-exact law over `demo.slide` in
`packages/slideblaster-deck/test/Main.hs` and
`packages/slideblaster-product-runtime/test/Main.hs` stays and must still pass:
`demo.slide` is the P0 regression evidence. The browser loads
`event-ingest-review.slide` as its default fixture; `demo.slide` remains
tracked and covered by the native suites.

### 2.2 Required changes to `candidate.slide`

The promoted file is
`.META/research/SB2-20260727-001--p0-1-tikz-breadth--fixture-analyst--01/candidate.slide`
with exactly the five changes below. Every change exists because the original
spelling is **not grounded** in the legacy feature surface, and this design may
not invent semantics for it. Line numbers refer to the candidate; the integrator
recomputes them after editing.

| # | Change | Reason |
| --- | --- | --- |
| 1 | Lines 57 and 168: `style=display` → `font=\Large\bfseries`. | `[L tikz/options.ts]` has no `style=` reader, so `style=display` cannot be honoured. `\Large` (14.4 pt) and `\bfseries` are grounded in `[L tikz/font.ts:NAMED_SIZE_PT]`. Without this the two titles would render at body size. |
| 2 | Lines 114 and 208: `style=body` → `font=\small`. | Same reason; `\small` is 9 pt `[L NAMED_SIZE_PT]`. |
| 3 | Lines 109, 119, 215: `<div class="sla">` → `<div>`, `<span class="hint">` → `<span>`, `<div class="rule">` → `<div>`. | `[L content/parse.ts:OPEN_TAG]` admits only attribute-free tags; an attributed tag makes the **whole** node body out-of-subset, which would delete three of the fixture's four structured-content demonstrations. |
| 4 | Every `\( … \)` → `$ … $` and the `\[ … \]` block at lines 116-118 → `$$ … $$`. | `[L content/parse.ts:matchMath]` admits only `$…$` and `$$…$$`; `\(`/`\[` fall through to literal text in legacy, so claiming them as math would be invention. |
| 5 | Append one node at the end of the `backpressure` body, before its closing `"""`: `\node[draw=black!45, anchor=north west, text width=40mm] (caveat) at (1,1.2) {\marginpar{late}};` | Nothing in the candidate exercises the content fail-closed path once change 3 lands. `\marginpar` is not in `[L LATEX_INLINE]`, so this node demonstrates `content_out_of_subset` end to end: exact bytes preserved, body unpainted, visible record, and the node still coordinate-writable. Appending keeps every earlier line number stable. |

No other change is required or permitted. In particular the six `align=center`
items are **kept unchanged**: they are the fixture's demonstration of `[D2]`,
an unhonoured visual option that must not remove coordinate writability.

### 2.3 What the fixture is expected to demonstrate

| Capability | Fixture evidence after the five changes |
| --- | --- |
| 1 multiple named nodes | 10 admitted nodes on `architecture`, 7 on `backpressure`. |
| 2 real structured content | Markdown bold, `\\` break, ordered list, unordered list, `<div>`, `<span>`, inline and display math source, em dash, plus one deliberately out-of-subset body. |
| 3 common options | `anchor`, `text width`, `minimum size`, `minimum height`, `rounded corners`, `circle`, `fill`, `draw=`, seven line widths, `dashed`, `font=`, `text=`; plus `align=` as the recorded limitation. |
| 4 absolute and relative | 12 direct-coordinate nodes; `decode`, `enrich`, `overflow` relative and read-only; `sla-tag`, `depth-tag` computed and read-only. |
| 5 straight and orthogonal with tips | 5 straight, 4 orthogonal; `-stealth` and `-{Latex[…]}` tips; `flow`/`trace` styles supply tips by expansion. |
| 6 connector follows a move | Every admitted endpoint is a node-and-port reference. |
| 7 selection and movement | All 12 direct-coordinate nodes. |
| 8 resize/create/duplicate/delete | Literal `text width` slots on `title`, `audit-log`, `budget`, `heading`, `consumer`, `dead-letter`, `reading`, `caveat`; `minimum height` on none directly, `minimum size` on `queue` which is deliberately resize-read-only; delete available on the unreferenced `title`, `contract`, `budget`, `heading`, `reading`, `caveat`. |
| 9 exact local edits | Mixed integer and decimal coordinates; comments at 13 positions must survive byte-identical. |
| 10 visible read-only | `\tikzset` block, three relative nodes, two `\foreach` regions, one `scope`, two computed placements, one path label, one out-of-subset body, two notes. |
| 11 real-world | The whole document. |

---

## 3. Data flow

Exact module and type names. `NEW` marks a type introduced by P0.1; `CHANGED`
marks a signature that changes.

```text
authored bytes  (Source.SourceBufferSnapshot)
  |
  |  SlideBlaster.Deck.analyzeDeck                                  [I1]
  v
Deck CST
  SlideBlaster.Deck.Syntax.DeckSyntax        (CHANGED)
  SlideBlaster.Deck.Syntax.SlideSyntax       (CHANGED)
  SlideBlaster.Deck.Syntax.NodeSyntax        (CHANGED)
  SlideBlaster.Deck.Syntax.ConnectorSyntax   (CHANGED)
  SlideBlaster.Deck.Syntax.RegionSyntax      (NEW)
  |
  |  SlideBlaster.Deck.Canvas.scanBody       (NEW, statement boundaries, 1.7)
  |  SlideBlaster.Deck.Style.styleTable      (NEW, \tikzset -> StyleTable)
  |  SlideBlaster.Deck.Options.readItems     (NEW, ordered spanned items)
  |  SlideBlaster.Deck.Options.expandStyles  (NEW, style splice, depth <= 8)
  |  SlideBlaster.Deck.Node.readNode         (NEW)
  |  SlideBlaster.Deck.Path.readPath         (NEW)
  |  SlideBlaster.Deck.Content.readContent   (NEW)
  |  SlideBlaster.Deck.Region.note           (NEW)
  v
Canvas semantic model + provenance + notes
  Canvas.Node { nodePlacement, nodeOutline, nodeContent, nodePropertyOverrides }
  Canvas.Connector { connectorPath, connectorPropertyOverrides }
  Document.ProvenanceMap SlideBlaster.Deck.DeckFieldKey        (CHANGED keys)
  SlideBlaster.Deck.Region.SourceNote                          (NEW)
  |
  |  relative resolution happens here, at parse time, because Deck owns spans:
  |  SlideBlaster.Deck.Node.classifyPlacement -> PlacementSyntax (NEW)
  |  SlideBlaster.Deck.Node.referenceOrder    -> topological order, cycle set
  |  a cyclic or unresolvable node is NOT admitted; it becomes a SourceNote
  v
Presentation.Presentation  (unchanged type)
  |
  |  SlideBlaster.Engine.CommonTikz.surfaceMeasurementBatch    (NEW)      [I1]
  v
Render.MeasurementBatch  (existing type, ticket + manifest + requests)
  |
  |  Product/2 round trip: workspace.measurement -> provide_measurements     [I2]
  |  SlideBlaster.Product.Runtime.ProductV2.PendingMeasurement  (NEW)
  |  SlideBlaster.Product.Runtime.ProductV2.MeasurementCache    (NEW)
  v
Render.MeasurementSet  (existing, via Render.completeMeasurements)
  |
  |  SlideBlaster.Engine.CommonTikz.renderPresentationSurfacePlan (CHANGED) [I1]
  |    - Render.NodeLayoutInput / Render.resolveNodeLayout resolve placement
  |    - Render.lowerOutlineRef lowers the outline
  |    - Render.mkRenderTypography / mkRenderStroke / solidRenderPaint lower style
  |    - connector clipping, orthogonal expansion, arrow-tip geometry
  v
Render.RenderPlan
  layers: ConnectorLayer (ConnectorPrimitive), ObjectLayer (ShapePrimitive),
          ContentLayer (ContentPrimitive)
  |
  |  SlideBlaster.Product.Runtime.ProductV2.itemValue (CHANGED)            [I2]
  v
Product/2 JSON  (section 10 frozen schema)
  |
  |  hosts/web/src/protocol/product-v2.js validate*                        [I2]
  |  hosts/web/src/ui/product-v2-renderer.js paint                         [I2]
  v
host paint  ->  host measurement reply  ->  provide_measurements
```

### 3.1 New Haskell types

`SlideBlaster.Deck.Syntax` (all `NEW` unless stated):

```haskell
data PlacementSyntax
  = DirectCoordinate !Canvas.Point !Canvas.BorderPort !Source.SourceSpan !Source.SourceSpan
  | RelativeCoordinate !Canvas.RelativePlacement !Source.SourceSpan
  | ComputedCoordinate !Source.SourceSpan

data LengthUnit = UnitNone | UnitCm | UnitMm | UnitPt | UnitBp | UnitIn | UnitEm | UnitEx

data LengthSlot = LengthSlot
  { lengthSlotAxis  :: !SizeAxis
  , lengthSlotSpan  :: !Source.SourceSpan   -- the numeric lexeme only
  , lengthSlotUnit  :: !LengthUnit
  , lengthSlotValue :: !Rational            -- in slide units
  , lengthSlotShared :: !Bool               -- True for `minimum size` (both axes)
  }

data SizeAxis = WidthAxis | HeightAxis

data OptionItem = OptionItem
  { optionItemSpan  :: !Source.SourceSpan
  , optionItemKey   :: !Text
  , optionItemValue :: !(Maybe Text)
  , optionItemValueSpan :: !(Maybe Source.SourceSpan)
  }

newtype StyleTable = StyleTable (Map Text [OptionItem])

data RegionSyntax = RegionSyntax
  { regionSpan   :: !Source.SourceSpan
  , regionReason :: !NoteReason
  }
```

`SlideBlaster.Deck.Region`:

```haskell
data NoteKind = ReadOnlyRegionNote | RenderingLimitationNote

data NoteReason
  = RelativePlacementReadOnly | RelativeTargetMissing | RelativeCycle
  | ComputedCoordinateReadOnly | StyleDefinitionReadOnly | StyleUnresolved
  | ForeachExpanded | ScopeTransformed | PathStatementUnsupported
  | PathSegmentUnsupported | ConnectorLabelUnsupported | ConnectorEndpointMissing
  | ArrowTipUnsupported | ArrowTipOptionsUnsupported
  | OptionKeyUnsupported | OptionValueUnsupported
  | ShapeUnsupported | ColourUnsupported
  | ContentOutOfSubset | MathNotTypeset
  | UnknownStatement | NotesSurfaceReadOnly
  | ResizeSlotAbsent | ResizeSlotAmbiguous

data SourceNote = SourceNote
  { sourceNoteId      :: !Text                    -- stable within a revision
  , sourceNoteKind    :: !NoteKind
  , sourceNoteReason  :: !NoteReason
  , sourceNoteFrame   :: !Presentation.FrameId
  , sourceNoteElement :: !(Maybe Canvas.ElementId)
  , sourceNoteSpan    :: !Source.SourceSpan       -- exact parent byte span
  , sourceNoteDetail  :: !Text                    -- e.g. the offending key text
  }
```

`sourceNoteId` is `"note-" <> frameIdText <> "-" <> show ordinal`, the ordinal
being the note's position in document order for that frame. It is stable for one
revision and is used only as a DOM key.

`SlideBlaster.Deck` `DeckFieldKey` (CHANGED):

```haskell
data DeckFieldKey
  = DeckAudienceX !Presentation.FrameId !Canvas.NodeId
  | DeckAudienceY !Presentation.FrameId !Canvas.NodeId
  | DeckAudienceWidth  !Presentation.FrameId !Canvas.NodeId
  | DeckAudienceHeight !Presentation.FrameId !Canvas.NodeId
  | DeckAudienceStatement !Presentation.FrameId !Canvas.NodeId
```

`SlideBlaster.Deck` `DeckEditError` (CHANGED) adds
`DeckNodeNotWritable !Canvas.NodeId`,
`DeckResizeSlotAbsent !Canvas.NodeId !SizeAxis`,
`DeckResizeSlotAmbiguous !Canvas.NodeId`,
`DeckResizeNotRepresentable !Canvas.NodeId`,
`DeckDeleteBlocked !Canvas.NodeId !Source.SourceSpan`,
`DeckIdentityExhausted`.

`SlideBlaster.Engine.CommonTikz` `CommonTikzRenderError` (CHANGED) adds
`CommonTikzRenderMeasurementMissing !Render.MeasurementKey`,
`CommonTikzRenderBatch !Render.MeasurementBatchError`,
`CommonTikzRenderLayout !Render.LayoutError`,
`CommonTikzRenderGeometry !Render.RenderGeometryError`,
`CommonTikzRenderContentUnsupported`.

`SlideBlaster.Engine.NominalMeasurement` (NEW module, section 5.4).

`SlideBlaster.Canvas.Edit` `EditIntent` (CHANGED) adds exactly one constructor:

```haskell
  | DuplicateElement !ElementId !Vector
```

This is safe for the frozen Product/1 path: `SlideBlaster.TikZ.Adapter.applyCommonTikzEdit`
ends with `_ -> Left (TikzCanvasIntentUnsupported operation)`
(`packages/slideblaster-tikz/src/SlideBlaster/TikZ/Adapter.hs:102`), so no file
under `packages/slideblaster-tikz` changes `[D7]`. Duplicate cannot be expressed
as `InsertNode` because byte-exact duplication of the authored statement needs
the source element's identity, which `Canvas.NodeSeed` does not carry.

### 3.2 Changed Haskell signatures

```haskell
-- SlideBlaster.Engine.CommonTikz  (I1)

-- NEW
surfaceMeasurementBatch
  :: Render.MeasurementTicket
  -> Presentation.SurfaceAddress
  -> Presentation.Presentation
  -> Either CommonTikzRenderError Render.MeasurementBatch

-- CHANGED: the Canvas.Size node-size constant is replaced by a MeasurementSet
renderPresentationSurfacePlan
  :: Render.RenderTicket
  -> Canvas.Size                       -- slide size, unchanged
  -> Render.MeasurementSet             -- was: Canvas.Size nodeSize
  -> (Canvas.NodeId -> Bool)
  -> Presentation.SurfaceAddress
  -> Source.SourceBufferSnapshot
  -> Presentation.Presentation
  -> Either CommonTikzRenderError Render.RenderPlan

-- UNCHANGED signature, retained for the frozen Product/1 codec [D7]
renderCommonTikzPlan
  :: Render.RenderTicket -> Canvas.Size -> Canvas.Size
  -> CommonTikzDocument -> Either CommonTikzRenderError Render.RenderPlan
-- Implementation: build the batch for the first frame's audience surface, then
-- complete it with the supplied constant size for every request via
-- Render.MeasurementResult and Render.completeMeasurements. Callers in
-- packages/slideblaster-protocol/src/SlideBlaster/Protocol/{Codec,Render}.hs are
-- not touched.
```

```haskell
-- SlideBlaster.Deck  (I1)

-- CHANGED: explicit expected revision closes the stale-snapshot hole where a
-- caller that bypasses App.beginCanvasEdit would lose the law.
applyDeckCanvasEdit
  :: Source.Revision                   -- NEW first parameter
  -> Presentation.FrameId
  -> Canvas.EditIntent
  -> DeckDocument
  -> Either DeckEditError DeckDocument

-- UNCHANGED
writableNodePlacement
  :: Presentation.FrameId -> Canvas.NodeId -> DeckDocument -> Maybe Canvas.Placement

-- NEW
deckSourceNotes :: DeckDocument -> [Region.SourceNote]
deckNodeFields  :: Presentation.FrameId -> Canvas.NodeId -> DeckDocument -> NodeFields
deckCommandAvailability :: Presentation.FrameId -> Maybe Canvas.NodeId -> DeckDocument -> CommandAvailability

data NodeFields = NodeFields
  { nodeFieldCoordinate :: !Bool
  , nodeFieldWidth      :: !SlotState
  , nodeFieldHeight     :: !SlotState
  , nodeFieldStatement  :: !Bool
  }

data SlotState = SlotWritable !Rational | SlotAbsent | SlotAmbiguous

data CommandAvailability = CommandAvailability
  { canCreateNode    :: !Bool
  , canDuplicateNode :: !Bool
  , canDeleteNode    :: !(Either NoteReason ())
  , canResizeWidth   :: !SlotState
  , canResizeHeight  :: !SlotState
  }
```

`packages/slideblaster-product-runtime` and `packages/slideblaster-protocol`
consume exactly the API above; they must not reach into
`SlideBlaster.Deck.*` submodules.

---

## 4. Writable provenance per field

`[D2]` writability is per field. A node contributes up to four independent
provenance entries and one statement-level entry.

### 4.1 Writable cases

**W1 — direct coordinate pair.** Keys `DeckAudienceX` / `DeckAudienceY`.
Origin `Document.DirectSlot <lexeme span> (rule "deck.implicit-tikz.direct-coordinate")`.

Eligible exactly when `nodeSyntaxPlacement` is
`DirectCoordinate point port xSpan ySpan` and the port came from a recognised
`anchor=` value or its absence. Unrecognised or unhonoured **visual** options do
not disqualify it `[D2]`.

Inverse rule and exact span arithmetic (unchanged from P0 and re-stated because
it is now one of five):

```text
combined = [ start(xSpan) , end(ySpan) )
middle   = bytes( end(xSpan) , start(ySpan) )        -- comma and spacing verbatim
expected = bytes(combined)
value    = renderRational(dest.x) <> middle <> renderRational(dest.y)
```

`renderRational` refuses a non-terminating decimal
(`[R Deck.hs:renderRational, terminatingDecimal]`), so an unrepresentable
destination rejects rather than rounds.

**W2 — literal width length.** Key `DeckAudienceWidth`. Origin
`Document.DirectSlot <numeric lexeme span> (rule "deck.implicit-tikz.literal-length")`.

Eligible exactly when the node's **own** option list (not a style expansion)
contains exactly one `text width=<len>` or `minimum width=<len>` item whose
value is a numeric lexeme followed by an accepted unit suffix, and no
`minimum size=` item. If the width comes only from a `\tikzset` style, the slot
is `SlotAbsent` (`resize_slot_absent`): rewriting the style would change every
consumer, which has no bounded inverse `[D5]`.

Span arithmetic:

```text
slot     = [ first non-space byte after '=' , last non-space byte of the item + 1 )
numeric  = [ start(slot) , start(slot) + length of the leading numeric lexeme )
suffix   = [ end(numeric) , end(slot) )               -- the authored unit, verbatim
expected = bytes(numeric)
value    = renderRational( requested_slide_units / UNIT_SCALE(unit) )
```

The authored unit spelling is preserved byte-for-byte because only `numeric` is
replaced. If the converted value is not a terminating decimal the projection
returns `DeckResizeNotRepresentable`; that is why `pt`, `bp`, `em` and `ex`
width slots are usually not resizable, and it is stated as a limitation.

**W3 — literal height length.** Key `DeckAudienceHeight`, identical rule over
`minimum height=<len>`.

**W4 — `minimum size` is deliberately not writable.** One lexeme owns both axes,
so a single-axis resize would silently change the other. Slot state
`SlotAmbiguous`, reason `resize_slot_ambiguous`. This diverges from the fixture
analyst's intent for `queue` and is stated in section 14.

**W5 — whole node statement.** Key `DeckAudienceStatement`. Origin
`Document.DirectSlot <statement span> (rule "deck.implicit-tikz.node-statement")`.

Eligible exactly when the placement is `DirectCoordinate` (so a duplicate can be
offset and a created node can be verified) **and**, for delete, the reference
test in section 7.5 passes.

### 4.2 Read-only classification set

Every entry below produces `Document.ReadOnly <reason> (Just span)` for the
affected field keys and one `SourceNote`.

| Case | `Document.NonEditableReason` | `NoteReason` | Detection |
| --- | --- | --- | --- |
| relative placement (`<side>=<d> of <ref>`) | `ExpandedSyntax` | `RelativePlacementReadOnly` | `Deck.Node.classifyPlacement` |
| relative target absent | `AmbiguousOwnership` | `RelativeTargetMissing` | `Deck.Node.referenceOrder` |
| relative reference cycle | `AmbiguousOwnership` | `RelativeCycle` | `Deck.Node.referenceOrder` |
| unit-bearing, polar or computed `at` | `ExpandedSyntax` | `ComputedCoordinateReadOnly` | `Deck.Node.classifyPlacement` |
| width or height only from a style | `MissingInverseRule` | `ResizeSlotAbsent` | `Deck.Options.expandStyles` provenance flag |
| `minimum size` | `AmbiguousOwnership` | `ResizeSlotAmbiguous` | `Deck.Options.readItems` |
| `\tikzset` region | `OpaqueSource` | `StyleDefinitionReadOnly` | `Deck.Canvas.scanBody` |
| undefined style name | `UnsupportedSyntax` | `StyleUnresolved` | `Deck.Options.expandStyles` |
| `\foreach` region | `ExpandedSyntax` | `ForeachExpanded` | `Deck.Canvas.scanBody` |
| `scope` region | `ExpandedSyntax` | `ScopeTransformed` | `Deck.Canvas.scanBody` |
| `\path`/`\fill`/`\filldraw`/`\coordinate`/unknown command | `UnsupportedSyntax` | `PathStatementUnsupported` / `UnknownStatement` | `Deck.Canvas.scanBody` |
| non-node or computed connector endpoint | `ExpandedSyntax` | `PathStatementUnsupported` | `Deck.Path.readPath` |
| `to`/`bend`/`controls`/`cycle` segment | `UnsupportedSyntax` | `PathSegmentUnsupported` | `Deck.Path.readPath` |
| mid-path `node{…}` label | `UnsupportedSyntax` | `ConnectorLabelUnsupported` | `Deck.Path.readPath` |
| connector endpoint names a non-admitted node | `ReferenceMissing` via note only | `ConnectorEndpointMissing` | `Deck.Canvas.scanBody` post-pass |
| unsupported arrow tip name / per-tip options | n/a (limitation) | `ArrowTipUnsupported` / `ArrowTipOptionsUnsupported` | `Deck.Path.readPath` |
| unsupported option key | n/a (limitation) | `OptionKeyUnsupported` | `Deck.Options.readItems` |
| theme-role token, unsupported option value | n/a (limitation) | `OptionValueUnsupported` | `Deck.Options.readItems` |
| unsupported shape token | n/a (limitation) | `ShapeUnsupported` | `Deck.Node.readNode` |
| unknown colour, hex colour | n/a (limitation) | `ColourUnsupported` | `Deck.Options.readItems` |
| out-of-subset content | n/a (limitation) | `ContentOutOfSubset` | `Deck.Content.readContent` |
| math run | n/a (limitation) | `MathNotTypeset` | `Deck.Content.readContent` |
| note body | n/a | `NotesSurfaceReadOnly` | `Deck.Parent` |

**The unsound byte sniff is removed.** `Deck.hs:hasRelativeOption` (lines
851-862) classifies `[above of=n]` as *writable* because it requires the key to
be immediately followed by `=`. It is deleted. Writability is now derived only
from `PlacementSyntax`, which is produced by a real option parse using the
grounded placement predicate. A node whose option list contains an item matching
`^(above|below|left|right)\b.*=.*\bof\b` is `RelativeCoordinate`; a node with a
`<side>=` item that does **not** contain `of` is a plain unsupported option
(recorded), and if the node also has no `at (...)` it is
`ComputedCoordinateReadOnly` because its position cannot be determined.

---

## 5. Node content and the real measurement design

`[D1]`. Measurement is a browser fact transported to Haskell. Layout, boxes,
ports and connector endpoints are owned by Haskell alone. JavaScript performs no
layout policy.

### 5.1 Why the round trip, and not the MeasurementPort

`packages/slideblaster-ports/src/SlideBlaster/Ports/Measurement.hs` is an `IO`
capability, and
`adapters/slideblaster-adapter-web/src/SlideBlaster/Adapter/Web/Port.hs:88-96`
keeps it `CapabilityUnavailable` because host protocol v1's plain-text
`measure.text` cannot honour structured content or exact fonts. That stays
unchanged and unused in P0.1. The Product/2 boundary is a **pure, synchronous**
dispatch (`runProductV2Request`, `sb_product_v2_dispatch`), so a measurement
cannot be awaited inside it. Measurement is therefore a protocol round trip:
Haskell publishes a batch, the host answers with a request, Haskell then plans.

### 5.2 Request

Haskell builds one `Render.MeasurementBatch` per analysis, covering **every**
audience surface of every frame, so navigator thumbnails and the active surface
are planned from the same evidence.

- Ticket: `Render.MeasurementTicket` allocated by the runtime, monotonic within
  a session, fenced against the analysed revision.
- Resource manifest: `Render.emptyResourceManifest`. P0.1 embeds no fonts, which
  is exactly why it makes no typographic-fidelity claim.
- One `Render.MeasurementRequest` per node with non-empty content:
  - `measurementKey = Render.MeasurementKey (Presentation.elementAddress surface (Canvas.NodeElement id)) (part "body")`
  - `measurementContent` — the lowered `Render.RenderContent` for that node,
    carrying resolved `Render.RenderTypography` on every text run.
  - `measurementMode` — `Render.MeasureWithin w` when the node has
    `text width=w`, otherwise `Render.MeasureIntrinsic`.

A node whose content lowers to nothing (empty body) is not measured; its content
extent is `(0,0)`.

Wire form is in section 10.4.

### 5.3 Reply, and who owns wrapping

The host measures and returns only **raw extents**. Exact host procedure, which
is mechanical and contains no policy:

1. `await document.fonts.ready`.
2. Create one detached container:
   `position:fixed; left:-100000px; top:0; visibility:hidden; pointer-events:none;`
   `white-space:pre-wrap; overflow-wrap:break-word; padding:0; margin:0; border:0`.
3. For each request build one child from the closed content tree, setting only
   `font-size`, `line-height`, `font-weight`, `font-style`, `text-decoration`,
   and `width`. `font-size` is `size × 100` CSS px; `width` is `w × 100` CSS px
   for `within` and `max-content` for `intrinsic`.
4. Append all children, force one reflow, then read every
   `getBoundingClientRect()`.
5. Divide width and height by exactly `100` and format as a decimal **rounded
   up** to six fractional digits, so the returned value is a terminating decimal
   and never smaller than what the browser laid out.
6. Remove the container and dispatch `provide_measurements`.

The fixed basis of **100 CSS px per slide unit** makes a measurement independent
of viewport size and of the host zoom transform, which is a composited transform
on `.deck-canvas` and never resizes slides (`docs/specs/product-v2-protocol.md`,
local viewport ownership). Padding is **not** applied by the host: Haskell adds
inner separation, so padding policy stays in Haskell.

**Wrapping**: Haskell owns the wrap *constraint*, the browser performs the line
breaking inside it, Haskell owns the resulting box. The host never decides
whether to wrap, at what width, or how to distribute the result.

### 5.4 Box computation, owned by Haskell

Given content extent `(cw, ch)` in slide units:

```text
sepX      = inner xsep, else inner sep, else 1/5
sepY      = inner ysep, else inner sep, else 1/5
baseWidth = (text width present ? textWidth : cw) + 2 * sepX
baseHeight= ch + 2 * sepY
width     = max(baseWidth,  minimum width  or minimum size, else 0)
height    = max(baseHeight, minimum height or minimum size, else 0)
```

Grounded on `[L tikz/options.ts:textWidth, minWidth, minHeight, innerPadding]`
and `[L layout/measure.ts:PADDING]`. Both minima are grow-only, exactly as the
legacy comments state. The resulting `Canvas.Size` feeds
`Render.NodeLayoutInput`, and `Render.resolveNodeLayout` turns authored
placement plus size into `Render.ResolvedNode` boxes with the existing
dependency fold and cycle detection.

Relative placement ports are set explicitly by `Deck.Node.classifyPlacement`
rather than by tuple position, to avoid a silent swap:

| `<side>` | `relativeTargetPort` | `relativeOwnPort` | `Canvas.RelativeSide` |
| --- | --- | --- | --- |
| `above` | `North` | `South` | `Above` |
| `below` | `South` | `North` | `Below` |
| `left` | `West` | `East` | `LeftOf` |
| `right` | `East` | `West` | `RightOf` |
| `above left` | `NorthWest` | `SouthEast` | `AboveLeft` |
| `above right` | `NorthEast` | `SouthWest` | `AboveRight` |
| `below left` | `SouthWest` | `NorthEast` | `BelowLeft` |
| `below right` | `SouthEast` | `NorthWest` | `BelowRight` |

This matches `[L tikz/options.ts]` positioning shorthand (`above→south` own
anchor) and `Canvas.defaultPortsForSide`, which is retained only as
documentation. `relativePrimaryGap` is the authored distance or the fallback;
`relativeSecondaryGap` is zero.

### 5.5 Fail-closed rule

No measurement, no geometry. Concretely:

- If any request in the batch has no result, `Render.completeMeasurements`
  returns `MissingMeasurementResults` and the runtime produces **no render
  offer** for any surface. `workspace.readiness` stays `"ready"`,
  `workspace.authority` becomes `"none"`, `workspace.renderOffer` and every
  `navigator.items[*].audience` are `null`, and `workspace.measurement` reports
  the failure with an explicit reason. The source pane, navigator and read-only
  notes remain populated: **the editor never blanks**.
- The JS law "a ready workspace offers a render" is therefore removed and
  replaced by "a ready workspace either offers a render or reports a
  measurement state".
- `CommonTikz` never substitutes a constant. `CommonTikzRenderMeasurementMissing`
  is returned instead, and the runtime maps it to `render_rejected`.
- A stale measurement cannot commit an edit: a commit requires a displayed paint
  lease, and a displayed paint exists only for a plan built from a completed
  batch whose ticket matched the analysed revision.

### 5.6 Staleness and exact reuse

`Render.completeMeasurements` already rejects a foreign ticket
(`StaleMeasurementResult`), duplicate keys and unexpected keys. The runtime adds:

- `productPendingMeasurement :: Maybe PendingMeasurement` holding the ticket, the
  analysed revision, and the per-surface batches. A `provide_measurements` whose
  ticket differs returns `measurement_stale` and changes no state.
- `productMeasurementCache :: Map Render.MeasurementKey (Render.MeasurementRequest, Canvas.Size)`.
  When a new batch is built, a key whose `MeasurementRequest` is **equal** to
  the cached one (`Eq` over `RenderContent` and `MeasurementMode`) reuses the
  cached size and is dropped from the outgoing request list. This is exactness,
  not tolerance: the measured thing is value-identical. A coordinate-only edit
  therefore needs no round trip, and a drag commits with the same latency as
  P0. The cache is cleared on `open_source`.
- If the residual request list is empty, the runtime plans immediately in the
  same dispatch and offers the paint, exactly as P0 does today.

### 5.7 Labelled deterministic test measurer

`packages/slideblaster-engine/src/SlideBlaster/Engine/NominalMeasurement.hs`
(NEW, I1):

```haskell
-- | Deterministic, DOM-free node extents for native and headless runs.
--
-- This is a NOMINAL measurer. It claims no typographic fidelity of any kind:
-- it counts characters and lines. It exists so pure layout, plan, inverse and
-- runtime laws are executable without a browser. It must never be installed in
-- a browser composition, and no product claim may be derived from its numbers.
module SlideBlaster.Engine.NominalMeasurement
  ( nominalMeasurementNotice
  , nominalMeasurementSet
  ) where

nominalMeasurementNotice :: Text        -- "nominal non-typographic measurement"
nominalMeasurementSet
  :: Render.MeasurementBatch
  -> Either Render.MeasurementCompletionError Render.MeasurementSet
```

Constants are the legacy headless estimator's, so they are grounded rather than
invented `[L layout/measure.ts:naiveMeasurer]`: character advance `7/50`, line
height `11/20`, minimum width `1`, minimum height `3/5`. Padding is **not**
included, because Haskell adds inner separation (5.4). Text is taken from
`Render.renderContentPlainText`; a `MeasureWithin w` request wraps greedily at
`floor(w / (7/50))` characters per line.

### 5.8 Honesty statement

The product does **not** claim pdflatex-identical extents, and P0.1 makes no
claim of typographic fidelity at all. In the browser, node boxes come from the
browser's own text layout at a fixed 100 CSS px per slide unit using the host's
default font stack, with no embedded fonts and no math typesetting; a
`pdflatex` run over the same source would produce different extents. In native
and headless runs the boxes come from the explicitly labelled nominal measurer,
which counts characters. Both are honest derived layout evidence; neither is a
typesetting claim, and neither ever enters authored source.

---

## 6. Connectors

### 6.1 Representation

`SlideBlaster.Deck.Path.readPath` produces, per admitted `\draw` statement, one
`ConnectorSyntax` per adjacent endpoint pair:

```haskell
data ConnectorSyntax = ConnectorSyntax
  { connectorSyntaxId        :: !Canvas.ConnectorId
  , connectorSyntaxStatement :: !Source.SourceSpan
  , connectorSyntaxStart     :: !Canvas.NodeId
  , connectorSyntaxStartPort :: !Canvas.BorderPort
  , connectorSyntaxStartImplicit :: !Bool
  , connectorSyntaxEnd       :: !Canvas.NodeId
  , connectorSyntaxEndPort   :: !Canvas.BorderPort
  , connectorSyntaxEndImplicit   :: !Bool
  , connectorSyntaxSegment   :: !Canvas.ConnectorSegment
  , connectorSyntaxProperties :: !Canvas.ConnectorPropertyPatch
  }
```

The semantic value stays a two-anchor `Canvas.ConnectorPath` built with
`Canvas.mkConnectorPath (NodeAnchor a portA :| [NodeAnchor b portB]) [segment] Canvas.OpenPath`,
so `Canvas.resolveConnectorPath` re-resolves both endpoints from current boxes on
every plan and **no geometry is ever cached** `[R Canvas/Connector.hs]`. Arrow
tips and stroke live in `Canvas.ConnectorPropertyPatch`
(`connectorPatchStartTip`, `connectorPatchEndTip`, `connectorPatchStroke`,
`connectorPatchDash`, `connectorPatchOpacity`) `[R Canvas/Property.hs]`.

Because `Canvas.Anchor` cannot distinguish `(a)` from `(a.center)`, the implicit
flags live in the CST and are transported to the engine through the
`Canvas.BorderPort` value alone: **a `Centre` endpoint is always clipped**. This
is a stated divergence from `[L render/anchors.ts:clipImplicitNodeAnchor]`, which
never clips an explicit `.center`. The divergence is deliberate: it avoids
widening a shared closed type for a case that does not occur in the fixture and
that no user wants (a line drawn to a box centre is drawn inside the box). The
CST flags are retained for the P0.2 decision recorded in section 14.

### 6.2 Port and border-clipping geometry

Computed in `SlideBlaster.Engine.CommonTikz.clipEndpoint`, after
`Canvas.resolveConnectorPath` and before path construction.

- A **compass** port (`north`, `north east`, …) is never clipped: the resolved
  `Canvas.pointAtPort` value is the endpoint `[L clipImplicitNodeAnchor]`.
- A **`Centre`** port is clipped along the direction `d` of the adjacent leg,
  from the box centre outward, with the box half-extents `(rx, ry)`:
  - rectangle, rounded rectangle, polygon outline:
    `t = 1 / max(|dx|/rx, |dy|/ry)` — exact rational arithmetic.
  - ellipse outline: `t = 1 / sqrt(dx²/rx² + dy²/ry²)`. This is the only
    irrational value in the pipeline. It is computed with one IEEE-754 `Double`
    square root and converted exactly with `toRational`, giving a deterministic
    dyadic rational. It is derived paint geometry and never enters authored
    source. Both formulas are `[L render/anchors.ts:clipImplicitNodeAnchor]`.
  - If `d` is the zero vector (coincident boxes) the endpoint is the centre and
    the connector carries no tip; there is no direction to clip along.

For a straight segment the direction for both endpoints is `end − start`. For an
orthogonal segment the **start** endpoint is clipped along the first leg's
direction and the **end** endpoint along the last leg's direction, with the
corner recomputed from the clipped endpoints so the elbow stays square.

### 6.3 Straight and orthogonal routing

Deck stores only the segment *kind*; the corner is derived at resolve time from
the resolved endpoints, so a node move re-routes for free and no elbow is ever
stored `[L knowledge/concepts/editable-connector-subset.md]`,
`[R Canvas/Connector.hs:resolveConnectorPath]`.

| Authored | `Canvas.ConnectorSegment` | Resolved corner | Render path |
| --- | --- | --- | --- |
| `--` | `StraightSegment` | none | `mkRenderPath s (RenderLineTo e :| []) RenderOpenPath` |
| `-\|` | `OrthogonalSegment HorizontalThenVertical` | `(e.x, s.y)` | `mkRenderPath s (RenderLineTo c :| [RenderLineTo e]) RenderOpenPath` |
| `\|-` | `OrthogonalSegment VerticalThenHorizontal` | `(s.x, e.y)` | same shape |

Corner order matches `[L render/slide.ts:renderPathData]` exactly:
`'hv'` turns at `{x: to.x, y: from.y}`, `'vh'` at `{x: from.x, y: to.y}`.
`SlideBlaster.Engine.CommonTikz.resolvedStraightPath` is replaced by
`resolvedConnectorPath`, which accepts `ResolvedStraight` and
`ResolvedOrthogonal` and rejects `ResolvedCubic` with
`CommonTikzRenderConnectorUnsupported` (unreachable, since Deck never emits a
cubic in P0.1, but retained as a closed guard).

### 6.4 Arrow tips

Tips are **plan geometry**, not host markers:
`Render.ConnectorPrimitive path stroke tips` where
`Render.RenderArrowTip` is `StrokedRenderArrowTip RenderPath RenderStroke` or
`FilledRenderArrowTip RenderOutline RenderShapeStyle`
`[R Render/Plan.hs]`. The host therefore synthesises no `<marker>` and no
`<defs>`, which is exactly what the render Haddock requires.

Geometry, with `w` the connector stroke width in slide units, `p` the endpoint,
`u` the outward unit direction of the adjacent leg and `n` its left normal.
Scale and reference offsets are the legacy marker catalog: box `0..6`,
`markerWidth = markerHeight = 6`, `refY = 3`, per-tip `refX`
(`to 5`, `latex 5.5`, `stealth 5.5`, `bar 4.6`)
`[L render/slide.ts` marker definitions, transcribed in the legacy report`]`.
Let `L = 6w` be the box length, `H = 3w` the half height, and `back = refX × w`.

| Tip | Geometry | Paint |
| --- | --- | --- |
| `to` | `RenderPath` from `p − back·u + H·n` to `p + (L − back)·u` to `p − back·u − H·n`, open | `StrokedRenderArrowTip` with the connector stroke, round join |
| `latex` | `RenderPolygon` over `p + (L − back)·u`, `p − back·u + H·n`, `p − back·u − H·n` | `FilledRenderArrowTip`, fill = stroke colour, no stroke |
| `stealth` | `RenderPolygon` over `p + (L − back)·u`, `p − back·u + H·n`, `p − back·u + (2w)·u`, `p − back·u − H·n` | `FilledRenderArrowTip`, fill = stroke colour |
| `bar` | `RenderPath` from `p + H·n` to `p − H·n`, open | `StrokedRenderArrowTip` with the connector stroke, butt cap |

`u` for the end tip is the direction of the last leg; for the start tip it is the
reverse of the first leg's direction. Because the tip is derived from the same
clipped endpoints as the path, it always sits on the line and re-orients when a
node moves. A connector whose direction is degenerate carries
`Render.noRenderArrowTips`.

Supported tip set: `to`, `latex`, `stealth`, `bar` (section 1.5). Every other
admitted name paints no tip and records `arrow_tip_unsupported`.

### 6.5 Edge labels

Not painted in P0.1. A `\draw` statement carrying a mid-path `node[…] {…}` is
admitted for geometry as a read-only connector, and the label's exact span is
recorded as `connector_label_unsupported`. Grounding for the exclusion: the
legacy editable-connector grammar rejects any token outside its anchor/segment
set `[L tikz/connector.ts]`, so a labelled path falls to the render-only
`toPath`/`connectorPoints` ladder `[L render/slide.ts:connectorsOf]`; its label
placement depends on `pathLabelOffset`/`pathLabelTranslation` machinery that was
not transcribed, and honouring it would be invention. The label bytes are
preserved exactly and its location is visible.

### 6.6 Identity stability

`[D9]`. Today the identity is `"path-" <> show statementStart <> "-" <> show index`
(`Deck.hs:397-401`), so a coordinate rewrite that changes byte length renames
every later connector. Replacement, in `SlideBlaster.Deck.Path.connectorId`:

```text
identity = "path-" <> startNodeIdText <> "-" <> endNodeIdText <> "-" <> show occurrence
```

where `occurrence` is the zero-based count of previously admitted connectors in
the **same audience body** with the same ordered `(startNodeId, endNodeId)` pair,
in source order. Node identifiers already satisfy
`[A-Za-z_][A-Za-z0-9_-]*`, so the result is a valid `Canvas.ConnectorId` and a
valid wire element id.

Grounding: legacy connector identity is positional — the index among path
statements, carried as `data-arrow` and targeted by `deleteConnector`,
`updateConnector` and `setConnectorOptions` `[L render/slide.ts:connectorsOf]`.
The chosen form is that same idea keyed on endpoint identity instead of position,
which is strictly more stable: it is invariant under every coordinate, option,
content and length edit, and under insertion or deletion of unrelated
statements. It changes only when a connector with the *same endpoint pair* is
added or removed earlier in the body, which is a structural edit that clears
selection anyway (section 7).

A multi-hop path `(a) -- (b) -- (c)` yields `path-a-b-0` and `path-b-c-0`.

### 6.7 Follow on move or resize

`[D10]` **Decision: attached connectors follow the node during the drag preview,
using geometry computed in Haskell.** Named: *Haskell-projected preview
connector geometry*. Mid-gesture following is in scope; it is not deferred.

Rationale and implementability: every input already exists inside
`SlideBlaster.Product.Runtime.ProductV2.attemptGesturePreview` — the planned node
boxes (`plannedNodeBoxes`), the resolved drag box, and the accepted document's
connector model. The projection is a pure recomputation, so no policy moves to
JavaScript.

Exact rule:

1. On each accepted preview, build `previewBoxes = plannedNodeBoxes plan` with
   the dragged node's entry replaced by
   `Canvas.box (Canvas.dragResolvedCenter resolution) (Canvas.boxSize dragged)`.
2. Select every admitted connector on the active surface whose start or end node
   is the dragged node.
3. Resolve each of them against `previewBoxes` through the same
   `Canvas.resolveConnectorPath` and the same clipping and corner derivation used
   by the plan, so preview and committed geometry are produced by one code path.
4. If **any** selected connector fails to resolve, the preview carries an
   **empty** connector list. Partial geometry is never emitted; the host then
   keeps the last accepted connector paint for all of them.
5. The preview connector list is advisory paint only. It is not a plan, it has no
   ticket, it grants no authority, and it never enters source or history.

Wire: `show_preview` and `workspace.preview` gain
`connectors: [{identity, path, tips}]` using the same closed path and tip schema
as a connector item (section 10.3). The host draws them into the existing
`product-v2-guide-layer` sibling group `product-v2-preview-layer`, `aria-hidden`,
and clears them with `clear_preview`.

**Resize** does not have a preview in P0.1 because resize is a discrete command
(section 7.2), so there is no mid-gesture state. Committed geometry after a
resize is correct by construction: the whole surface is re-analysed, re-measured
where the request changed, and re-planned, and connector endpoints are re-derived
from the new boxes.

---

## 7. Operations

All five operations share one transaction shape and one set of laws.

### 7.0 Common transaction

```text
host command (revision-fenced)  or  pointer release
  -> App.beginCanvasEdit paint intent model
       (requires the displayed writable paint lease and the exact accepted
        document at that revision; rejects otherwise)
  -> Deck.applyDeckCanvasEdit expectedRevision frame intent document
       - expectedRevision must equal Source.snapshotRevision of the document
         source, else DeckStaleRevision                      [new in P0.1]
       - no-op check (per operation, below) -> Right document unchanged
       - build exactly one Source.mkExactReplacement with exact expected bytes
       - Source.applyExactReplacement (revision, bounds, expected bytes and the
         locality postcondition are all re-checked there)
       - analyzeDeck the successor, in full
       - verifySuccessor (7.6)
  -> App.commitCanvasSuccessor request successor model
       (changed bytes, revision +1, exact base bytes and revision, live lease)
  -> analyzeAndOffer: re-analyse, re-measure only changed requests, re-plan
```

Any failure returns `Left` and produces **no** successor state, no source
change and no history entry. `Deck.applyDeckCanvasEdit` builds **one**
replacement per operation; there is no multi-splice path in P0.1, so the
descending-offset discipline that legacy needs
`[L tikz/sourceEdit.ts:projectTikzPictureEdit]` is required only *inside* the
duplicated byte copy (7.3).

`Canvas.EditIntent` mapping:

| Operation | Intent |
| --- | --- |
| move | `MoveElement (NodeElement id) (AbsolutePlacement point port)` |
| resize | `ResizeElement (NodeElement id) sizing` where `sizing` is `FixedWidth w` or `FixedHeight h` |
| create | `InsertNode seed (AbsolutePlacement point Centre)` |
| duplicate | `DuplicateElement (NodeElement id) offset` |
| delete | `DeleteCanvasElements (NodeElement id :| [])` |

### 7.1 Move

Unchanged from P0 except for the explicit expected revision and the stronger
verification. Source transaction is W1 (section 4.1).

No-op: `nodeSyntaxPoint node == destination` **and** the requested port equals
the authored port ⇒ return the input document. `App.commitCanvasSuccessor` then
reports `CanvasEditSuccessorNoOp`, the reducer maps it to
`App.InteractionNoOp`, and no patch, revision or history entry is produced
`[R Deck.hs:185-207, App/CanvasEdit.hs]`.

### 7.2 Resize

**Modality decision.** Resize is a **discrete Haskell-owned command**, not a
pointer gesture, in P0.1. `packages/slideblaster-app/src/SlideBlaster/App/Interaction.hs`
is not modified: no new `PointerTarget`, no resize gesture phase, no second
`InteractionPolicy` callback, no `ShowResizePreview` action. Reason: adding a
handle gesture would fork the reducer, the `HostAction` set, the preview wire
and the paint path, and would put the P0-accepted drag laws at risk for a
capability whose value is the *source transaction*, not the gesture. The four
`<circle>` selection handles in
`hosts/web/src/ui/product-v2-renderer.js:renderSelection` are decoration inside
an `aria-hidden` overlay; because they imply a drag that does not exist, I2 must
either remove them or give them a documented non-interactive appearance
(section 8). Handle-drag resize is recorded as a deferral (section 14).

The affordance is an accessible width and height field in the host, whose typed
value is transported as a raw user fact exactly as the source textarea already
is. Haskell owns validation, unit conversion, slot eligibility and the inverse.

Source transaction is W2 or W3 (section 4.1): one replacement over the numeric
lexeme only, preserving the authored unit suffix byte-for-byte.

Rejections: `DeckResizeSlotAbsent` (no literal lexeme in the node's own option
list), `DeckResizeSlotAmbiguous` (`minimum size` owns both axes),
`DeckResizeNotRepresentable` (converted value is not a terminating decimal in the
authored unit), `DeckNodeNotWritable` (placement is not a direct coordinate).

No-op: requested value equals `lengthSlotValue` exactly (compared in slide
units, so `26mm` and `2.6` are the same value) ⇒ return the input document; no
patch, revision or history entry.

### 7.3 Duplicate

Intent `DuplicateElement (NodeElement id) offset` with
`offset = Canvas.vector (1/2) (−1/2)` chosen by Haskell, not the host.

Source transaction:

1. `copy = bytes(nodeSyntaxStatement node)` — the whole `\node … ;`, including
   its comments, option spelling, order and interior whitespace.
2. Mint `fresh`: the first unused `<originalId>-copy`, `<originalId>-copy-2`,
   `<originalId>-copy-3`, … not present as a node id **anywhere in the deck** and
   not occurring as a byte substring of any read-only region of this body.
   Exhaustion after 999 attempts is `DeckIdentityExhausted`.
3. Rewrite inside `copy`, applying edits in **descending** offset order so
   earlier offsets stay valid: first the y lexeme, then the x lexeme, then the id
   lexeme. Offsets are the CST spans rebased by `−start(statementSpan)`.
   Coordinates become `point + offset`, rendered with `renderRational`; a
   non-terminating result rejects with `DeckProjectionRejected`.
4. One replacement: zero-width span at `end(nodeSyntaxStatement node)`,
   `expected = ""`, `value = eol <> rewrittenCopy` where `eol` is the inferred
   line ending `[R Deck.hs:inferredEol]`.

Eligibility: placement must be `DirectCoordinate` (`DeckNodeNotWritable`
otherwise), because a relative or computed copy has no coordinate to offset.

No-op: none. Duplicate always changes bytes.

### 7.4 Create

Intent `InsertNode seed (AbsolutePlacement (point 8 (9/2)) Centre)`.

Source transaction: one zero-width replacement immediately after the end of the
**last admitted statement region** of the active audience body, or at
`start(slideBodySpan)` when the body has no region, with
`expected = ""` and

```text
value = eol <> "\node[anchor=center, text width=40mm] (node-N) at (8,4.5) {New node};" <> eol
```

`node-N` is the first unused `node-1`, `node-2`, … by the same rule as step 2 of
7.3, mirroring the accepted `slide-N` policy `[R Deck.hs:nextSlideId]`. The
inserted spelling is deliberately inside the P0.1 subset so the created node is
immediately writable, measurable and verifiable: `anchor=center` is a recognised
anchor, `text width=40mm` is a literal resize slot, and `New node` is in-subset
content. The slide centre `(8, 4.5)` is used unconditionally; P0.1 performs no
overlap avoidance, because a free-space search would need geometry the command
does not have and would make the insertion non-deterministic.

No-op: none.

### 7.5 Delete

Intent `DeleteCanvasElements (NodeElement id :| [])`.

Source transaction: one replacement whose span is

```text
span  = [ start(statementSpan) , end(statementSpan) )
        extended forward over any run of spaces and tabs immediately following
        end(statementSpan) that is terminated by one line ending, in which case
        that line ending is included; otherwise not extended at all
expected = bytes(span)
value    = ""
```

The backward direction is never extended, so the preceding comment line and its
indentation survive untouched.

**Connector-reference rule.** Today an unresolved connector endpoint makes the
whole deck syntax-only (`Deck.hs:329`), so a naive delete would blank the
document. Two independent measures apply:

1. Admission changes (section 14, item U1): a connector whose endpoint names a
   non-admitted node is no longer fatal. It is not admitted, and it produces a
   `ConnectorEndpointMissing` read-only region record for its statement span. A
   document can therefore never be blanked by a dangling endpoint.
2. Delete is nevertheless **blocked** when the node is referenced, so that the
   user is told rather than silently losing arrows. Delete is offered only when
   both hold:
   - no admitted connector on that surface names the node as start or end;
   - the node's identifier text does not occur as a byte substring inside any
     read-only region span of that audience body (this catches `\foreach`
     bodies, `scope` contents, `\path` statements and computed placements that
     reference the node).
   Otherwise the projector returns
   `DeckDeleteBlocked id <first referencing span>` and the host surfaces the
   reason with a link to that span. Cascading delete of referencing statements is
   deliberately deferred (section 14).

No-op: none. A delete of an absent node is `DeckTargetMissing`, not a no-op.

### 7.6 Pre-commit verification

`SlideBlaster.Deck.Inverse.verifySuccessor` replaces the weaker
`parentIdentityExceptBody` check (`Deck.hs:662-671`, which compared only frame
id, title and note presence). Every operation runs all of it:

1. `Document.documentSemantic successor` is `Just`, else `DeckVerificationRejected`.
2. The active slide exists in the successor and its `slideFrameId`, `slideTitle`,
   `slideMetadataSpan` bytes, `slideBodyDelimiterSpans` bytes and note **bytes**
   are unchanged.
3. The **intended semantic delta** holds for the operation:
   - move: the target node's point equals the destination, its port equals the
     requested port, and its coordinate slot is still writable;
   - resize: the target node's slot value for that axis equals the requested
     value, in slide units, and the authored unit suffix bytes are unchanged;
   - duplicate: the successor contains the original node with an unchanged
     point, plus exactly one additional node whose id is `fresh` and whose point
     is `point + offset`;
   - create: the successor contains exactly one additional node whose id is the
     minted id, whose point is `(8, 4.5)`, whose port is `Centre`, and whose
     coordinate slot is writable;
   - delete: the target node is absent.
4. **Every other admitted element in that slide is unchanged.** The successor's
   admitted node list, minus the intended addition or removal, must equal the
   predecessor's under a comparison of `(id, placement, port, outline,
   content, property patch, length slot values)`; and its admitted connector
   list must equal the predecessor's under `(id, start, startPort, end, endPort,
   segment, property patch)`, minus the intended change. This is the check the
   analyst identified as missing and it is what makes statement-level operations
   safe.
5. Every other slide's whole-span bytes are identical.
6. The read-only region record set of that slide is unchanged, except for the
   entries whose spans lie wholly inside an inserted or removed statement.

Undo and redo are unchanged: each committed operation is exactly one
`App` history transition, so `undo` restores the exact prior bytes and the prior
active frame and `redo` restores the exact generated bytes
`[R docs/specs/str-007-implicit-canvas-slide-trial.md]`. The runtime sets
`productUndoPreferredFrame` and `productRedoPreferredFrame` to the active frame
for every canvas command, exactly as `newSlide` already does. Selection is
cleared after create, duplicate and delete, because element identity may shift;
it is retained after move and resize.

---

## 8. Unsupported and read-only presentation

Two product-owned surfaces. Authored colours are never overridden; only the
chrome below is product-owned, and only it carries a contrast guarantee.

### 8.1 On the canvas

- A **writable** node keeps the existing hit target: a `<button
  class="product-v2-node-target">` with `aria-label` `"<accessible name>"` and
  `aria-pressed`. The accessible name is the plan's
  `Render.Labelled` text, which is `Render.renderContentPlainText` of the node's
  content truncated to 120 characters, falling back to
  `"Source-backed node <id>"` for an empty body.
- A **read-only** node receives **no hit target element at all**: no button, no
  pointer handler, no drag projection. Its shape item is painted with the
  additional class `product-v2-node-readonly`
  (`stroke-dasharray: 0.12 0.08`, stroke `#6b7180`) inside the `aria-hidden`
  geometry layer. Keyboard users reach it through the notes panel (8.2), not
  through the canvas, so no focusable element ever announces an action it cannot
  perform.
- A node with one or more **rendering limitations** keeps its hit target and
  gains the class `product-v2-node-limited` on its shape item plus a
  visually-hidden suffix in its accessible name:
  `", <n> rendering limitations"`. The detail is in the panel.
- Selection chrome is unchanged except that the four decorative
  `<circle class="product-v2-selection-handle">` elements must stop implying a
  drag: I2 either removes them or renders them at `r="0.05"` with
  `fill:none; stroke:#6b7180`, and the enclosing overlay keeps `aria-hidden`.
- The preview connector layer (`product-v2-preview-layer`) is `aria-hidden`.

### 8.2 The source-notes panel

One new region in `hosts/web/index.html`, adjacent to the status bar:

```html
<section class="source-notes" aria-labelledby="source-notes-heading">
  <h2 id="source-notes-heading">Read-only source and limitations</h2>
  <p class="visually-hidden" role="status" aria-live="polite" id="source-notes-count"></p>
  <ul class="source-notes-list" aria-label="Read-only source regions">…</ul>
  <ul class="source-notes-list" aria-label="Rendering limitations">…</ul>
</section>
```

- Each entry is a `<button type="button">` whose accessible name is
  `"<human reason> at line <n>"`, with `aria-describedby` pointing at a sibling
  `<span>` carrying the exact detail text (for example the offending option
  spelling). Reason text is a closed host-side lookup keyed by the wire reason
  token; it is presentation wording, not policy.
- Activating an entry focuses `#source`, sets `selectionStart` and
  `selectionEnd` from the note's UTF-16 offsets, and scrolls the selection into
  view. No source is modified.
- Haskell supplies **both** the exact byte span and the equivalent UTF-16
  code-unit span (section 10.2) so the host never converts encodings. Line and
  column are also supplied, one-based, so the host never counts lines.
- `#source-notes-count` announces `"<n> read-only regions, <m> rendering
  limitations"` on each change, using the same polite-status pattern as the
  existing `product-v2-guide-status`.
- Focus order is document order; each list is a plain list of buttons, so
  keyboard traversal is Tab and Shift+Tab with no custom key handling.

### 8.3 Contrast

Non-text chrome meets WCAG 2.2 SC 1.4.11 (3:1) against the `#fff` node surface:
read-only stroke `#6b7180` is 4.6:1, selection `#4f5bd5` is 6.1:1, limitation
badge stroke reuses `#6b7180`. Panel text uses `--ink` `#1b1e28` on `--surface`
`#fff`, 15.6:1, meeting SC 1.4.3 comfortably. Authored `fill=` and `text=`
colours are the author's responsibility and are never silently altered; when a
node has an authored `text=` colour the panel does not claim a contrast
guarantee for it.

---

## 9. Failure modes

Every row is atomic: no source bytes change and no history entry is created
unless the row says otherwise.

| Failure | Detection point (file, function) | User-visible result | Source effect | History effect |
| --- | --- | --- | --- | --- |
| stale revision | `SlideBlaster.Deck.Inverse.applyDeckCanvasEdit` (`DeckStaleRevision`), and independently `Product/Runtime/ProductV2.ensureRevision`, and `App.CanvasEdit.beginCanvasEdit` (`CanvasEditAcceptedDocumentStale`) | error `stale_revision` or `deck_projection_rejected`; status "Couldn't update the presentation"; the editor keeps its current paint | none | none |
| stale paint | `Product/Runtime/ProductV2.capturePaintFence` (`App.InteractionAuthorityUnavailable`) | error `gesture_stale_paint`; the gesture does not start | none | none |
| stale gesture | `App.Interaction.reducePointerEvent` (pointer-id mismatch), then `Product/Runtime/ProductV2.pointerFailure` | the delayed event is ignored; the active gesture is unaffected | none | none |
| stale measurement | `Product/Runtime/ProductV2.provideMeasurements` ticket check, and `Render.Measurement.completeMeasurements` (`StaleMeasurementResult`) | error `measurement_stale`; the pending batch stays pending | none | none |
| measurement unavailable | host `measureBatch` failure → request `measurement_unavailable`, recorded by `Product/Runtime/ProductV2.measurementUnavailable`; and `Engine.CommonTikz.renderPresentationSurfacePlan` (`CommonTikzRenderMeasurementMissing`) if a plan is attempted | no render offer on any surface; `authority` `"none"`; status "Can't lay out this slide: text measurement is unavailable"; source pane, navigator and notes panel remain fully populated; **no fabricated geometry** | none | none |
| no-op | `SlideBlaster.Deck.Inverse.applyDeckCanvasEdit` no-op check, confirmed by `App.CanvasEdit.commitCanvasSuccessor` (`CanvasEditSuccessorNoOp`) | for a drag, `preview.outcome` `"no_op"` and the gesture ends cleanly; for a command, kind `node_resized` with `outcome` `"no_op"` | none | none |
| unsupported construct | `SlideBlaster.Deck.Canvas.scanBody` → `SlideBlaster.Deck.Region.note` | the region is listed in the read-only panel with its reason and line; nothing is painted for it | bytes preserved exactly | none |
| unsupported option | `SlideBlaster.Deck.Options.readItems` → `RenderingLimitationNote` | the node paints, is still coordinate-writable, is marked limited, and the item is listed in the limitations panel | bytes preserved exactly | none |
| ambiguous | `SlideBlaster.Deck.Options.readItems` (`minimum size`, two `anchor=`), `SlideBlaster.Deck.Node.referenceOrder` (relative cycle) | for `minimum size`: resize disabled with reason `slot_ambiguous`. For two `anchor=`: whole document syntax-only, `deck.node_anchor_unsupported`, retained P0 law | bytes preserved exactly | none |
| malformed | `SlideBlaster.Deck.Parent` (`deck.*`), `SlideBlaster.Deck.Canvas.scanBody` (`deck.unclosed_statement`, `deck.unbalanced_environment`) | syntax-only document: one diagnostic, `readiness` `"syntax_only"`, no render offer, last-good paint retained inertly | bytes preserved exactly | none |
| relative cycle | `SlideBlaster.Deck.Node.referenceOrder` | the cyclic node is not admitted and is listed with reason `relative_cycle`; every other node and connector on the slide still renders; the document is **not** blanked | bytes preserved exactly | none |
| projection failure | `SlideBlaster.Deck.Inverse` (`DeckProjectionRejected`, `DeckPlacementUnsupported`, `DeckNodeNotWritable`, `DeckResize*`, `DeckDeleteBlocked`, `DeckIdentityExhausted`), `SlideBlaster.Source.Edit.applyExactReplacement` (`DeckSourceRejected`) | for a drag, `pointer_preview_rejected` and the reducer's cancellation law ends the gesture; for a command, the specific error code with a human reason | none | none |
| verification failure | `SlideBlaster.Deck.Inverse.verifySuccessor` (`DeckVerificationRejected`), and independently `App.CanvasEdit.commitCanvasSuccessor` (`CanvasEditSuccessorBaseMismatch`, `CanvasEditSuccessorRevisionInvalid`, `CanvasEditCompletionStale`) | error `canvas_verification_rejected` / `deck_projection_rejected`; the displayed paint is untouched | none | none |

---

## 10. Target boundaries and the frozen protocol delta

### 10.1 Boundaries

**Shared portable Haskell** (native GHC and GHC-Wasm; no `GHC.Wasm.Prim`, no DOM
or browser package, no native process or C-FFI package): `slideblaster-source`,
`slideblaster-document`, `slideblaster-canvas`, `slideblaster-presentation`,
`slideblaster-render`, `slideblaster-deck`, `slideblaster-engine`,
`slideblaster-app`, `slideblaster-protocol`, `slideblaster-product-runtime`. All
TikZ reading, option and style semantics, content lowering, relative resolution,
box computation, layout, clipping, routing, arrow-tip geometry, provenance,
inverses, verification, history, command availability and the closed wire
vocabulary live here.

**Wasm adapter** (`apps/slideblaster-web-wasm`): serialises the pure runtime in
one forced `MVar` and exports `sb_product_v2_dispatch`. **No change is expected**;
the single export carries every new command.

**Host JavaScript** (`hosts/web`): validates the closed projection, transports
raw browser facts (pointer samples, typed text, typed numbers, measured
extents), invokes browser capabilities (pointer capture, focus, selection,
`document.fonts.ready`, DOM measurement) and paints. It owns the zoom and pan
transform, which is local presentation state and appears in no protocol field.
It contains no TikZ knowledge, no unit table, no colour table, no wrap decision,
no box arithmetic, no identity minting, no revision arithmetic, no availability
policy and no source mutation.

`adapters/slideblaster-adapter-web/src/SlideBlaster/Adapter/Web/Port.hs` and
`hosts/web/src/capabilities/measure.js` are **unchanged and unused** by P0.1: the
`MeasurementPort` is an `IO` capability for a different composition, while the
Product/2 measurement path is the pure protocol round trip in 10.4.

### 10.2 Shared value schemas

Every number that carries geometry is an **exact number string** matching
`^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+)|\/([1-9][0-9]*))?$`, validated by
`hosts/web/src/protocol/product-v2.js:exactCoordinate` (unchanged). All lengths
are slide units. All identifiers match `^[A-Za-z_][A-Za-z0-9_-]*$`.

```jsonc
point   = { "x": exact, "y": exact }
size    = { "width": exact, "height": exact }          // both > 0
box     = { "center": point, "size": size }
surface = { "frame": ident, "kind": "audience" | "notes" }
element = { "kind": "node" | "connector" | "group", "id": ident }
identity= { "surface": surface, "element": element, "part": nonEmptyText }

colour  = { "r": 0..255, "g": 0..255, "b": 0..255, "a": 0..255 }

paint   = { "kind": "none" }
        | { "kind": "solid", "colour": colour }

stroke  = null
        | { "kind": "solid",
            "colour": colour,
            "width": exact,                            // > 0
            "dash":  [exact, ...],                     // [] means solid
            "cap":   "butt" | "round" | "square",
            "join":  "miter" | "round" | "bevel" }

shapeStyle = { "paint": paint, "stroke": stroke, "opacity": exact }  // 0..1

cornerRadii = { "topLeft": exact, "topRight": exact,
                "bottomRight": exact, "bottomLeft": exact }          // each >= 0

outline = { "kind": "rectangle", "box": box, "cornerRadii": cornerRadii }
        | { "kind": "ellipse",   "box": box }
        | { "kind": "polygon",   "points": [point, point, point, ...] }  // >= 3

path    = { "start": point,
            "segments": [ { "kind": "line_to", "to": point }, ... ],  // >= 1
            "closed": false }                                        // always false in P0.1

tip     = null
        | { "kind": "stroked", "path": path,      "stroke": stroke }
        | { "kind": "filled",  "outline": outline, "style": shapeStyle }

typography = { "sizeUnits":  exact,                    // > 0, slide units
               "lineSpacing": exact,                   // > 0
               "weight":     "normal" | "bold" | { "number": 1..1000 },
               "posture":    "upright" | "italic",
               "decoration": "none" | "underline" | "strike",
               "colour":     colour,
               "horizontal": "left" | "centre" | "right",
               "vertical":   "top" | "middle" | "bottom",
               "family":     null }                    // always null in P0.1

contentRole = "inline" | "paragraph" | "strong" | "emphasis" | "code"
            | "quote" | "unordered_list" | "ordered_list" | "list_item"

content = { "kind": "text", "text": text,
            "typography": typography,
            "highlight": null | colour }
        | { "kind": "container", "role": contentRole, "children": [content, ...] }
        | { "kind": "break" }

span    = { "byteStart": uint, "byteEnd": uint,        // parent bytes, half-open
            "utf16Start": uint, "utf16End": uint,      // parent UTF-16 code units
            "line": uint, "column": uint }             // one-based, of byteStart
```

`content` is the only lowering of `Render.RenderContent` P0.1 emits.
`Render.RenderLink`, `RenderMath`, `RenderTableContent`, `RenderInlineOverlay`
and `RenderContentImage` are **rejected** by
`Product/Runtime/ProductV2.contentValue` with `render_rejected`; the Deck reader
never produces them (math becomes a `code` container, section 1.6).

### 10.3 Render item kinds

The two P0 item kinds `"rectangle"` and `"line"` are **replaced**. Renaming is
required because both shapes change beyond recognition, and a name that says
`rectangle` while carrying an ellipse would be a lie.

```jsonc
// ObjectLayer only. One per admitted node. part = "shape".
nodeItem = {
  "kind": "node",
  "identity": identity,                  // element.kind === "node"
  "outline": outline,
  "style": shapeStyle,
  "hitTarget": box,
  "accessibleName": null | text,
  "limitationCount": uint,
  "interaction": { "kind": "inert" }
                 | { "kind": "select_element", "surface": surface, "element": element }
}

// ContentLayer only. At most one per admitted node with content. part = "body".
contentItem = {
  "kind": "content",
  "identity": identity,                  // element.kind === "node"
  "box": box,
  "content": content,
  "accessibleName": null | text,
  "interaction": { "kind": "inert" }     // always inert
}

// ConnectorLayer only. One per admitted connector. part = "path".
connectorItem = {
  "kind": "connector",
  "identity": identity,                  // element.kind === "connector"
  "path": path,
  "stroke": stroke,                      // never null for a painted connector
  "tips": { "start": tip, "end": tip },
  "interaction": { "kind": "inert" }     // always inert in P0.1
}
```

Closed validator laws for `hosts/web/src/protocol/product-v2.js:validateItem`,
all of which must be enforced:

1. `identity.surface` equals the plan surface.
2. `kind === "node"` requires `identity.element.kind === "node"` and
   `identity.part === "shape"`; `interaction` is either `inert` **or**
   `select_element` matching `identity.surface` and `identity.element`. **This
   admits the inert read-only node item and closes `[D8]`**: today
   `validateItem` requires `select_element` for a `"rectangle"`, so the first
   read-only node would throw `ProductV2WireError` and blank the editor.
3. `kind === "content"` requires `identity.element.kind === "node"`,
   `identity.part === "body"` and `interaction.kind === "inert"`.
4. `kind === "connector"` requires `identity.element.kind === "connector"`,
   `identity.part === "path"` and `interaction.kind === "inert"`.
5. A `content` item must appear only in a `content` layer; a `node` item only in
   an `object` layer; a `connector` item only in a `connector` layer.
6. `projectedNodeIds` collects ids from every `kind === "node"` item, regardless
   of outline kind, so the selection law still holds.
7. Bounds: `path.segments` at most 64; `polygon.points` at most 256;
   `content` nesting depth at most 16 and at most 4096 nodes per item;
   `stroke.dash` at most 8 entries.

`Product/Runtime/ProductV2.plannedNodeBoxes` is derived from the node item's
`hitTarget` box (that is, from `Render.RenderBoxHitRegionView`), **not** from a
rectangle outline view, so drag and snapping keep working for ellipse and
polygon outlines. `Engine.CommonTikz.nodeItem` therefore sets
`renderItemHitRegion = Render.renderBoxHitRegion box`.

### 10.4 Measurement request and reply

**Workspace field** (Haskell → host), nullable:

```jsonc
"measurement":
    null
  | { "state": "pending",
      "ticket": uint,
      "basisPxPerUnit": 100,
      "requests": [
        { "element": identity,             // part === "body"
          "mode": { "kind": "intrinsic" }
                | { "kind": "within", "width": exact },   // width > 0
          "content": content },
        ...
      ] }
  | { "state": "unavailable",
      "ticket": uint,
      "reason": "host_unsupported" | "fonts_unavailable"
              | "measure_failed" | "results_invalid" }
```

`basisPxPerUnit` is a literal `100`, present so the host reads the basis from the
protocol rather than from a local constant. At most 4096 requests per batch.

**Reply requests** (host → Haskell):

```jsonc
{ "protocol": "slideblaster.product/2",
  "command": "provide_measurements",
  "ticket": uint,
  "results": [
    { "element": identity, "width": exact, "height": exact },   // >= 0
    ...
  ] }

{ "protocol": "slideblaster.product/2",
  "command": "measurement_unavailable",
  "ticket": uint,
  "reason": "host_unsupported" | "fonts_unavailable" | "measure_failed" }
```

`width` and `height` are decimals with at most six fractional digits, rounded
**up**, in slide units, produced by dividing the measured CSS pixels by exactly
`basisPxPerUnit`. Exactly one result per request, no extras: Haskell enforces
this through `Render.completeMeasurements`.

Success kinds: `measurements_provided`, `measurement_rejected`.

### 10.5 Canvas commands

```jsonc
{ "protocol": "slideblaster.product/2",
  "command": "canvas_command",
  "revision": uint,
  "operation":
      { "kind": "create_node" }
    | { "kind": "duplicate_node", "nodeId": ident }
    | { "kind": "delete_node",    "nodeId": ident }
    | { "kind": "resize_node",    "nodeId": ident,
        "axis": "width" | "height", "value": exact }   // value > 0, slide units
}
```

Success kinds: `node_created`, `node_duplicated`, `node_deleted`,
`node_resized`. Each success carries the ordinary workspace and a `repaint`
action, exactly as `slide_created` does.

**Availability projection**, new workspace field, never nullable:

```jsonc
"canvasCommands": {
  "create":       availability,
  "duplicate":    availability,
  "delete":       availability,
  "resizeWidth":  availability,
  "resizeHeight": availability
}

availability = { "enabled": true,  "disabledReason": null }
             | { "enabled": false, "disabledReason": reason }

reason = "source_not_ready" | "paint_not_acknowledged" | "no_selection"
       | "node_not_writable" | "slot_absent" | "slot_ambiguous"
       | "connector_reference" | "region_reference"
```

Availability is computed only by `Deck.deckCommandAvailability` and projected;
JavaScript never derives it and never sends a disabled command.

### 10.6 Source notes

New workspace field, never nullable, at most 2048 entries:

```jsonc
"sourceNotes": [
  { "id": ident,
    "kind": "read_only" | "limitation",
    "reason": reasonToken,
    "frame": ident,
    "element": null | element,
    "span": span,
    "detail": text },                    // may be "" ; at most 512 characters
  ...
]
```

`reasonToken` is exactly this closed set, in one-to-one correspondence with
`SlideBlaster.Deck.Region.NoteReason`:

```text
relative_placement_read_only  relative_target_missing   relative_cycle
computed_coordinate           style_definition          style_unresolved
foreach_expanded              scope_transformed         path_statement_unsupported
path_segment_unsupported      connector_label_unsupported
connector_endpoint_missing    arrow_tip_unsupported     arrow_tip_options_unsupported
option_key_unsupported        option_value_unsupported  shape_unsupported
colour_unsupported            content_out_of_subset     math_not_typeset
unknown_statement             notes_surface_read_only
resize_slot_absent            resize_slot_ambiguous
```

Host law: a `read_only` note may reference a frame that has no render plan; a
`limitation` note whose `element` is non-null must reference an element present
in that frame's plan **when that frame has a plan**.

### 10.7 Preview delta

`show_preview` action and `workspace.preview` each gain one field:

```jsonc
"connectors": [ { "identity": identity, "path": path,
                  "tips": { "start": tip, "end": tip } }, ... ]
```

At most 256 entries; `[]` is the fail-closed value (section 6.7). Every other
`show_preview` and `preview` field is unchanged.

### 10.8 Workspace delta, complete

`workspace` exact key set becomes:

```text
source, readiness, canUndo, canRedo, selection, authority,
renderOffer, displayedRender, pointer, preview, navigator,
measurement, canvasCommands, sourceNotes
```

Changed cross-field laws in `validateWorkspace`:

- **Removed**: `readiness === "syntax_only" && renderOffer !== null` fails —
  *kept*.
- **Removed**: `authority === "paint_pending" requires renderOffer` — *kept*.
- **Removed**: `authority === "writable" requires displayedRender` — *kept*.
- **New**: if `readiness === "ready"` then `renderOffer !== null ||
  displayedRender !== null || measurement !== null`. A ready workspace either
  offers or displays a plan, or explains why it cannot.
- **New**: if `measurement !== null && measurement.state === "pending"` then
  `renderOffer === null`.
- **New**: if `readiness !== "ready"` then `measurement === null`,
  `sourceNotes.length === 0` and every `canvasCommands` entry is disabled with
  `source_not_ready`.
- **Unchanged**: the selection, pointer and preview laws, with the addition that
  `preview.connectors` is validated whenever `preview !== null`.

### 10.9 New error codes

Added to `SlideBlaster.Protocol.ProductV2.ProductV2Error`, to `errorCode`,
`errorMessage`, and to the host `errorCodes` set:

| Constructor | Wire code | Meaning |
| --- | --- | --- |
| `ProductV2MeasurementNotRequested` | `measurement_not_requested` | No batch is pending. |
| `ProductV2MeasurementStale` | `measurement_stale` | Ticket does not match the pending batch. |
| `ProductV2MeasurementIncomplete` | `measurement_incomplete` | Missing, duplicate or unexpected result keys. |
| `ProductV2MeasurementUnavailable` | `measurement_unavailable` | The host cannot measure; recorded, no geometry produced. |
| `ProductV2NodeNotWritable` | `node_not_writable` | The node has no writable field for this operation. |
| `ProductV2ResizeSlotAbsent` | `resize_slot_absent` | No literal length lexeme in the node's own options. |
| `ProductV2ResizeSlotAmbiguous` | `resize_slot_ambiguous` | One lexeme owns both axes. |
| `ProductV2ResizeNotRepresentable` | `resize_not_representable` | The value is not a terminating decimal in the authored unit. |
| `ProductV2DeleteBlocked` | `delete_blocked` | An admitted connector or a read-only region references the node. |
| `ProductV2IdentityExhausted` | `identity_exhausted` | No collision-free generated identifier remains. |

New request constructors: `ProvideMeasurements !Word64 ![MeasurementResultValue]`,
`MeasurementUnavailable !Word64 !MeasurementFailureValue`,
`ProductV2CanvasCommand !Word64 !CanvasOperationValue`.

New success kinds added to the host `successKinds` set: `measurements_provided`,
`measurement_rejected`, `node_created`, `node_duplicated`, `node_deleted`,
`node_resized`.

`packages/slideblaster-protocol/src/SlideBlaster/Protocol/Codec.hs` and every
module under `packages/slideblaster-tikz` are **not touched** `[D7]`.

---

## 11. Test plan

Derived from the contracts above, not from the implementation. Files are exact.

### 11.1 Pure: `packages/slideblaster-deck/test/Main.hs` (I1)

Existing `demo.slide` laws are retained unchanged as P0 regression evidence.
New laws over `test/fixtures/event-ingest-review.slide`:

1. fixture bytes remain exact after analysis.
2. both slides are admitted; the deck is ready (today it is `deck.node_at`
   syntax-only, so this law is the P0.1 unblocking proof).
3. admitted node ids per slide are exactly the expected lists, and the three
   relative nodes are admitted with `RelativeCoordinate` placement.
4. `writableNodePlacement` returns `Just` for exactly the twelve
   direct-coordinate nodes and `Nothing` for `decode`, `enrich`, `overflow`,
   `sla-tag`, `depth-tag`.
5. `[above of=n]` is classified **read-only** (the removed byte sniff would have
   called it writable) and `[above=1cm]` with no `of` and no `at` is
   `ComputedCoordinateReadOnly`.
6. `\tikzset` no longer swallows the following node: `title` exists.
7. `\foreach`, `scope`, `\path` and `\end{scope}` regions do not swallow the
   statements that follow them: `sla-tag` and `depth-tag` exist as read-only.
8. style expansion: `edge-collector` resolves `stage` to `draw=blue!55!black`,
   `fill=blue!8`, `rounded corners=2pt`, `very thick`, `text width=26mm`,
   `minimum height=11mm`, `font=\small`; a reference to an undefined style yields
   exactly one `StyleUnresolved` note.
9. colour: `blue!8` is `RGB 235 235 255`; `blue!55!black` is `RGB 0 0 140`;
   `black!45` is `RGB 140 140 140`; an unknown name yields `ColourUnsupported`
   and no paint.
10. lengths: `26mm` is `13/5`; `2pt` is `127/3600` after the `PT_TO_UNITS`
    anchor for a corner radius, and `254/3613.5` for a text width; a `p/q`
    coordinate still parses.
11. orthogonal connectors are admitted with the correct `CornerOrder`; a `to`
    path is a read-only region, not a silent drop.
12. arrow tips: `-stealth` yields end tip `stealth`; `-{Latex[length=2.4mm]}`
    yields `latex` plus `ArrowTipOptionsUnsupported`; `-{Circle}` yields no tip
    plus `ArrowTipUnsupported`.
13. connector identity: `path-queue-consumer-0`; identity is byte-identical
    before and after a coordinate move of an *earlier* node (the P0 defect).
14. content: `contract` lowers to a list with `Strong` runs; `caveat` lowers to
    one `UnsupportedContent` with `ContentOutOfSubset`; `budget` yields
    `OpaqueMath DisplayMath` plus `MathNotTypeset`; an attributed tag would make
    the whole body unsupported.
15. `align=center` produces `OptionKeyUnsupported` **and** the node keeps its
    writable coordinate slot (`[D2]`, the headline law).
16. connector endpoint naming an unknown node yields `ConnectorEndpointMissing`
    and a **ready** document, not a syntax-only one.
17. move: only the two coordinate lexemes change; every comment byte is
    identical; revision advances exactly once.
18. move no-op: identical destination and port returns the input document.
19. resize width on `budget` rewrites only the numeric lexeme and preserves the
    `mm` suffix; on `edge-collector` it is `DeckResizeSlotAbsent`; on `queue` it
    is `DeckResizeSlotAmbiguous`; a `pt` slot whose conversion is
    non-terminating is `DeckResizeNotRepresentable`.
20. resize no-op: the same value in a different unit spelling is a no-op.
21. create inserts exactly one statement after the last region, mints `node-1`,
    and the successor's other admitted elements are unchanged.
22. duplicate copies the statement byte-for-byte apart from the id and the two
    coordinates, offsets by `(1/2, -1/2)`, and mints `<id>-copy`.
23. delete removes exactly the statement span plus at most one trailing line
    ending; `title` succeeds; `hot-store` is `DeckDeleteBlocked`.
24. `applyDeckCanvasEdit` with a wrong expected revision is `DeckStaleRevision`
    for every one of the five operations.
25. `verifySuccessor` rejects a hand-built successor in which an unrelated node's
    coordinate differs.
26. a malformed body (`\node (a) at (1` ) leaves all bytes intact and yields one
    diagnostic.

### 11.2 Pure: `packages/slideblaster-engine/test/Main.hs` (I1)

Existing `renderCommonTikzPlan` laws are retained to prove the frozen Product/1
wrapper still works. New laws:

1. `surfaceMeasurementBatch` emits one request per node with content, with
   `MeasureWithin` exactly for nodes carrying `text width`, and rejects a
   duplicate key.
2. `renderPresentationSurfacePlan` with a `MeasurementSet` missing one key fails
   with `CommonTikzRenderMeasurementMissing` and produces **no plan**.
3. Boxes: `width = (textWidth or contentWidth) + 2·sepX`, floored by
   `minimum width`/`minimum size`; height likewise; default `sep = 1/5`.
4. Relative resolution: `decode` sits `12mm` right of `edge-collector` with
   ports `East`/`West`; `overflow` sits `14mm` below `enrich`.
5. Layer shape: exactly `ConnectorLayer`, `ObjectLayer`, `ContentLayer`, in that
   order, and `mkRenderPlan` accepts it.
6. Outlines: `circle` lowers to `RenderEllipseView`; `rounded corners=2pt`
   lowers to non-zero `RenderCornerRadii`; `diamond` lowers to a four-point
   `RenderPolygonView`; an unsupported shape token lowers to a rectangle.
7. Stroke: a node without `draw` has `noRenderStroke`; `very thick` is
   `1.2·3/40 = 9/100`; `dashed` yields the dash array `[0.15, 0.1]`.
8. Clipping: a `Centre`-to-`Centre` straight connector between two rectangles
   starts and ends on the borders, not the centres; a compass endpoint is not
   clipped; an ellipse endpoint uses the square-root form and is deterministic
   across two runs.
9. Orthogonal: `-|` produces two `RenderLineTo` segments with the corner at
   `(end.x, start.y)`; `|-` at `(start.x, end.y)`.
10. Arrow tips: `to` is `StrokedRenderArrowTip` with three path points; `stealth`
    is `FilledRenderArrowTip` with a four-point polygon; tip direction reverses
    when the endpoints are swapped.
11. Content: a node's `ContentPrimitive` box equals its shape box, and its
    `RenderContent` contains no `RenderMath`, `RenderLink`, `RenderTableContent`,
    `RenderInlineOverlay` or `RenderContentImage`.
12. `nodeItem` hit region is `RenderBoxHitRegionView`, so a planned node box is
    recoverable for an ellipse outline.
13. `SlideBlaster.Engine.NominalMeasurement.nominalMeasurementSet` covers every
    request of a batch exactly and is stable across two runs.

### 11.3 Protocol: `packages/slideblaster-protocol/test/ProductV2Main.hs` (I2)

This is a Product/2-only test module, so `packages/slideblaster-protocol/test/Main.hs`
(which imports the frozen `SlideBlaster.TikZ`) is **not** touched.

1. `provide_measurements`, `measurement_unavailable` and `canvas_command` decode
   from their exact key sets, and reject a missing field, an extra field, a
   non-canonical exact number, an unknown `operation.kind`, an unknown `axis`,
   and an unknown `reason`.
2. Every new error code round-trips through `encodeProductV2ErrorJSON` with a
   stable code and a source-redacted message.
3. No new request carries authored bytes except the existing
   `open_source`/`replace_source` base16 fields.

### 11.4 Runtime: `packages/slideblaster-product-runtime/test/Main.hs` (I2)

Existing 17 laws retained. New laws over
`test/fixtures/event-ingest-review.slide`, using
`SlideBlaster.Engine.NominalMeasurement` as the measurer:

1. `open_source` produces `measurement.state === "pending"` with the expected
   request count and **no** render offer.
2. `provide_measurements` with the pending ticket produces a render offer for
   the active surface and populated navigator plans.
3. `provide_measurements` with a foreign ticket is `measurement_stale` and
   changes no state; with a missing key it is `measurement_incomplete`.
4. `measurement_unavailable` leaves `readiness === "ready"`,
   `authority === "none"`, every plan `null`, `sourceNotes` populated, and the
   source revision unchanged.
5. Exact reuse: after a committed drag, the new batch requests **zero** keys
   because every `MeasurementRequest` is value-equal, and the paint is offered
   in the same dispatch.
6. Editing a node's content through `replace_source` re-requests exactly the
   keys whose request value changed.
7. An inert read-only node item is projected for `decode` and the whole plan is
   accepted (the `[D8]` regression).
8. `sourceNotes` contains the expected reason multiset for the fixture, and every
   span's `utf16` and `line`/`column` values agree with the byte span.
9. `canvasCommands` availability matches `deckCommandAvailability` for: no
   selection, a writable selection, `edge-collector` (resize absent), `queue`
   (resize ambiguous), `hot-store` (delete blocked).
10. Each of `create_node`, `duplicate_node`, `delete_node`, `resize_node`
    advances the revision exactly once, records exactly one history entry, and
    `undo` restores the exact prior bytes and active frame.
11. A `canvas_command` at a stale revision is `stale_revision` and changes
    nothing; one without an acknowledged paint is rejected and changes nothing.
12. A resize no-op returns `node_resized` with no revision change and no history
    entry.
13. `preview.connectors` is non-empty while dragging `queue`, and becomes `[]`
    when a referencing connector cannot resolve.
14. Connector identity is unchanged across a committed move of an earlier node.

### 11.5 Host: `hosts/web/test/product-v2.test.js` (I2)

1. `validateItem` accepts each of `node`, `content`, `connector` in its correct
   layer and rejects each in a wrong layer.
2. `validateItem` accepts a `node` item with `interaction.kind === "inert"`
   (`[D8]`) and rejects a `node` item whose `select_element` names a different
   element.
3. Rejects `rectangle` and `line` after phase 3 of the sequencing (11.7).
4. Accepts each `outline` kind and rejects a polygon with two points, a
   non-positive size, a negative corner radius, a nine-entry dash array and a
   65-segment path.
5. Accepts the `content` tree and rejects an unknown role, depth 17, and a
   non-string text value.
6. Validates `measurement` in both states and rejects a `pending` state that
   coexists with a `renderOffer`.
7. Validates `canvasCommands` and rejects an unknown `disabledReason` and an
   `enabled: true` with a non-null reason.
8. Validates `sourceNotes` and rejects an unknown reason token, a span whose
   `byteEnd < byteStart`, and more than 2048 entries.
9. Rejects a `ready` workspace with no offer, no displayed render and no
   measurement.
10. Request builders for `provide_measurements`, `measurement_unavailable` and
    `canvas_command` emit exact key sets and reject out-of-range input.
11. `hosts/web/test/product-v2-policy.test.js`: the redacted trace of every new
    request and of the measurement reply contains no authored source bytes, no
    node content text and no span detail text.

### 11.6 End to end: `hosts/web/test/browser-smoke.js` (I2)

Real Chrome against `event-ingest-review.slide`, one sequence, zero page or
console errors:

1. Both slides render; the `architecture` surface shows 10 node boxes with real
   glyphs, 9 connectors, visible arrow tips, and at least one ellipse and one
   rounded rectangle.
2 . Exactly the expected read-only nodes carry `product-v2-node-readonly` and
   have **no** `.product-v2-node-target` element.
3. The source-notes panel lists the expected number of read-only regions and
   limitations; activating one entry focuses `#source` and selects the exact
   authored substring.
4. Drag `hot-store` through several intermediate points: attached connectors
   follow during the gesture, and on release exactly one revision is recorded,
   the two coordinate lexemes are the only changed bytes, and the committed
   connector geometry matches the preview's final geometry.
5. Undo restores the exact original bytes; Redo restores the exact edited bytes.
6. Resize `budget`'s width: the `mm` suffix survives, one revision is recorded,
   the box and its wrapped content both change, and the same resize repeated is a
   no-op with no revision change.
7. Create, then duplicate, then delete: three revisions, three undos restore the
   original bytes exactly.
8. Delete on `hot-store` is disabled and its disabled reason is announced.
9. A relative node cannot be dragged: pointer-down on its geometry produces a
   canvas target, not a node target, and no revision changes.
10. Responsive widths 1440, 820, 560 and 390 CSS px: no page overflow, and node
    geometry is unchanged because measurement uses the fixed 100 px basis.
11. The existing P0 acceptance checks (thumbnail selection, arrow navigation,
    Alt free drag, New Slide, dirty-draft race, stale rejection, zoom and pan)
    still pass.

### 11.7 Verification ladder order

`format/lint` → focused Deck test → Engine test → Protocol Product/2 test →
Runtime test → `node --test hosts/web/test/*.test.js` → Wasm packaging →
`node hosts/web/test/browser-smoke.js` → repository-wide native matrix. The
pre-existing unrelated catalog failure on `sports.camper-1` must continue to be
reported, not hidden.

---

## 12. Disjoint file ownership

Two implementation lanes with **no shared file**, plus an explicitly separate
integrator set that neither lane touches.

### 12.1 Lane I1 — shared Haskell semantics

| File | Role |
| --- | --- |
| `packages/slideblaster-deck/src/SlideBlaster/Deck.hs` | Public façade: re-exports, `analyzeDeck`, `applyDeckCanvasEdit`, `writableNodePlacement`, `insertSlideAfter`, `deckSourceNotes`, `deckNodeFields`, `deckCommandAvailability`, accessors. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Syntax.hs` (new) | CST types shared by the readers; breaks import cycles. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Cursor.hs` (new) | Byte cursor, trivia skipping, balanced and quoted scanning primitives. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Parent.hs` (new) | `deck`/`slide`/`note` grammar, raw bodies, spans, unique frames. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Canvas.hs` (new) | Statement boundary detection (1.7) and dispatch; region records. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Options.hs` (new) | Spanned option items, key/value split, lengths, colours, fonts, anchors, shapes, limitation records. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Style.hs` (new) | `\tikzset` style table and bounded expansion. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Node.hs` (new) | Node statement, placement classification, reference order and cycles, property patch, outline, length slots. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Path.hs` (new) | Endpoints, segments, arrow spec, connector identity, connector property patch. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Content.hs` (new) | Node body to `Canvas.Content`, out-of-subset rule. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Region.hs` (new) | `NoteKind`, `NoteReason`, `SourceNote`, span-to-line/UTF-16 projection. |
| `packages/slideblaster-deck/src/SlideBlaster/Deck/Inverse.hs` (new) | Five projections, span arithmetic, identifier minting, `verifySuccessor`. |
| `packages/slideblaster-deck/test/Main.hs` | Section 11.1. |
| `packages/slideblaster-engine/src/SlideBlaster/Engine/CommonTikz.hs` | Measurement batch, layout, style and outline lowering, content lowering, clipping, routing, tips. |
| `packages/slideblaster-engine/src/SlideBlaster/Engine/NominalMeasurement.hs` (new) | Labelled deterministic measurer (5.7). |
| `packages/slideblaster-engine/src/SlideBlaster/Engine.hs` | Re-export list only. |
| `packages/slideblaster-engine/test/Main.hs` | Section 11.2. |
| `packages/slideblaster-canvas/src/SlideBlaster/Canvas/Edit.hs` | One new `EditIntent` constructor (3.1). |
| `packages/slideblaster-canvas/test/Main.hs` | One law that the new constructor round-trips through `Show`/`Eq` and that `dragResolutionIntent` still yields `MoveElement`. |

**`Deck.hs` has exactly one writer.** It is split into the eleven
`SlideBlaster.Deck.*` submodules listed above, all owned by I1, so that no file
exceeds a reviewable size and so the module-level Haddock contract of each reader
is explicit. The split changes `packages/slideblaster-deck/slideblaster-deck.cabal`
(`exposed-modules`, plus `other-modules` if the submodules stay private — they
are **exposed**, because the runtime must not import them but tests and future
adapters legitimately may inspect the CST) and `PROJECT.md`; both are
integrator-owned and are listed in 12.3.

### 12.2 Lane I2 — protocol, Wasm and host

| File | Role |
| --- | --- |
| `packages/slideblaster-protocol/src/SlideBlaster/Protocol/ProductV2.hs` | New request constructors, value types, error codes (10.9). |
| `packages/slideblaster-protocol/test/ProductV2Main.hs` | Section 11.3. |
| `packages/slideblaster-product-runtime/src/SlideBlaster/Product/Runtime/ProductV2.hs` | Measurement ticket, pending batch, exact-reuse cache, canvas-command dispatch, new item/workspace projection, preview connectors. |
| `packages/slideblaster-product-runtime/test/Main.hs` | Section 11.4. |
| `apps/slideblaster-web-wasm/src/SlideBlaster/Adapter/Web/ProductV2.hs` | Expected unchanged; assigned so no one else edits it. |
| `hosts/web/src/protocol/product-v2.js` | Validators, request builders, error and success sets. |
| `hosts/web/src/ui/product-v2-renderer.js` | Outline paint, content paint, tips, read-only chrome, preview connectors; remove the dead `createIdentityLabel`. |
| `hosts/web/src/ui/measure-content.js` (new) | The mechanical DOM measurement procedure of 5.3 and nothing else. |
| `hosts/web/src/main.js` | Fixture URL, measurement round trip, canvas-command wiring, source-notes panel behaviour. |
| `hosts/web/src/product-v2-policy.js` | Redaction of the new request and workspace shapes. |
| `hosts/web/index.html` | Source-notes panel, width and height fields, create/duplicate/delete controls. |
| `hosts/web/styles.css` | New classes (8.1, 8.2). |
| `hosts/web/test/product-v2.test.js` | Section 11.5. |
| `hosts/web/test/product-v2-policy.test.js` | Redaction laws. |
| `hosts/web/test/browser-smoke.js` | Section 11.6. |

### 12.3 Integrator set

Touched by neither lane; one owner, sequenced, after both lanes are green.

| File | Change |
| --- | --- |
| `packages/slideblaster-deck/slideblaster-deck.cabal` | Eleven new exposed modules; new `data-files` fixture entry. |
| `packages/slideblaster-engine/slideblaster-engine.cabal` | New `NominalMeasurement` module. |
| `packages/slideblaster-product-runtime/slideblaster-product-runtime.cabal` | New `data-files` fixture entry. |
| `hosts/web/fixtures/event-ingest-review.slide` | Promotion, plus the two byte-identical test copies. |
| `packages/slideblaster-deck/test/fixtures/event-ingest-review.slide` | Byte-identical copy. |
| `packages/slideblaster-product-runtime/test/fixtures/event-ingest-review.slide` | Byte-identical copy. |
| `PROJECT.md` | Module map. |
| `docs/specs/str-007-implicit-canvas-slide-trial.md` | Amend the connector-endpoint law (item U1) and the subset statement. |
| `docs/specs/product-v2-protocol.md` | Measurement round trip, canvas commands, new item kinds, new workspace fields. |
| `docs/architecture/capability-map.md` | Feature-by-feature status. |
| `.META/sessions/SB2-20260727-001/SPEC.md` | Correct the false `SlideBlaster.TikZ.Adapter` sentence identified by the current-state analyst; add the new fixture identity beside the retained demo hash. |
| `.META/knowledge/` | Update the two provisional canvas notes after acceptance. |

### 12.4 Cross-lane interfaces

Each lane consumes the other only through a value frozen in this document.

| Interface | Owner | Consumer contract |
| --- | --- | --- |
| `Engine.CommonTikz.surfaceMeasurementBatch` and `renderPresentationSurfacePlan` signatures (3.2) | I1 | I2 calls exactly these; I2 never constructs a `MeasurementSet` except through `Render.completeMeasurements`. |
| `Deck.deckSourceNotes`, `deckNodeFields`, `deckCommandAvailability`, `applyDeckCanvasEdit` (3.2) | I1 | I2 projects these values and never re-derives availability, writability or notes. |
| `Deck.Region.NoteReason` ↔ `reasonToken` mapping (10.6) | I1 defines the constructors, I2 defines the tokens | The mapping is one-to-one and is asserted by a runtime test. |
| Wire schema (section 10) | this document | Both lanes code against it; neither changes it unilaterally. Any change is a design amendment. |
| `Canvas.EditIntent.DuplicateElement` (3.1) | I1 | I2 constructs it from `canvas_command`. |

---

## 13. Sequencing

The editor must never blank. The protocol change is breaking in both directions
(`exactKeys` rejects unknown fields, and the validator rejects unknown item
kinds), so the order below is a deliberate two-phase migration with an explicit
gate after each step.

| Step | Owner | Lands | Gate before the next step |
| --- | --- | --- | --- |
| S1 | I2 | `product-v2.js` accepts **both** the P0 item kinds (`rectangle`, `line`) and the P0.1 kinds (`node`, `content`, `connector`); admits an inert node item (`[D8]`); treats `measurement`, `canvasCommands` and `sourceNotes` as **optional** workspace keys; adds the new request builders, success kinds and error codes; renderer paints both shapes. No Haskell change. | `node --test hosts/web/test/*.test.js` green; browser smoke over the **unchanged** `demo.slide` green. The packaged editor still works because Haskell output is unchanged. |
| S2 | I1 | Deck split into submodules with **no behaviour change**: same admitted subset, same provenance, same inverse, `applyDeckCanvasEdit` gains its revision parameter with call sites updated by I2 in S3. | Deck and Engine suites green with the existing `demo.slide` laws unchanged. |
| S3 | I2 | Runtime adopts the new `applyDeckCanvasEdit` signature and the new engine signatures behind a temporary `NominalMeasurement`-backed `MeasurementSet`, so the plan still renders and the wire still emits the P0 item kinds. | Runtime and host suites green; the packaged editor still opens `demo.slide` and still drags. |
| S4 | I1 | Statement boundary detection, option reader, style table, region and limitation records, content reader, relative placement, connector paths and tips, connector identity. Deck output becomes rich; Engine still ignores the new data. | Deck suite green on `demo.slide` **and** on the promoted fixture's parse laws. `demo.slide` bytes and its existing laws unchanged. |
| S5 | I1 | Engine measurement batch, layout, style/outline/content lowering, clipping, routing, tips; `renderCommonTikzPlan` kept working for the frozen Product/1 codec. | Engine suite green; `renderCommonTikzPlan` laws unchanged. |
| S6 | I2 | Runtime emits the P0.1 item kinds, the measurement round trip, `sourceNotes`, `canvasCommands` and preview connectors; host measurement module wired; source-notes panel and command controls added. | Runtime, protocol and host suites green; browser smoke over `demo.slide` shows real glyphs, tips and read-only chrome. |
| S7 | I1 + I2 | The five inverse projections (I1) and their `canvas_command` dispatch and controls (I2). | Full ladder green over `demo.slide`. |
| S8 | Integrator | Promote `event-ingest-review.slide` to its three byte-identical copies, add the `data-files` entries, switch `hosts/web/src/main.js`'s fixture URL (I2 makes that one-line change under integrator sequencing). | Deck, runtime and browser suites green over the new fixture; every `demo.slide` law still green. |
| S9 | I2 | Remove acceptance of `rectangle` and `line`; make `measurement`, `canvasCommands` and `sourceNotes` **required** workspace keys; add the negative laws of 11.5 item 3. | Full ladder green. |
| S10 | Integrator | Manifests, `PROJECT.md`, spec and architecture updates, `SPEC.md` correction, knowledge notes. | Full ladder green; diff reviewed; `git diff --check` clean. |

Two properties make this safe. First, at no step does a Haskell output shape
exist that the shipped validator rejects: S1 widens the validator before S6
narrows the producer, and S9 narrows the validator only after S6. Second,
`demo.slide` remains the working fixture until S8, so every intermediate step is
demonstrable in the browser.

---

## 14. Remaining user-gated items and honest limitations

### 14.1 Items requiring product-owner confirmation

**U1 — an unresolved connector endpoint stops being fatal.**
`docs/specs/str-007-implicit-canvas-slide-trial.md` states that "unresolved
admitted connector targets … make the whole document syntax-only", and
`Deck.hs:329` implements it. This design changes that: such a connector is not
admitted, its statement becomes a visible read-only region
(`connector_endpoint_missing`), and the document stays ready. The change is
required so that a delete can never blank the document and so that a
`\draw` referencing a relatively-placed node that failed to resolve does not
destroy the whole slide. It is a change to the meaning of an unsupported
construct, which `AGENTS.md` places in the user-decision column. The integrator
must amend the spec and the product owner must confirm.

**U2 — the P0.1 supported subset itself has no accepted contract.** The legacy
analyst's decisive governance finding stands: `design/format/tikz-subset.md` is
draft, `docs/specs/slice1-tikz-subset.md` is proposed, STR-007 is provisional,
and the legacy knowledge notes describe an unmigrated tree. Section 1 is
therefore a **proposal** for the T0/T1/T2 boundary, grounded but not yet
accepted. It should be promoted to `docs/specs/` and accepted by the product
owner before it is treated as durable.

**U3 — resize modality.** P0.1 delivers resize as a discrete accessible command,
not a handle drag (7.2). If the product owner requires handle dragging, that is a
change to `SlideBlaster.App.Interaction`, the `HostAction` set, the preview wire
and the paint path, and it should be a separate slice with its own reducer laws.

**U4 — `SPEC.md` documentation conflict.** `SPEC.md` claims
`SlideBlaster.TikZ.Adapter` maps the admitted child syntax and applies the
verified inverse. That is false for the shipped path: both live in
`SlideBlaster.Deck`. `AGENTS.md` requires reconciliation before implementation.
The integrator must correct it; it is listed in 12.3 but flagged here because
`AGENTS.md` makes it a gate rather than a chore.

**U5 — new external dependencies: none.** No lane adds a Haskell package or a
JavaScript dependency. This is stated explicitly because `AGENTS.md` requires new
dependencies to be reported even when reversible.

### 14.2 Honest limitations of P0.1

1. **No typographic fidelity claim.** Section 5.8. Browser extents come from the
   host's default font stack with no embedded fonts; native extents come from a
   character-counting nominal measurer. `pdflatex` would differ.
2. **Math is not typeset.** Math source is painted verbatim in a code container
   with a visible `math_not_typeset` record (1.6). Typesetting needs a TeX-to-
   `RenderMathPresentation` lowerer that P0.1 does not have.
3. **No font family.** `\fontfamily` is recorded, not honoured, so a node that
   asks for a monospace family renders in the host default (1.2).
4. **`em` and `ex` are absolute.** They resolve against the legacy interpreter's
   10 pt baseline, not against the node's own font size, exactly as
   `[L tikz/coordinates.ts:UNIT_SCALE]` does. A node with `font=\Large` and a
   width in `em` will be narrower than TikZ would make it.
5. **Stroke widths are not physical.** `PT_TO_UNITS = 3/40` is the legacy anchor
   chosen so `thin` equals the stylesheet's `0.03`, not a real pt-to-cm
   conversion (1.2). Font sizes and lengths do use the real conversion, so a
   `0.4pt` rule and a `0.4pt` font are not the same size on screen.
6. **`minimum size` is not resizable** (4.1 W4), which diverges from the fixture
   analyst's intent for `queue`. A single-axis resize of a shared lexeme has no
   unambiguous inverse.
7. **Style-derived sizes are not resizable** (4.1 W2). A node whose width comes
   from `\tikzset` can be moved but not resized, because editing the style would
   silently resize every consumer.
8. **`pt`, `bp`, `em` and `ex` length slots are usually not resizable**, because
   the converted value is rarely a terminating decimal and the design refuses to
   round authored source (7.2).
9. **Delete is blocked, not cascading** (7.5). Deleting a connected node requires
   the user to delete its connectors first, and P0.1 offers no connector
   deletion, so a connected node cannot be removed from the canvas at all. This
   is the largest functional gap in capability 8 and it is deliberate: cascading
   deletion of statements the user did not select is a destructive multi-splice
   operation that needs its own design.
10. **Connectors are not selectable or editable.** `interaction` is always
    `inert` for a connector, so there is no connector creation, deletion,
    re-anchoring or property editing. This matches P0 and is outside the eleven
    capabilities.
11. **No multi-select and no marquee.** `App.InteractionState` carries a single
    `Maybe Canvas.NodeId`.
12. **A drag cannot re-anchor.** The destination port must equal the authored
    port (`Deck.hs:202`), so a drag never rewrites `anchor=`.
13. **Read-only nodes are not reachable from the canvas by keyboard.** They are
    reachable from the source-notes panel (8.1). This is a deliberate choice:
    projecting a focusable control that cannot act would announce an action the
    product cannot perform.
14. **Selection handles do not resize.** They are decoration and must be made to
    look like decoration (8.1).
15. **`\begin{tikzpicture}` islands remain unsupported**, per the STR-007
    refinement. A body containing one becomes a read-only region.
16. **Notes remain read-only** and are projected as an empty surface with one
    `notes_surface_read_only` record per note.
17. **Two measurement round trips on first open.** Opening a document costs one
    extra dispatch before the first paint. Subsequent coordinate-only edits cost
    none, because of exact request reuse (5.6). A content edit costs one.
18. **The ellipse clip uses one `Double` square root** (6.2). It is
    deterministic and converted exactly, but it is the only non-rational step in
    the geometry pipeline.
19. **`(a.center)` is clipped** although legacy would not clip it (6.1). The CST
    retains the implicit/explicit flag so this can be corrected without a
    re-parse.
20. **The nominal measurer's boxes differ from the browser's**, so a native test
    asserting an exact box value is asserting the nominal measurer, not the
    product's visual result. Native laws therefore assert *relationships*
    (ordering, floors, padding arithmetic, connector attachment) rather than
    absolute pixel-like values, and absolute geometry is asserted only in the
    Chrome smoke.
