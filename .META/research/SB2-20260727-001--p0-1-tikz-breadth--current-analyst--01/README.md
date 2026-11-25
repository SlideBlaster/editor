# Research artifact: p0-1-tikz-breadth (current)

- Slug: `SB2-20260727-001--p0-1-tikz-breadth--current-analyst--01`
- Session: `SB2-20260727-001`
- Agent: `current-analyst`
- Created: `2026-07-29`
- Status: `complete`

# P0.1 Core TikZ Authoring Breadth — current-state analyst inventory

Node 1 (current-state analyst). Read-only on all product code. Scope: the
governed session worktree `/home/t/Documents/slide/slideBlaster/sb2-SB2-20260727-001`,
branch `session/SB2-20260727-001`, registration baseline `cbe29eb`.

All citations are `path:line` inside this worktree at the state observed on
2026-07-29 (`git status` shows the P0 working tree with `packages/slideblaster-deck/`,
`hosts/web/fixtures/`, `hosts/web/src/protocol/product-v2.js`,
`hosts/web/src/ui/product-v2-renderer.js`, `docs/specs/product-v2-protocol.md`,
and `docs/specs/str-007-implicit-canvas-slide-trial.md` still untracked). No file
was modified. No build or test was run.

## Headline answers to the three direct questions

1. **Does the renderer paint real node text today?** No. It paints placeholder
   geometry only: one stroked SVG `<rect>` of a *constant* 2×1 canvas-unit size
   per node, plus an invisible `<button>` hit target. Node content never reaches
   the wire. `hosts/web/src/ui/product-v2-renderer.js:368` (`createRectangle`) and
   `:61-65` are the only node paint paths;
   `packages/slideblaster-engine/src/SlideBlaster/Engine/CommonTikz.hs:119-123`
   (`nodeBox`) gives every node the same `nodeSize`;
   `packages/slideblaster-product-runtime/src/SlideBlaster/Product/Runtime/ProductV2.hs:753`
   hard-codes `nodeSize = 2 × 1`. There is not even an identity placeholder in the
   DOM: `createIdentityLabel` at
   `hosts/web/src/ui/product-v2-renderer.js:389` is **dead code** — it has no
   caller anywhere under `hosts/web/`, and its CSS class
   `product-v2-source-identity` does not exist in `hosts/web/styles.css`. The only
   textual trace of a node is the accessible name
   `"Source-backed node <id>"` at `hosts/web/src/ui/product-v2-renderer.js:339`.
   The Haskell comment at `CommonTikz.hs:8-10` states this deliberately:
   "Authored mixed content remains source-authoritative and intentionally
   unpainted until exact structured measurement is available."

2. **Do connectors exist in the render plan, and are arrow tips painted?**
   Connectors exist and are painted, as plain 1-segment straight lines. Arrow
   tips are **not** painted and are not even represented in the plan:
   `CommonTikz.hs:190` sets `Render.ConnectorPrimitive path stroke
   Render.noRenderArrowTips` unconditionally. The wire schema for a connector is
   `{kind:"line", identity, start, end, interaction}` only
   (`ProductV2.hs:1051-1079`, `hosts/web/src/protocol/product-v2.js:428-436`), and
   the browser paints it with `createLine`
   (`hosts/web/src/ui/product-v2-renderer.js:377`) with no `marker-end` and no
   `<marker>`/`<defs>` anywhere in `hosts/web/src`. `->` in the fixture is parsed
   as nothing: the option bracket bytes are read and then discarded
   (`packages/slideblaster-deck/src/SlideBlaster/Deck.hs:383-408`).

3. **Which placements does Deck treat as writable vs read-only, and by which
   function?** `writableNodePlacement`
   (`packages/slideblaster-deck/src/SlideBlaster/Deck.hs:162-176`) is the single
   writability oracle. It returns `Just (Canvas.AbsolutePlacement point port)`
   iff (a) the document is semantically ready, (b) the frame and node exist, and
   (c) `nodeSyntaxWritable node` is `True`. `nodeSyntaxWritable` is computed once
   at parse time as `not (hasRelativeOption options)` (`Deck.hs:368`), where
   `hasRelativeOption` (`Deck.hs:851-862`) returns `True` (⇒ read-only) when
   either the option bracket cannot be split into top-level items
   (`topLevelOptionItems` returns `Nothing`, `Deck.hs:864-895`) or a top-level
   item's key is one of `above|below|left|right|of` **immediately followed by
   `=`**. Everything else — including `[draw, rounded corners]`,
   `[text width=7cm]`, `[rotate=-2]`, `[style=display]` — is treated as
   **writable**, because those options are parsed and then thrown away. The same
   flag drives provenance: `deckProvenance` (`Deck.hs:609-622`) emits
   `Document.DirectSlot span rule` for writable nodes and
   `Document.ReadOnly Document.MissingInverseRule (Just span)` otherwise, for the
   two field keys `DeckAudienceX`/`DeckAudienceY` (`Deck.hs:87-90`).

## Where the wired TikZ path actually lives (important architectural fact)

`packages/slideblaster-tikz` is **not** on the active Product/2 path. Its
one-node/one-connector literal reader
(`packages/slideblaster-tikz/src/SlideBlaster/TikZ/Internal/Parser.hs`) and its
`SlideBlaster.TikZ.Adapter` are reachable only from the frozen Product/1 codec
(`packages/slideblaster-protocol/src/SlideBlaster/Protocol/Codec.hs:67`,
`Render.hs:49`) and the `renderCommonTikzPlan` compatibility wrapper
(`CommonTikz.hs:38-51`). `packages/slideblaster-deck` does not depend on
`slideblaster-tikz` at all (`packages/slideblaster-deck/slideblaster-deck.cabal`
build-depends: canvas, document, presentation, source, bytestring, containers,
text; `Deck.hs:35-51` imports only `Canvas`, `Document`, `Presentation`,
`Source`).

