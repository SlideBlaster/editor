---
status: accepted
updated: 2026-07-23
---

# Vertical slice: canvas authoring semantics

This slice establishes one target-neutral Haskell vocabulary for canvas
authoring and implements two complete pure paths:

1. resolving a shape/property stack into total node properties; and
2. turning a proposed drag into an authored absolute or relative placement.

It does not claim a renderer, source parser/writer, browser gesture adapter,
measurement engine, or provenance-guided source commit. Those are consumers of
this package.

The governing references are:

- `design/decisions/0006-positioning-and-snapping.md`;
- `design/ux/positioning-snapping.md`;
- `design/decisions/0007-node-content-tri-dialect.md`;
- `design/format/node-content.md`;
- `design/decisions/0017-theme-style-layout-furniture.md`;
- `design/format/shapes-inventory.md`;
- the connector, overlay, layer-order, source-backed-unsupported, and shape
  preset notes in `knowledge/concepts/`; and
- `docs/architecture/product-model.md`.

## Boundary and authority

`slideblaster-canvas` depends only on `base`, `containers`, and `text`. It has no
filesystem, Git, DOM, JavaScript FFI, source-revision, or target-render imports.
The same package compiles under native GHC and `wasm32-wasi` GHC.

The package owns semantic values and pure authoring proposals:

```text
Picture + Theme + measurements
  -> future slideblaster-render layout

proposed Box + peer Boxes + snap policy
  -> DragResolution
  -> EditIntent
  -> future revision/provenance-guided source transaction
```

The `Picture` and `Theme` are deliberately separate. A `Picture` is one
audience or notes surface. The presentation aggregate selects one `Theme` for
the deck and exposes it to layout, presenter, and export; furniture must never
be guessed from a per-picture default.

## Public module map

`SlideBlaster.Canvas` re-exports:

| Module | Contract |
| --- | --- |
| `Identifier` | Nominal validated IDs and stable `ElementId` animation/edit targets. |
| `Geometry` | Exact rational slide units, y-up points/vectors, validated sizes, boxes, ports, relative fractions/rectangles. |
| `Overlay` | One-based steps, validated inclusive ranges, visibility, and finite final-step analysis. |
| `Content` | Recursive mixed Markdown/LaTeX/HTML content, opaque math, and source-backed unsupported placeholders. |
| `Property` | Total resolved properties and partial node/connector override layers. |
| `Placement` | Authored absolute/relative/derived/generated placement, resolved boxes, and typed layout failures. |
| `Connector` | Validated anchors and straight/orthogonal/cubic open or closed paths. |
| `Theme` | Structured style, soft master regions, safe area, and furniture. |
| `Shape` | Extensible geometry, catalog presets, and property resolution. |
| `Object` | Nodes/connectors/groups/assets/stencils, ordered entries, barriers, lookup, and safe reorder. |
| `Snap` | Binding/alignment/spacing/grid candidates and drag resolution. |
| `Edit` | Closed canvas/property intents before source projection. |

Every public module has an explicit export list and Haddock contract.

## Identity and geometry

Node, connector, group, asset resource, asset instance, stencil definition,
stencil instance, shape, custom geometry, role, region, theme, furniture,
barrier, and source-reference IDs are nominally distinct. Their common spelling
is validated as:

```text
[A-Za-z_][A-Za-z0-9_-]*
```

`ElementId` is the stable editable/animatable sum:

```haskell
NodeElement NodeId
ConnectorElement ConnectorId
GroupElement GroupId
AssetElement AssetInstanceId
StencilElement StencilInstanceId
```

An ID is never a list index or DOM identifier.

`CanvasUnit` is an exact `Rational`, not a browser pixel. `Size` is strictly
positive. `Box` is a resolved centre plus full size. `Fraction` and
`RelativeRect` validate aspect-independent theme geometry. All coordinates are
y-up. Pixel thresholds are converted by the host before entering this package.

## Authored placement versus resolved layout

`Placement` retains authored meaning:

- `AbsolutePlacement Point BorderPort`;
- `RelativeNodePlacement RelativePlacement`;
- `SourceDerivedPlacement SourceRef`, which is renderable but not assumed
  writable; and
- `GeneratedPlacement Point BorderPort` for new canvas objects before source
  projection.

Relative placement carries target node, one of eight sides, primary/secondary
gaps, target port, and own port. `ResolvedElementBox` retains both the authored
placement and its disposable `Box`.

The future layout package owns the dependency graph and must use the already
public typed failures:

- `PlacementCycle`;
- `MissingPlacementTarget`;
- `MissingMeasurement`; and
- `LayoutUnsupportedPlacement`.