**Documentation divergence to reconcile before implementation.**
`.META/sessions/SB2-20260727-001/SPEC.md` ("STR-007 implementation design")
states `SlideBlaster.TikZ.Adapter` "maps only admitted child syntax to the common
model and applies common absolute-centre moves through the private verified
inverse". That is false for the shipped path: the admitted child syntax, the
inverse, and the verification are all inline in `SlideBlaster.Deck`
(`Deck.hs:320-441`, `:650-660`, `:178-225`). `docs/specs/product-v2-protocol.md`
is accurate ("a format-owned child projection"), and
`docs/architecture/capability-map.md` mostly says "provisional `Deck` adapter".
Per AGENTS.md ("When two authoritative documents conflict, stop implementation
and reconcile"), the orchestrator should have the integrator correct SPEC.md
before P0.1 code lands, or the P0.1 design will inherit a wrong mental model.

## The exact TikZ subset the parser admits today

Authority: `packages/slideblaster-deck/src/SlideBlaster/Deck.hs`.

Parent (`.slide`) grammar — `parseDeck` `Deck.hs:255-282`, `parseSlide` `:284-318`:

```
deck [ "title" ] ( balanced-metadata )
( slide IDENT "title" ( balanced-metadata ) """ raw-body """
  [ note """ raw-body """ ] )+
```

Child (implicit TikZ canvas) grammar — `parseCanvasBytes` `Deck.hs:320-343`:

- statements are scanned in body order; `\node` → `parseNode` (`:345-381`),
  `\draw` → `statementEnd` + `parseConnectors` (`:383-391`), **anything else →
  skipped to its next depth-0 `;` and silently dropped** (`Deck.hs:340-342`).
- `\node` form (`parseNode`, `Deck.hs:345-381`), all parts mandatory except the
  bracket:

  ```
  \node [ balanced-options ]? ( IDENT ) at ( COORD , COORD ) { balanced-content } ;
  ```

  - `IDENT`: `[A-Za-z_][A-Za-z0-9_-]*` via `Canvas.nodeId` (`Deck.hs:352`;
    `packages/slideblaster-canvas/src/SlideBlaster/Canvas/Identifier.hs`).
  - `COORD`: signed decimal or `p/q` rational (`coordinateAt` `Deck.hs:772-777`,
    `parseRationalBytes` `:779-786`). Notably richer than the `slideblaster-tikz`
    reader; no units (`cm`, `pt`) are accepted.
  - content: one balanced `{...}` group, decoded as UTF-8, retained verbatim as
    **one flat `Text`** (`Deck.hs:362`, `nodeEntry` `:594-607`). Nested braces are
    allowed (`balancedEnd` `:472-491`), including `\[ \operatorname{commit}(s,e) \]`.
  - options: the **only** interpreted key is `anchor=` (`optionPort`
    `Deck.hs:825-849`), accepting `center|centre|north|north east|east|south
    east|south|south west|west|north west`. Zero anchors ⇒ `Centre`. An unknown
    anchor value or two `anchor=` items makes the **whole deck syntax-only**
    (`deck.node_anchor_unsupported`, `Deck.hs:363-367`). Every other option key
    is read and discarded.
- `\draw` form (`parseConnectors`, `Deck.hs:383-408`): the raw statement bytes
  are string-sniffed. If the statement contains `" to "` **or** does not contain
  `"--"`, the result is `Right []` — zero connectors, no diagnostic
  (`Deck.hs:386-387`). Otherwise **every** parenthesised token in the statement is
  taken as an endpoint (`parenthesizedTokens` `:430-441`), each parsed as
  `name[.anchor]` (`endpointFromBytes` `:410-416`, `endpointPort` `:418-428`), and
  consecutive pairs become connectors (`connectorsFromEndpoints` `:393-408`). Any
  token that is not a valid identifier (e.g. a literal coordinate `(1,2)`) makes
  the whole statement yield `Right []` silently (`Deck.hs:389-390`).
- connector identity is offset-derived: `"path-" <> show statementStart <> "-" <>
  show index` (`Deck.hs:397-401`). Because a coordinate rewrite can change byte
  length, connector IDs of *later* statements are not stable across edits.
- whole-document atomic rejections (source unchanged, `Document.syntaxOnlyDocument`):
  duplicate node ID inside one body (`Deck.hs:327`), a connector endpoint naming
  an unknown node (`:329`), duplicate slide IDs (`ensureUniqueFrames` `:503-509`),
  malformed parent structure, unclosed raw body, trailing source
  (`:445-461`, `:511-514`).

### Where unsupported syntax is preserved, and how visibly

| Construct | Preserved? | Diagnosed? | Visible to user? | Citation |
| --- | --- | --- | --- | --- |
| Unsupported node options (`text width`, `draw`, `rounded corners`, `rotate`, `style=`) | yes (bytes untouched) | **no** | **no** | `Deck.hs:347` reads then discards `options`; only `optionPort`/`hasRelativeOption` consult it |
| Relative option (`above=`, `right=` …) | yes | no | only indirectly: node is non-selectable because `nodeItem` marks it `Render.Inert` (`CommonTikz.hs:168-171`) | `Deck.hs:851-862`, `:368` |
| Non-`--` / `to` / bend paths | yes | **no** | **no** — the connector simply does not appear | `Deck.hs:386-387` |
| Orthogonal `-|`, `|-` paths | yes | no | no (silently dropped: no `--` substring) | `Deck.hs:386` |
| Any other statement (`\fill`, `\path`, `\begin{scope}` …) | yes | **no** | **no** | `Deck.hs:340-342` |
| Node content structure (Markdown/HTML/LaTeX) | yes, as one exact `Text` run | n/a | **no** (never painted) | `Deck.hs:362`, `:594-607`, `CommonTikz.hs:8-10` |
| Notes bodies | yes, as spans | n/a | rendered as an empty notes surface card | `Deck.hs:80-85`, `:583-592` |
| Parent metadata interiors | yes, as opaque spans | n/a | no | `Deck.hs:56-62`, `:265` |
| Structural failure | yes (whole source) | yes, one `Document.Diagnostic` with the whole-source span | host shows only a status string; there is no diagnostic chrome | `Deck.hs:684-700`; `hosts/web/src/main.js:showFailure` |

The trial spec is explicit that this is the intended P0 boundary
(`docs/specs/str-007-implicit-canvas-slide-trial.md`, "Deliberate exclusions").
The gap for P0.1 capability 10 is therefore not preservation (which holds) but
**visibility and diagnosis**: unsupported constructs are invisible, undiagnosed,
and indistinguishable from "not present".

## Capability-by-capability inventory

### 1. Multiple named nodes on one slide

- **Exists.** `parseCanvasBytes` loops over all `\node` statements
  (`Deck.hs:320-343`); `slideFrame` builds one `Canvas.mkPicture` from all of them
  (`Deck.hs:583-592`, `nodeEntry` `:594-607`); `renderPresentationSurfacePlan`
  emits one `RenderItem` per node (`CommonTikz.hs:64-117`);
  `plannedNodeBoxes` (`ProductV2.hs:506-521`) rebuilds the peer map for snapping.
  Duplicate IDs in one body reject atomically (`Deck.hs:327`); the same ID on
  different slides is admitted (deck test
  `packages/slideblaster-deck/test/Main.hs`, law "same node id across slides is
  admitted").
- **Real end-to-end?** Yes. The tracked fixture has 5 nodes on `opening`, 3 on
  `questions`, 2 on `finish`, and the deck test asserts readiness over the exact
  3,115-byte fixture.
- **Gap.** None for admission. The residual issue is that all of them look
  identical (see 2/3).
- **Change surface.** None required.

### 2. Real node text and structured content rendering

- **Exists only as a type.** `Canvas.Content` is rich
  (`packages/slideblaster-canvas/src/SlideBlaster/Canvas/Content.hs` exports
  `Dialect`, `Provenance`, `InlineMark`, `ContainerKind`, `ListKind`, `MathKind`,
  `TableModel`, `SourceBackedContent`, …) and `Render.Content` has a complete
  lowered vocabulary (`RenderContent`, `RenderTable`, `RenderMathPresentation`,
  `renderContentPlainText`, …). `Render.Plan` has `ContentPrimitive
  !RenderContent !Box` (`Render/Plan.hs:248`) and a `ContentLayer`
  (`Render/Plan.hs:282`).
- **What actually happens.** `Deck.nodeEntry` collapses the whole body to
  `Canvas.content [Canvas.TextRun (Canvas.CanvasProvenance Canvas.LaTeX) text]`
  (`Deck.hs:602`) — one run, dialect asserted as LaTeX regardless of actual
  Markdown/HTML content. `CommonTikz` then emits **no** `ContentPrimitive` and no
  `ContentLayer` at all: layers are exactly `ConnectorLayer` + `ObjectLayer`
  (`CommonTikz.hs:104-106`). `ProductV2.itemValue` would *reject the entire plan*
  (`ProductV2RenderRejected`) if a `ContentPrimitive` appeared, because it matches
  only `ShapePrimitive` and `ConnectorPrimitive` (`ProductV2.hs:1051-1079`), and
  `hosts/web/src/protocol/product-v2.js:406` admits only `"rectangle"` and
  `"line"`.
- **Gap.** The complete content path from `NodeSyntax.nodeSyntaxContent` to
  painted glyphs is missing, at four seams: (a) no structured reader from the
  retained body text to `Canvas.Content`; (b) no `ContentPrimitive` lowering; (c)
  no wire item kind; (d) no browser paint. Also blocking: measurement. The web
  measurement port deliberately fails closed —
  `adapters/slideblaster-adapter-web/src/SlideBlaster/Adapter/Web/Port.hs:88-96`
  `webMeasurementProvision = hostUnavailable MeasurementCapability
  "measure.render-content"` — so no measured text extent is obtainable in the
  browser today, and `renderPresentationSurfacePlan` takes no `MeasurementSet`
  argument at all.
- **Smallest honest change surface.** Two candidate shapes; this is a
  designer/user decision, not an analyst call:
  - *Deterministic Haskell-owned box + browser-owned glyph layout*: keep node
    geometry authoritative in Haskell from `text width` (see 3), add
    `ContentPrimitive` with a `RenderContent` payload, and let the browser paint
    text inside the Haskell-owned box via `foreignObject`/absolutely positioned
    HTML. Files: `CommonTikz.hs`, `ProductV2.hs` (`itemValue`), `product-v2.js`
    (`validateItem`), `product-v2-renderer.js`. No new measurement port.
  - *Real structured measurement*: implement the `MeasurementPort` in
    `adapters/slideblaster-adapter-web/.../Port.hs` plus a browser measurer, and
    thread `Render.Measurement` through `renderPresentationSurfacePlan`. Larger,
    touches `packages/slideblaster-ports`, both adapters, and the host.
  The prompt's rule "do not paint placeholder labels and call structured content
  complete" and "treat text measurement and font readiness honestly" means the
  first option must state exactly which content constructs it paints and fail
  closed (or mark read-only) outside them.

### 3. Common node options: anchors, text width, shape, fill, stroke, typography

- **Anchors: real, bounded.** `optionPort` (`Deck.hs:825-849`) →
  `Canvas.BorderPort` → `AbsolutePlacement point port` (`Deck.hs:600`) →
  `centreForPort` converts anchor+fixed size to a box centre
  (`CommonTikz.hs:125-142`) → the move inverse preserves the port exactly
  (`Deck.hs:202-203`, `:218-222`; `ProductV2.portPlacement` `:481-489`). Covered
  by deck tests ("real headline retains writable north-west anchor provenance",
  "real headline reparses to the intended retained anchor destination") and by
  `packages/slideblaster-product-runtime/test/Main.hs` ("real headline direct
  anchor survives natural and Alt/free drag"). Because node size is a constant,
  the anchor is currently *arithmetically* honoured but *visually* meaningless.
- **text width: absent.** No parse, no `Canvas.Sizing`, no effect. The type
  exists: `Sizing = ContentSized | MinimumSize | FixedSize | FixedWidth |
  FixedHeight | AspectLocked`
  (`packages/slideblaster-canvas/src/SlideBlaster/Canvas/Property.hs:269-276`) and
  `nodePatchSizing` (`Property.hs:298`). Nothing writes it: `Deck.hs:603` uses
  `Canvas.emptyNodePropertyPatch`.
- **shape: absent.** Every node is `Canvas.PrimitiveGeometry
  Canvas.RectangleOutline` (`Deck.hs:601`), lowered to
  `Render.mkRenderRectangle box Render.zeroRenderCornerRadii`
  (`CommonTikz.hs:152`), wired as `"rectangle"` with a fixed box, painted as
  `<rect>`. `rounded corners` in the fixture has no effect. `Canvas.Outline`
  supports rectangle/rounded/ellipse/arc/polygon/path/compound and
  `Render.Outline.lowerOutlineRef` exists but is unused by this path.
- **fill/stroke: absent.** `nodeItem` hard-codes
  `renderShapePaint = Render.noRenderPaint` and one shared black
  `mkRenderStroke black (1/50) solid butt miter`
  (`CommonTikz.hs:71-79`, `:155-160`). `draw` in the fixture is ignored; a node
  without `draw` is stroked anyway. The wire carries **no** style field at all
  (`ProductV2.hs:1053-1067`).
- **typography: absent.** `Canvas.Typography` (`Property.hs:239-266`, with
  `typographyWrapWidth`) and `Render.Style.RenderTypography`
  (`Render/Style.hs` exports `mkRenderTypography` + accessors) both exist; neither
  is populated or transported.
- **Gap.** Everything except `anchor=` is "a type exists". Nothing in the
  option bracket other than `anchor=` and the relative-key sniff influences any
  observable behaviour.
- **Smallest change surface.** A real option reader in `Deck.hs` producing
  `Canvas.NodePropertyPatch` + `Canvas.Sizing` + `Canvas.OutlineRef`, with an
  explicit accepted-key list and read-only marking for unknown keys; a style
  payload on the shape item in `CommonTikz.hs`; corresponding wire fields in
  `ProductV2.hs:itemValue` and `product-v2.js:validateItem`; paint in
  `product-v2-renderer.js:createRectangle`. Note `Deck.hs` is one file and would
  be the hot spot for capabilities 3, 4, 5 and 8 simultaneously — see the
  ownership warning at the end.

### 4. Absolute AND relative positioning with explicit provenance

- **Absolute: real end-to-end.** `at (x,y)` is mandatory; the two coordinate
  lexeme spans are retained (`NodeSyntax.nodeSyntaxXSpan/YSpan`, `Deck.hs:98-99`)
  and are the sole edit target (`coordinateReplacement` `Deck.hs:650-660`, which
  splices `renderRational x <> exact middle bytes <> renderRational y` over the
  combined span, so the comma and interior whitespace spelling survive).
- **Relative: not supported, only *detected*.** There is no relative placement
  in the wired path at all. `Canvas.Placement` has `RelativeNodePlacement
  !RelativePlacement` with target/side/gaps/ports and `SourceDerivedPlacement
  !SourceRef` and `GeneratedPlacement`
  (`packages/slideblaster-canvas/src/SlideBlaster/Canvas/Placement.hs:65-70`), and
  `Canvas.RelativeSide`/`defaultPortsForSide` exist (`Placement.hs:26-63`). Deck
  never constructs any of them: `nodeEntry` always emits `AbsolutePlacement`
  (`Deck.hs:600`). A node written as `\node[right=of a] (b) at (3,4) {…}` still
  gets its geometry from `at (3,4)`; the `right=` sniff only flips
  `nodeSyntaxWritable` to `False`. A node **without** `at (...)` is a hard parse
  failure (`deck.node_at`, `Deck.hs:355`) that makes the whole document
  syntax-only.
- **Provenance: real, and correctly typed.** `deckProvenance`
  (`Deck.hs:609-622`) records `DirectSlot`/`ReadOnly MissingInverseRule` per
  coordinate field. The deck test asserts read-only for three relative spellings
  (`above=other`, `above = other`, `above\t =\r\n other`) and asserts that
  relative *words inside a nested option payload or node content* do not change
  writability.
- **Latent defect for read-only nodes — must be fixed by P0.1.** A read-only node
  in a semantically ready deck produces `Render.Inert`
  (`CommonTikz.hs:168-171`) → `interactionValue Inert` → wire
  `{"kind":"inert"}` (`ProductV2.hs:1113-1120`) → the browser validator
  **rejects the whole plan**, because a `"rectangle"` item is required to carry
  `interaction.kind === "select_element"` matching its identity
  (`hosts/web/src/protocol/product-v2.js:417-423`). The tracked fixture happens to
  contain no read-only node, so the packaged host never hits this. Any P0.1
  fixture that includes a relative or otherwise read-only node will blank the
  editor with a `ProductV2WireError` unless `validateItem` and the renderer learn
  an inert node item. This is confirmed by reading only; it was not executed.
- **Gap.** (a) no relative *semantics* (no resolution, no dependency graph in the
  active path, although `Render.Layout` "node kernel executable" per
  `docs/architecture/capability-map.md`); (b) `hasRelativeOption` is a byte sniff,
  not a parse: `[above of=n]` (key `above`, next non-space byte `o`) is classified
  **writable**, which would grant drag authority to a genuinely relative node;
  (c) inert nodes break the wire; (d) read-only status is not surfaced to the user
  beyond non-selectability.
- **Smallest change surface.** `Deck.hs` (real option parse → either
  `RelativeNodePlacement` or an explicit `ReadOnly` classification with a reason),
  `CommonTikz.hs` (resolve relative placement to geometry, or fail closed with
  `CommonTikzRenderPlacementUnsupported` — note it currently fails the *whole
  plan* for any non-absolute placement, `CommonTikz.hs:119-123`),
  `ProductV2.hs:itemValue` + `hosts/web/src/protocol/product-v2.js:validateItem`
  (admit inert node items), `product-v2-renderer.js` (paint read-only nodes
  visibly read-only).

### 5. Straight and orthogonal connectors with visible arrow tips

- **Straight: real end-to-end, bounded.** `ConnectorSyntax` (`Deck.hs:117-125`) →
  `connectorEntry` builds `Canvas.mkConnectorPath (NodeAnchor a portA :|
  [NodeAnchor b portB]) [Canvas.StraightSegment] Canvas.OpenPath`
  (`Deck.hs:624-648`) → `Canvas.resolveConnectorPath` against the node box map →
  `resolvedStraightPath` → `Render.ConnectorPrimitive`
  (`CommonTikz.hs:175-212`) → wire `"line"` with exactly one `RenderLineTo`
  (`ProductV2.hs:1094-1099`) → `<line>` (`product-v2-renderer.js:377-386`).
- **Orthogonal: type only, and actively excluded.**
  `Canvas.ConnectorSegment = StraightSegment | OrthogonalSegment !CornerOrder |
  CubicSegment` and `Canvas.ResolvedSegment = ResolvedStraight | ResolvedOrthogonal
  | ResolvedCubic` exist
  (`packages/slideblaster-canvas/src/SlideBlaster/Canvas/Connector.hs:55-63`,
  `:116-120`) and `resolveConnectorPath` resolves them
  (`Connector.hs:129-…`). But: Deck never parses `-|`/`|-` (`Deck.hs:386` requires
  the literal substring `--`), Deck hard-codes `[StraightSegment]`
  (`Deck.hs:632`), `resolvedStraightPath` rejects any non-straight resolved
  segment with `CommonTikzRenderConnectorUnsupported` (`CommonTikz.hs:198-212`),
  and `pathEndpointValue` rejects any path that is not exactly one `RenderLineTo`
  (`ProductV2.hs:1094-1099`), which fails the whole plan.
- **Arrow tips: absent at every layer.** `Canvas.ArrowTip = NoArrowTip |
  NamedArrowTip !Text` and `connectorPatchStartTip/EndTip`
  (`Property.hs:279-282`, `:419-420`), plus `Render.RenderArrowTip`/`RenderArrowTips`
  (`Render/Plan.hs:209-220`) all exist. Deck emits
  `Canvas.emptyConnectorPropertyPatch` (`Deck.hs:642`); `CommonTikz.hs:190` emits
  `noRenderArrowTips`; the wire has no tip field; the SVG has no marker.
- **Gap.** Parse `[->, <-, <->]` and `-|`/`|-`; carry tips and multi-segment
  paths through plan, wire, and paint. Note also the fixture's
  `\draw[..] (canvas.east) to node[right] {verified edit} (source.east);` is
  silently invisible today (`Deck.hs:386`), which is a *good* fail-closed
  decision but an *invisible* one.
- **Smallest change surface.** `Deck.hs` (`parseConnectors` → a real path
  tokenizer producing `[ConnectorSegment]` + tip patch), `CommonTikz.hs`
  (`resolvedStraightPath` → general path lowering + tips),
  `ProductV2.hs:pathEndpointValue`/`itemValue`, `product-v2.js:validateItem`,
  `product-v2-renderer.js:createLine` (+ `<defs><marker>` and `styles.css`).

### 6. Connector geometry updating when an attached node moves

- **Real end-to-end for straight node-anchored connectors.** Geometry is derived,
  never cached: after a committed move, `analyzeAndOffer` re-parses and re-plans
  from scratch (`ProductV2.hs:715-770`), `connectorItem` resolves against the
  freshly built `boxes` map (`CommonTikz.hs:107-111`, `:182-183`), and the browser
  remounts the whole surface (`main.js:mountRender`). Endpoints therefore always
  come from accepted node geometry, satisfying the prompt's "connector endpoints
  must derive from accepted node geometry and ports, not from stale browser
  pixels".
- **Gap, three parts.** (a) During a drag, the *preview* is a cloned hit-target
  ghost only (`product-v2-renderer.js:paintPreview`); attached connectors do not
  follow until release, so the user sees a detached arrow mid-gesture. (b)
  Endpoint ports come from `name.anchor` syntax only
  (`endpointPort` `Deck.hs:418-428`); a bare `(a) -- (b)` uses `Centre`/`Centre`,
  so a straight line is drawn box-centre to box-centre and is visibly *inside*
  both node rectangles. There is no border-intersection/clipping logic anywhere.
  (c) Connector IDs shift when byte offsets shift (`Deck.hs:397-401`), so a
  connector's identity is not stable across the very edits this capability is
  about.
- **Smallest change surface.** (a) `ProductV2.hs:previewValue` +
  `App/Interaction.hs` `ShowPreview` payload, `product-v2.js:validatePreview`/
  `validateHostAction`, `product-v2-renderer.js:paintPreview` — or, more cheaply,
  declare mid-drag connector following out of scope and state it. (b) `CommonTikz.hs`
  (`connectorItem`: clip resolved endpoints to the node outline). (c) `Deck.hs`
  (derive connector IDs from endpoint identities and an in-slide occurrence
  index, not byte offsets).

### 7. Selection and movement of any supported writable node

- **Real end-to-end.** Press on a painted node target → raw fact → `App.Interaction`
  reducer selects and arms (`packages/slideblaster-app/src/SlideBlaster/App/Interaction.hs`
  `pressPointer`), 2-CSS-px threshold (`movementThreshold = 2`), snapping via
  `Canvas.resolveDrag` (`ProductV2.hs:491-504`), projection via
  `Deck.applyDeckCanvasEdit`, mechanical commit via `App.commitCanvasSuccessor`
  (`packages/slideblaster-app/src/SlideBlaster/App/CanvasEdit.hs`). Authority is
  fenced by the displayed paint (`capturePaintFence` `ProductV2.hs:377-392`), and
  a snapped placement the format cannot express is retried as guide-free
  `FreeDrag` without rounding (`resolveGesturePreview` `ProductV2.hs:404-417`).
  Keyboard `Enter`/`Space` activation selects and focuses without mutating source
  (`activateNode` `ProductV2.hs:537-556`).
- **Scope of "any supported writable node".** Any node whose options contain no
  `above|below|left|right|of` immediately followed by `=`. In the tracked fixture
  that is **all 10 nodes**. A read-only node is `Render.Inert`, hence has no
  `select_element` interaction — and, per capability 4, currently breaks the wire.
- **Gap.** (a) Connectors are never selectable (`renderItemInteraction = Inert`,
  `CommonTikz.hs:194`; `product-v2.js:433` enforces it). (b) Only single
  selection exists (`stateSelection :: Maybe Canvas.NodeId`,
  `Interaction.hs`), so no multi-select or marquee. (c) The move destination port
  must equal the authored port exactly (`Deck.hs:202`), so a drag can never
  re-anchor. (d) Read-only nodes are silently unselectable with no visible
  explanation.
- **Smallest change surface.** For P0.1 as specified, essentially none is
  strictly required beyond fixing the inert-node wire hole; connector selection
  and multi-select are not in the eleven capabilities.

### 8. Resize, create, duplicate, delete for the supported node subset

- **Nothing exists end-to-end. Types only.**
  `Canvas.EditIntent` already has `ResizeElement !ElementId !Sizing`,
  `DeleteCanvasElements !(NonEmpty ElementId)`, `InsertNode !NodeSeed !Placement`,
  plus `BindNode`, `DetachNode`, `SetNodeProperties`, `ReplaceNodeContent`,
  `ReplaceNodeOutline`, `ReplaceConnectorPath`, `ReorderCanvasElement`
  (`packages/slideblaster-canvas/src/SlideBlaster/Canvas/Edit.hs:55-72`). There is
  **no** duplicate intent.
- **What the wired path accepts.** `applyDeckCanvasEdit` accepts exactly
  `MoveElement (NodeElement id) (AbsolutePlacement dest port)`; every other
  intent returns `DeckProjectionRejected` or `DeckTargetMissing`
  (`Deck.hs:183-193`). The only node-creating/deleting operation anywhere is
  `insertSlideAfter`, which inserts a whole empty *slide*, not a node
  (`Deck.hs:227-253`).
- **Interaction and protocol have no vocabulary for these.**
  `App.PointerTarget` is `PointerCanvas | PointerNode NodeId` only
  (`Interaction.hs`), so there is no resize-handle target; the four selection
  handles drawn at `product-v2-renderer.js:renderSelection` are **decorative
  `<circle>` elements inside an `aria-hidden` overlay with no pointer handling**.
  `ProductV2Request` has no create/duplicate/delete/resize command
  (`packages/slideblaster-protocol/src/SlideBlaster/Protocol/ProductV2.hs:161-173`),
  and `product-v2.js` has no such request builder.
- **Gap.** All four operations, at every layer, including the inverse
  projections: resize needs a `text width`/`minimum size` option writer (which
  needs capability 3 first); create needs deterministic node-ID minting plus
  insertion-point and indentation policy in the child body; duplicate needs an
  ID-derivation rule and an offset policy; delete needs exact statement-span
  removal plus a decision about connectors that reference the deleted node
  (today an unresolved endpoint makes the **whole deck** syntax-only,
  `Deck.hs:329`, so a naive delete would blank the document).
- **Smallest change surface.** `Deck.hs` (four inverse projectors + span
  arithmetic + verification), `Canvas/Edit.hs` (a duplicate intent, or express
  duplicate as `InsertNode` from a read seed — prefer the latter to avoid
  widening a shared type), `App/Interaction.hs` (a resize-handle pointer target
  and gesture, or a non-pointer command path),
  `Protocol/ProductV2.hs` + `ProductV2.hs` (commands + dispatch),
  `product-v2.js` (request builders + validation), `product-v2-renderer.js`
  (live handles, delete/duplicate affordances), `main.js` (toolbar/keys).
  This is the single largest block of P0.1 work.

### 9. Exact source-local edits, complete reparse, intended-semantic verification

- **Real end-to-end, for move only.** `applyDeckCanvasEdit`
  (`Deck.hs:178-225`): no-op short-circuit (`:205`), one
  `Source.mkExactReplacement` over the *combined* x..y span carrying the exact
  expected bytes (`coordinateReplacement` `:650-660`), full `analyzeDeck` of the
  successor (`:210`), then re-check of point, port, writability, and
  `parentIdentityExceptBody` (`:218-222`). `App.commitCanvasSuccessor`
  independently re-checks changed bytes, revision +1, exact base bytes/revision,
  and the live lease (`App/CanvasEdit.hs`). Rejection returns `Left`, so
  `resolveGesturePreview` yields `InteractionPreviewRejected` and the reducer's
  cancellation law ends the gesture with no source or history effect
  (`ProductV2.hs:pointerFailure` `:344-367`). `renderRational`/`terminatingDecimal`
  refuse non-terminating decimals rather than rounding (`Deck.hs:651-655`,
  `:752-758`).
- **Gaps and sharp edges.**
  - `applyDeckCanvasEdit` performs **no revision check of its own**; it reads
    the revision out of the document it was handed (`Deck.hs:653`). Staleness is
    enforced only upstream by `capturePaintFence` (`ProductV2.hs:381-384`) and
    `App.beginCanvasEdit`. `DeckStaleRevision` is used solely by
    `insertSlideAfter` (`Deck.hs:236`). Any new P0.1 caller of
    `applyDeckCanvasEdit` that bypasses `beginCanvasEdit` would silently lose the
    stale-snapshot law.
  - `parentIdentityExceptBody` (`Deck.hs:662-671`) compares only frame ID,
    title, and note presence — it does not compare the note bytes, other slides,
    or the deck header. The exact-replacement span is the real guarantee; the
    verification predicate is weaker than the doc prose implies.
  - Verification is destination-only. It does not assert that *other* nodes and
    connectors in the same slide are unchanged, which becomes material once
    edits can add or remove statements (capability 8).
  - `Deck.hs:194` (`_ -> Left DeckProjectionRejected`) is the single funnel that
    makes every non-move intent atomic today.
- **Smallest change surface.** `Deck.hs` (a shared "verify successor equals
  intended semantic delta and leaves every other admitted element identical"
  helper, plus an explicit expected-revision parameter on
  `applyDeckCanvasEdit`), and its test file
  `packages/slideblaster-deck/test/Main.hs`.

### 10. Exact preservation and visibly read-only treatment of unsupported TikZ

- **Preservation: real and strong.** `Document.documentSource` is the only output
  path; there is no printer. `analyzeDeck` returns `syntaxOnlyDocument` with the
  original snapshot on any failure (`Deck.hs:136-160`, `:684-700`). The deck test
  asserts byte identity for the fixture and for each read-only probe. Edits go
  through `Source.applyExactReplacement` with expected bytes.
- **Read-only *treatment*: partially real.** Provenance is correctly typed
  (`Document.ReadOnly Document.MissingInverseRule (Just span)`, `Deck.hs:615`) and
  the render item becomes `Render.Inert` (`CommonTikz.hs:168-171`).
- **Visibility: absent, and this is the biggest honesty gap in P0.1.**
  - There is no visual distinction between a writable node, a read-only node,
    and an unsupported statement. The renderer has no read-only styling; the
    only signal is `disabled` on the hit-target button
    (`product-v2-renderer.js:updateWorkspace`), which is invisible.
  - The wire carries no read-only/diagnostic vocabulary; per capability 4 it
    currently cannot even carry an inert node item.
  - Unsupported statements and unsupported option keys produce **no diagnostic
    at all** (`Deck.hs:340-342`, `:347`), so the user cannot locate them.
  - `Document.Diagnostic` values exist only for whole-document failures and are
    not projected into the workspace at all
    (`ProductV2.hs:workspaceValue` `:801-843` has no diagnostics field);
    `docs/architecture/capability-map.md` notes the host deliberately has
    "absent diagnostic chrome".
- **Smallest change surface.** `Deck.hs` (per-region read-only/unsupported
  records with spans and reasons, instead of silent skips), `CommonTikz.hs` (an
  explicit read-only marker item or an item-level read-only flag),
  `ProductV2.hs` (a read-only/unsupported projection in the workspace or the
  plan item), `product-v2.js` (validate it), `product-v2-renderer.js` +
  `hosts/web/styles.css` (paint it accessibly), and possibly `main.js` (a source
  gutter or list). Design must decide the vocabulary before any writer starts;
  this crosses all three groups.

### 11. A meaningful real-world TikZ fixture

- **Exists and is already close to sufficient.** `hosts/web/fixtures/demo.slide`
  is 3,115 bytes, SHA-256
  `d9d15951e4331345cb68c51dbecd3a15f3ac935190fd27c150019bc682428fd1` per
  `.META/sessions/SB2-20260727-001/SPEC.md`, byte-identical at
  `packages/slideblaster-deck/test/fixtures/demo.slide`,
  `packages/slideblaster-product-runtime/test/fixtures/demo.slide`, and
  `temp/demo.slide`. Contents: 3 slides; 10 named nodes; real mixed content
  (Markdown `**bold**`, ordered/unordered lists, an HTML `<div class="principle">`,
  `<blockquote>`, `<strong>`, `<span>`, a LaTeX display `\[ \operatorname{commit}
  (s,e)=s' \Longrightarrow \operatorname{parse}(s')=\operatorname{intent}(e). \]`,
  a `\\` line break, a U+2019 apostrophe and an em dash); options
  `anchor=north west`, `text width=4..8cm`, `style=display|lead|body|body-large|
  accent-card`, `draw`, `rounded corners`, `very thick`, `rotate=-2`; 5 `\draw`
  statements including `[->]`, `[thick, ->]`, `[paper, very thick, ->]`, and one
  deliberately unsupported `[->, dashed, bend left=35] (canvas.east) to
  node[right] {verified edit} (source.east)`; per-slide notes with backticked
  code and inline math. A second, smaller fixture exists at
  `hosts/web/fixtures/common-noncanonical.tikz` (119 bytes).
- **How much of it is currently exercised.** Nodes and 4 of 5 connectors are
  admitted; **zero** of the content, `text width`, `style`, `draw`, `rounded
  corners`, `rotate`, arrow tips, or the `to`/`bend` path is rendered. So the
  fixture is already meaningfully harder than the implementation.
- **Gap for P0.1.** It contains **no relative-placement node** and **no
  orthogonal (`-|`/`|-`) connector**, both of which capabilities 4 and 5 require;
  and it contains no construct that is *visibly* read-only. Extending it changes
  the four tracked copies and their SHA-256 in SPEC.md, and would break the
  existing byte-exact assertions in
  `packages/slideblaster-deck/test/Main.hs`,
  `packages/slideblaster-product-runtime/test/Main.hs`, and the Chrome smoke
  expectations in `hosts/web/test/browser-smoke.js` — plus, per capability 4,
  adding a read-only node **will** trip
  `hosts/web/src/protocol/product-v2.js:417-423` until that is fixed. The fixture
  analyst (node 2) and the orchestrator must sequence this: the inert-node wire
  fix has to land before, or in the same slice as, the fixture change.

## Exact change surface for P0.1

Grouped for one writer per file, no overlap.

### (i) Shared portable Haskell semantics

| File | Why it must change | Capabilities |
| --- | --- | --- |
| `packages/slideblaster-deck/src/SlideBlaster/Deck.hs` | real option parser; sizing/shape/fill/stroke/typography patches; relative placement or explicit read-only classification; real `\draw` path/tip parsing; stable connector IDs; resize/create/duplicate/delete inverses; per-region read-only records; explicit expected-revision on `applyDeckCanvasEdit`; stronger successor verification | 3,4,5,6,8,9,10 |
| `packages/slideblaster-deck/test/Main.hs` | contract-derived laws for every above change | 3,4,5,6,8,9,10 |
| `packages/slideblaster-engine/src/SlideBlaster/Engine/CommonTikz.hs` | content lowering (`ContentPrimitive`/`ContentLayer`); per-node size/shape/style from the patch; relative placement resolution; general path lowering + arrow tips; endpoint clipping to node outlines; read-only marker items | 2,3,4,5,6,10 |
| `packages/slideblaster-engine/test/Main.hs` | plan-shape laws for the above | 2,3,4,5,10 |
| `packages/slideblaster-canvas/src/SlideBlaster/Canvas/Edit.hs` | only if a duplicate intent is added instead of reusing `InsertNode` — prefer *no change* | 8 |
| `packages/slideblaster-app/src/SlideBlaster/App/Interaction.hs` | only if resize is a pointer gesture: a handle-bearing `PointerTarget` and its transitions | 8 |
| `packages/slideblaster-app/test/Main.hs` | reducer laws if `Interaction.hs` changes | 8 |
| `adapters/slideblaster-adapter-web/src/SlideBlaster/Adapter/Web/Port.hs` | only if the design chooses real structured measurement over Haskell-owned boxes (user-gated: new host protocol surface) | 2,3 |

Deliberately **not** expected to change: `slideblaster-source`,
`slideblaster-document`, `slideblaster-presentation`,
`slideblaster-canvas/{Property,Placement,Connector,Content,Outline}.hs`,
`slideblaster-render/*` (the vocabulary needed already exists),
`packages/slideblaster-tikz/*` (frozen Product/1 path — touching it is scope
creep and would also touch the frozen `Protocol/Codec.hs`).

### (ii) Protocol and Wasm boundary

| File | Why it must change | Capabilities |
| --- | --- | --- |
| `packages/slideblaster-protocol/src/SlideBlaster/Protocol/ProductV2.hs` | new closed request vocabulary for create/duplicate/delete/resize; new error codes | 8 |
| `packages/slideblaster-protocol/test/Main.hs` | codec laws for new requests/errors (note: this file also imports the frozen `SlideBlaster.TikZ`; edit only the Product/2 sections) | 8 |
| `packages/slideblaster-product-runtime/src/SlideBlaster/Product/Runtime/ProductV2.hs` | `itemValue` must gain a content item kind, per-item style, multi-segment paths, arrow tips, inert node items, and read-only projection; `renderEffect` must stop hard-coding `nodeSize`; new command dispatch | 2,3,4,5,8,10 |
| `packages/slideblaster-product-runtime/test/Main.hs` | runtime laws for new commands, atomic rejection, wire shapes | 2,3,4,5,8,9,10 |
| `apps/slideblaster-web-wasm/src/SlideBlaster/Adapter/Web/ProductV2.hs` | only if a new export is needed; the single `sb_product_v2_dispatch` export should suffice — expect **no change** | — |

### (iii) Browser host

| File | Why it must change | Capabilities |
| --- | --- | --- |
| `hosts/web/src/protocol/product-v2.js` | `validateItem` must admit content items, style, multi-segment paths, arrow tips, and **inert node items**; new request builders and error codes | 2,3,4,5,8,10 |
| `hosts/web/src/ui/product-v2-renderer.js` | paint real content, per-node size/shape/fill/stroke/typography, `<defs><marker>` arrow tips, polyline paths, visible read-only treatment, live resize handles, delete/duplicate affordances; remove the dead `createIdentityLabel` | 2,3,4,5,7,8,10 |
| `hosts/web/styles.css` | classes for content, read-only, arrow markers, handles | 2,3,5,8,10 |
| `hosts/web/src/main.js` | wire new commands/keys/toolbar; optional unsupported-region surface | 8,10 |
| `hosts/web/test/product-v2.test.js` | closed-schema laws for every new wire shape | 2,3,4,5,8,10 |
| `hosts/web/test/browser-smoke.js` | real-Chrome sequence over the P0.1 fixture | all |
| `hosts/web/fixtures/demo.slide` | add a relative/read-only node and an orthogonal connector, if the fixture analyst so decides | 4,5,10,11 |

### Files that are necessarily touched by more than one group

- `hosts/web/fixtures/demo.slide` **and** its three byte-identical copies
  `packages/slideblaster-deck/test/fixtures/demo.slide`,
  `packages/slideblaster-product-runtime/test/fixtures/demo.slide`,
  `temp/demo.slide` must change together, and `.META/sessions/SB2-20260727-001/SPEC.md`
  records their shared SHA-256. Assign **one** owner (the integrator, after the
  fixture analyst decides) for all four plus the hash, and make it a single
  ordered step — not a parallel edit.
- The read-only / unsupported / content / arrow-tip **wire vocabulary** is one
  contract spanning `ProductV2.hs:itemValue` (group ii) and
  `product-v2.js:validateItem` (group iii). These are two files, so one writer
  each is possible, but they must share one frozen schema decided in the design
  node; otherwise the browser will reject valid Haskell output. The same applies
  to `Protocol/ProductV2.hs` request shapes versus `product-v2.js` builders.
- `Deck.hs` is the single hot spot for capabilities 3, 4, 5, 6, 8, 9 and 10. It
  must have exactly one writer for the whole slice, or be split into
  `SlideBlaster.Deck.*` submodules *before* parallel work begins — splitting it
  is itself a delegated decision that changes
  `packages/slideblaster-deck/slideblaster-deck.cabal` and `PROJECT.md` (both
  integrator-owned).
- `packages/slideblaster-protocol/test/Main.hs` covers both frozen Product/1
  (importing `SlideBlaster.TikZ`) and Product/2. Restrict edits to Product/2
  sections.

## Decisions the orchestrator should resolve before any writer starts

1. **Content strategy (user-gated).** Haskell-owned geometry with
   browser-painted glyphs, versus implementing the real structured
   `MeasurementPort`. The second introduces a new host protocol surface and a
   cross-cutting capability; the first changes what "structured content
   rendering" means. `AGENTS.md` puts "adopting or replacing a cross-cutting
   runtime" and "changing a durable public package or protocol boundary" in the
   user-decision column.
2. **Which option keys become semantic, and what happens to the rest.** Today
   an unrecognised key is silently ignored (writable). Making unknown keys
   read-only is a *behaviour change* for the existing fixture: `style=display`,
   `rotate=-2`, `very thick` and `paper` would all turn the fixture's nodes
   read-only and remove the P0-accepted headline drag. This is a semantic change
   to `docs/specs/str-007-implicit-canvas-slide-trial.md`.
3. **Relative placement: resolve it, or classify it read-only with a visible
   reason.** Resolving requires a layout fold and a `RelativeNodePlacement`
   inverse; classifying requires only the read-only vocabulary. Note the current
   `hasRelativeOption` byte sniff is unsound for `[above of=n]` either way.
4. **Fixture extension** and the resulting SHA-256/spec update, sequenced after
   the inert-node wire fix.
5. **SPEC.md correction** about `SlideBlaster.TikZ.Adapter` (see above) — a
   documented conflict that AGENTS.md says must be reconciled before
   implementation.

## Confidence and limits of this report

Every claim above is from reading files in this worktree; the specific files and
lines are cited. I ran no build, no test, and no browser. Two statements are
inferences from code reading that a verifier should confirm by execution rather
than trusting me:

- that an inert (read-only) node item causes `ProductV2WireError` in
  `hosts/web/src/protocol/product-v2.js:417-423`, and
- that `[above of=n]` is classified writable by `Deck.hs:851-862`.

Both are cheap to confirm with a focused Deck/host test and should be part of
the verifier's first ladder rung.