This package does not persist resolved geometry.

## Picture order and barriers

`Picture` is a validated ordered sequence of `LayerEntry` values. Construction
rejects duplicate stable element IDs, dangling/duplicate group members, and
self-containing groups.

The currently generic reorder law is intentionally conservative:

- nodes, asset instances, and stencil instances may exchange with an adjacent
  reorderable object;
- connectors and groups are barriers;
- named coordinates, opaque source statements, and explicit layer barriers are
  barriers; and
- no operation jumps over a barrier.

This preserves the source-order/z-order contract without inventing a global
`z-index`. A format adapter may later prove a stronger local reorder, but the
generic operation cannot assume it.

Groups currently express explicit membership only. They do not claim automatic
containment, swimlane layout, or child movement.

## Connector subset

Anchors are:

- a node plus border/centre port;
- an absolute point;
- a relative vector with `KeepCurrent` (`+`) or `AdvanceCurrent` (`++`); or
- a source-backed unsupported anchor.

Segments are straight, orthogonal (`horizontal-then-vertical` or
`vertical-then-horizontal`), or cubic with two authored absolute control
points. `mkConnectorPath` validates:

```text
open:   segment count = anchor count - 1
closed: segment count = anchor count
```

Resolution is a left-to-right fold. Node ports use current resolved node boxes,
orthogonal elbows are derived, cubic controls are retained, and an unsupported
source anchor produces a typed failure.

## Mixed content and provenance

Every authored construct carries both:

- its `Dialect` (`Markdown`, `LaTeX`, or `HTML`); and
- its `Provenance` (`AuthoredProvenance` with a stable `SourceRef`, or
  `CanvasProvenance`).

Those are different concerns. Dialect controls inverse spelling; provenance
controls which exact source-owned construct may be edited.

`ContentNode` is recursive. Text, styled runs, transparent containers, lists,
images, includes, line breaks, and overlay content may freely nest across
dialects. `OpaqueMath` retains literal math payload without reparsing it.
`UnsupportedContent` retains a typed source handle and unsupported category;
the source/CST layer retains exact bytes. The canvas package neither discards
nor guesses unsupported content.

Parsing, source spans, canonical per-dialect writing, source splice, and hard
diagnostic admission are contract-only in other packages.

## Properties and precedence

Node and connector properties are algebraic values, not option strings.
Implemented semantic fields are:

- paint;
- stroke and line width;
- solid/dashed/dotted/custom dash;
- opacity;
- rotation;
- content/minimum/fixed/fixed-width/aspect-locked sizing;
- typed typography (family, size, weight, posture, decoration, colour,
  horizontal/vertical alignment, wrap width, line spacing);
- semantic role;
- overlay hook; and
- connector start/end tips and line join.

`NodePropertyPatch` and `ConnectorPropertyPatch` retain explicit partial
layers. Resolved properties are total.

The implemented node resolver applies:

```text
built-in fallback
  < theme base
  < selected theme role
  < shape creation preset
  < presentation/frame overrides (low to high)
  < explicit node patch
```

The explicit or preset-selected role chooses the theme role layer. Selecting a
non-default role absent from the theme returns `UnknownThemeRole`; it is not
silently relabelled.

A shape preset is creation/palette data owned by `slideblaster-catalog`, not by
the canvas model. A drop operation stamps its outline, size, content seed, and
property patch into an ordinary node. Property resolution accepts the preset as
an ordinary patch and therefore does not depend on a catalog type. The preset
identifier is not retained on the node: an equivalent hand-authored node and a
dropped preset are semantically indistinguishable. A catalog identifier must
not become a target-specific rendering case.

Gradient, shadow, flip/scale, arbitrary custom corner treatment, animation
keyframes, and transient preview layers are not implemented in this package
revision. The common product contract reserves them; adding them is an
additive property-model slice.

## Shapes are presets, not a closed enum

`OutlineRef` is extensible:

- generic rectangle/rounded rectangle/ellipse/arc primitives;
- arbitrary polygons;
- typed move/line/quadratic/cubic/arc/close paths;
- compound outlines;
- imported stencil IDs;
- custom geometry IDs; and
- source-backed unsupported geometry.

`ShapePreset` in `slideblaster-catalog` combines that outline with
label/category/search data, catalog family and priority, a node-property patch,
drop size, seed content, and source/attribution metadata.

The following status vocabulary is exact:

- **catalog-entry**: a built-in row exists in the catalog package;
- **preset-ready**: current generic geometry/properties can express it as data,
  but its built-in catalog row is not yet present;
- **preset-contract**: `OutlineRef` can carry it, but the built-in point/path or
  compound formula and catalog row are not implemented; and
- **semantic-gap**: the outline can be carried, but required multipart content
  or containment behavior is not implemented and must not be implied.

The canvas package deliberately contains zero catalog rows. Catalog breadth and
its own executable inventory live in `docs/specs/vs-shape-catalog.md`.

### Complete P0 inventory

| Family | Shape | Status | Remaining work |
| --- | --- | --- | --- |
| General | Rectangle / box | catalog-entry | None in catalog data. |
| General | Text, no border | catalog-entry | None in catalog data. |
| General | Square | preset-ready | Add alias row with equal drop dimensions. |
| General | Rounded rectangle | catalog-entry | Target renderer must honor radius. |
| General | Ellipse | catalog-entry | None in catalog data. |
| General | Circle | preset-ready | Add ellipse alias row with equal dimensions. |
| General | Diamond / rhombus | catalog-entry | None in catalog data. |
| General | Triangle | catalog-entry | None in catalog data. |
| General | Parallelogram | preset-ready | Add four-point polygon row. |
| General | Trapezoid | preset-ready | Add four-point polygon row. |
| General | Hexagon | catalog-entry | None in catalog data. |
| General | Cylinder / database | catalog-entry | Refine and renderer-test the cubic path. |
| Flowchart | Process | preset-ready | Add semantic alias of rectangle. |
| Flowchart | Decision | preset-ready | Add semantic alias of diamond. |
| Flowchart | Terminator / start-end | preset-ready | Add rounded row whose radius derives from height. |
| Flowchart | Data / I-O | preset-ready | Add parallelogram alias row. |
| Flowchart | Connector / junction dot | preset-ready | Add circle alias row. |

### Complete P1 inventory

| Family | Shape | Status | Remaining work |
| --- | --- | --- | --- |
| General | Pentagon | catalog-entry | None in catalog data. |
| General | Octagon | catalog-entry | None in catalog data. |
| General | Star | catalog-entry | Refine/test the polygon formula. |
| General | Cloud | preset-contract | Implement cloud path formula and row. |
| General | Cross / plus | preset-ready | Add 12-point polygon row. |
| General | Chamfered rectangle | preset-ready | Add 8-point polygon row. |
| Flowchart | Document | catalog-entry | Refine/test the wavy-bottom path. |
| Flowchart | Predefined process | preset-contract | Implement compound/path side bars and row. |
| Flowchart | Manual input | preset-ready | Add sloped-top polygon row. |
| Flowchart | Manual operation | preset-ready | Add rotated trapezoid row. |
| Flowchart | Preparation | preset-ready | Add hexagon alias row. |
| Flowchart | Off-page connector | preset-ready | Add home-plate polygon row. |
| Flowchart | Stored data | preset-contract | Implement path formula and row. |
| Flowchart | Delay | preset-contract | Implement D-shaped path and row. |
| Flowchart | Card | preset-ready | Add chamfered alias row. |
| Arrows | Block arrow, right | preset-ready | Add 7-point polygon row. |
| Arrows | Block arrows, left/up/down | preset-ready | Add rotated variants after target transform support. |
| Arrows | Double / bidirectional arrow | preset-ready | Add mirrored polygon row. |
| Arrows | Chevron / step | preset-ready | Add 6-point polygon row. |
| Callouts | Speech / rectangle callout | preset-contract | Implement callout path/tail and row. |
| Callouts | Ellipse callout | preset-contract | Implement ellipse-tail compound/path and row. |
| UML | Class / compartment box | semantic-gap | Define multipart content before claiming the row. |
| UML | Note / folded corner | preset-ready | Add folded polygon/path row. |
| UML | Package / tab-folder | preset-contract | Implement compound/path formula and row. |
| UML | Object / instance | preset-ready | Add rectangle plus structured underlined-title seed. |
| UML | Use-case | preset-ready | Add ellipse alias row. |
| Entity-relation | Entity / row table | semantic-gap | Define multipart row content before claiming the row. |
| Entity-relation | Attribute | preset-ready | Add ellipse alias row. |
| Entity-relation | Relationship | preset-ready | Add diamond alias row. |
| Containers | Simple frame / container | semantic-gap | Visual frame is expressible; containment/move semantics are not. |

The imported draw.io long tail is a separate attributed catalog pack.
`StencilGeometry` is only its unresolved semantic reference; the catalog owns
source selection and geometry, while render lowering must resolve the reference
or fail before constructing a closed render plan.

## Theme contract

`Theme` has three structured layers:

1. `ThemeStyle`: palette, type scale, base/role property patches, and default
   node distance;
2. `MasterLayout`: relative named regions with creation-only role/anchor
   defaults; and
3. `Furniture`: page numbers, logos, and header/footer bands against a relative
   safe area.

Regions are soft guides. Moving into one never reclassifies, owns, constrains,
or reflows a node. Furniture is deck chrome, not a picture object, and is
present in editor/presenter/export through the presentation's selected theme.

`defaultTheme` is a total explicit fallback with `background`, `ink`, and
`accent` palette values, a body role, no regions, and no furniture. It is useful
for tests and unthemed documents; consumers must not substitute it when a
presentation selected another theme.

Theme JSON parsing/writing, asset storage, import, per-aspect overrides,
furniture layout, and theme-editor UI are contract-only.

## Drag resolution

`resolveDrag` is pure and consumes a proposed `Box`, peer node boxes, validated
snap/binding configs, and `DragMode`.

### Relative binding

Binding candidates are tried first. For each cardinal side of each peer:

- perpendicular misalignment must be within `alignmentTolerance`;
- edge-to-edge gap must be in `[0, maximumGap]`;
- overlap offers no binding;
- passing `maximumGap` detaches by falling through to absolute placement;
- the authored gap is rounded to `0.1` slide units; and
- preview centre is recomputed from the rounded gap so preview equals commit.

The lowest `gap + misalignment` score wins; stable peer/side input order breaks
ties. A binding returns `RelativeNodePlacement` and suppresses all absolute
axis snaps.

### Absolute snapping

If no binding engages, each axis resolves independently:

1. **alignment**: dragged near/centre/far reference against slide edges,
   thirds, centre, theme-region references, and peer edges/centres;
2. **spacing**: centre between the nearest two flankers that overlap on the
   other axis; and
3. **grid**: nearest grid multiple.

Only a candidate within the threshold engages. Configuration enforces
`threshold < grid / 2`, preserving free zones. Alignment and spacing return
typed guide segments; grid changes only the centre.

`FreeDrag`, corresponding to Alt, bypasses binding and both axis resolvers. It
returns exact absolute placement and no guides.

`dragResolutionIntent` converts the result to the same typed `MoveElement`
intent used by non-pointer clients.

Multi-selection, N-way distribution, diagonal relative binding offers,
placement-cycle filtering, connector-endpoint port snapping, and browser
gesture/hysteresis state are contract-only follow-up slices.

## Source transaction boundary

`EditIntent` covers move, resize, bind, detach, node/connector properties,
content replacement, connector path replacement, reorder, delete, and shape
insert.

It does not mutate a `Picture` and cannot save source. The source/application
layers must still perform:

```text
typed intent at current rendered lease
  -> before/after semantic transaction
  -> provenance-guided candidate patch
  -> expected revision and bytes
  -> reparse and elaborate
  -> semantic verification
  -> verified patch and source history
```

A syntax-only snapshot or source-derived/unsupported construct remains
non-writable. A no-op must not create a patch or history entry.

## Executable laws

`test/Main.hs` executes 17 named laws:

- property precedence and typed unknown roles;
- P0/P1 catalog presence and custom geometry;
- binding before absolute snapping;
- Alt/free bypass;
- alignment before spacing before grid;
- independent axes and exact out-of-range drops;
- overlap/detachment binding rejection;
- connector cardinality, `+` folding, and orthogonal elbow derivation;
- barrier-safe reorder and unique picture identity;
- overlay visibility/final-step analysis; and
- mixed dialect/source-backed content retention.

Verified native:

```sh
cd slideBlaster2/packages/slideblaster-canvas
cabal --config-file=/tmp/slideblaster-slice1-cabal.config \
  test slideblaster-canvas-tests \
  --ghc-options='-fforce-recomp -Werror' \
  --test-show-details=direct
```

Verified with the installed Wasm compiler and package set:

```text
wasm32-wasi GHC 9.14.1.20260330
base-4.22.0.0
containers-0.8
text-2.1.3
```

The library and test executable compile with `-Werror`; the resulting WASI test
executable also runs under Node's WASI preview-1 implementation and passes all
17 laws.

## Deliberate next slices

This package is ready for the separate presentation, export, and render
packages to consume. Product parity still requires vertical slices for:

- measurement, placement graph/cycle detection, resolved connector/furniture
  layout, and a typed target-neutral render plan;
- source readers/writers, provenance, verified edits, and browser/CLI protocol
  integration;
- the exhaustive catalog rows and geometry formulas listed above;
- browser palette/property/drag/connector interactions crossing the real Wasm
  boundary; and
- animation keyframes and properties beyond overlay visibility.
