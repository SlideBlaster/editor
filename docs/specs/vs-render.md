---
status: accepted
updated: 2026-07-23
---

# Vertical slice: closed measurement, layout, and render plans

## Demonstration

Given already-elaborated presentation meaning and exact resource bytes, shared
Haskell can:

1. describe dialect-free content and direct typography for measurement;
2. reject measurement batches with duplicate keys or absent/wrong-kind font
   and image resources;
3. accept only exact-ticket, exact-key host measurements;
4. resolve absolute and relative node placement as a dependency graph;
5. reject duplicate nodes, missing targets, source-derived placement, and
   cycles atomically; and
6. construct a self-contained
   `Revision × RenderTicket × SurfaceAddress × OverlayStep × Size` render plan.

The render plan contains only direct paint instructions plus embedded resource
bytes. It is executable under native GHC and GHC Wasm. The current browser host
does not yet consume this general plan.

## Boundary and authority

```text
Presentation / Picture / resolved Theme
  -> lower source dialects, roles, palette/font names, assets and stencils
  -> dialect-free measurement requests + embedded resources
  -> authoritative host measurements
  -> render-owned ResolvedNode / resolved paths / furniture boxes
  -> validated closed RenderPlan
  -> target translation only
```

Source, CST, semantic presentation, and resolved theme remain upstream
authorities. Measurement results, resolved layout, and render plans are
disposable projections. They cannot enter persistence or source history.

A browser or native host may:

- install the embedded font/image/media bytes;
- measure exactly the structured request it was given;
- translate direct geometry/styles/content to its native drawing surface;
- attach the declared hit behavior; and
- acknowledge the exact revision and ticket it painted.

It may not:

- parse Markdown, LaTeX, HTML, TikZ, or any other authored syntax;
- resolve a palette key, theme font, role, asset id, stencil id, or source
  outline;
- invent geometry, fallback font selection, layer order, interaction ownership,
  or animation targets; or
- treat a stale result as current.

## Package modules

| Module                            | Contract                                                                                                                                                                    |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SlideBlaster.Render.Resource`    | Validated resource identities, non-empty exact bytes, image/font/binary kinds, duplicate-free manifests, and kind-checked references.                                       |
| `SlideBlaster.Render.Style`       | Validated direct RGBA colors, ordered gradients, positive strokes/dashes, non-negative shadows, and direct typography whose font is an embedded resource.                   |
| `SlideBlaster.Render.Geometry`    | Validated resolved paths/outlines/corner radii, affine transforms, clips, and explicit positive-width hit regions.                                                          |
| `SlideBlaster.Render.Content`     | Closed dialect-free text, link, math, table, inline-overlay, container, and image presentation with typed resource references.                                              |
| `SlideBlaster.Render.Measurement` | Stable element/part keys, intrinsic or width-constrained requests, one ticket and manifest per batch, and exact result coverage.                                            |
| `SlideBlaster.Render.Layout`      | Render-owned layout inputs/results/errors and input-order-preserving relative dependency resolution.                                                                        |
| `SlideBlaster.Render.Plan`        | Closed layered primitives, multipart identities, resources, overlay visibility, animation payloads, revision/ticket/surface validation, and interaction/accessibility data. |

The public `SlideBlaster.Render` facade re-exports this entire target-neutral
vocabulary.

## Closed vocabulary

The render package deliberately does not expose these semantic canvas values
through measurement or paint:

- `Content`;
- `NodeProperties` or `ConnectorProperties`;
- `OutlineRef`;
- `AssetId` or `StencilId`;
- `PaletteColour`;
- `ThemeFont`; or
- target-specific DOM/SVG strings.

Instead:

- a semantic outline is lowered to a resolved rectangle, ellipse, polygon, or
  one or more direct paths;
- a shape uses direct fill/stroke/opacity/shadow values;
- a connector uses a direct resolved path/stroke plus direct start/end arrow
  geometry, including first-class filled tips;
- content is a source-dialect-free structural tree with literal text and
  direct typography;
- an authored asset or stencil is lowered to an image resource or resolved
  geometry;
- audio/video playback declares controls, manual/automatic start, looping, and
  muted/audible state rather than inheriting host defaults;
- transforms are explicit affine matrices;
- clipping and hit testing are explicit plan data; and
- unsupported rendering fails in lowering or becomes ordinary explicit
  shape/content parts for a fully styled diagnostic; no open-ended
  “unsupported” paint instruction enters a valid plan.

`RenderContentRole` gives target translators a closed structural mapping for
paragraphs, headings, emphasis, code, lists, citations, and footnotes. Content
whose layout cannot be recovered from a generic role has dedicated values:

- a resolved highlight includes its direct colour;
- a link is a validated HTTP, HTTPS, email, or internal-fragment target;
- math is a closed token/row/fraction/root/script/under-over/fence presentation
  tree with an accessibility label, not TeX source;
- a table has header/body rows, header/data cells, and positive row/column
  spans; and
- an inline overlay is explicitly visible or hidden-but-layout-reserved.

The host maps these values directly. It does not parse HTML, TeX, CSS, Markdown,
or a source dialect, and hidden inline overlays must not reflow their
surroundings.

## Validated style and geometry

Types that can carry invalid numeric geometry are opaque. A target can inspect
them through closed view types, while lowering constructs them only through
smart constructors.

Construction rejects:

- gradient offsets outside `[0,1]`, decreasing gradient-stop order, coincident
  linear-gradient endpoints, and non-positive radial radii;
- non-positive custom dash lengths and stroke widths;
- negative shadow blur/spread and corner radii;
- polygons with fewer than three distinct points or zero area;
- non-positive path hit widths;
- non-positive font sizes/line spacing; and
- numeric font weights outside `1..1000`.

Duplicate adjacent gradient offsets remain legal because they express a hard
colour stop. Negative shadow offsets are likewise legal; only blur and spread
are constrained. Dashed strokes contain exact positive dash lengths rather
than a host-defined “dashed” or “dotted” preset.

## Resource closure

`ResourceManifest` embeds exact non-empty bytes under validated stable ids:

```haskell
data ResourceKind
  = ImageResource ImageFormat
  | FontResource FontFormat
  | BinaryResource MediaType
```

Every use site records its expected broad kind:

- image primitives and content images require `ImageResource`;
- every text run's direct typography requires `FontResource`; and
- video, audio, and embedded-document primitives require `BinaryResource`.

`mkResourceManifest` rejects duplicate ids.
`mkMeasurementBatch` and `mkRenderPlan` reject a missing resource or kind
mismatch. Hosts therefore receive all bytes needed by the accepted value and
never silently substitute a system font or workspace path. Format validation,
decoding failure, and safe blob/object projection remain typed target-adapter
failures; an adapter must not interpolate resource bytes as raw markup.

Extra unreferenced manifest entries are legal. That permits one immutable
manifest to serve several surface/step plans while every actual reference stays
closed and checked.

## Measurement

`MeasurementKey` is an authoritative `ElementAddress` plus a non-empty semantic
part such as `body` or `label`. A `MeasurementRequest` carries only:

- the key;
- dialect-free `RenderContent`; and
- `MeasureIntrinsic` or `MeasureWithin CanvasUnit`.

The batch carries its resource manifest and measurement ticket. Construction
proves unique keys, strictly positive `MeasureWithin` widths, and valid
resource references.

`completeMeasurements` accepts a result set only when:

- every result carries the batch ticket;
- no key occurs twice;
- every request has exactly one result; and
- no result key was absent from the request.

The existing browser `measure.text` call cannot install embedded fonts or
measure the recursive content vocabulary. The web port must therefore report
this capability unavailable until a structured, font-aware measurement
protocol exists. Flattening content or choosing a browser fallback font would
violate this contract.

## Layout

Render, not Canvas, owns derived node layout:

```haskell
data NodeLayoutInput = NodeLayoutInput
  { layoutInputIdentifier :: NodeId
  , layoutInputPlacement  :: Placement
  , layoutInputSize       :: Size
  }

data ResolvedNode = ResolvedNode
  { resolvedNodeIdentifier :: NodeId
  , resolvedNodePlacement  :: Placement
  , resolvedNodeBox        :: Box
  }
```

There is no semantic `Node` or unresolved style in either type. Absolute and
generated placement resolve the authored anchor/port against measured size.
Relative placement recursively resolves its stable target and applies primary
and perpendicular gaps to the requested target/own ports.

The operation is atomic. `LayoutError` reports:

- duplicate input identity;
- missing target;
- a complete relative dependency cycle path;
- source-derived placement without an admitted resolver; or
- an internal missing result.

The result preserves input order and can produce the node-box index used by a
separate connector-lowering step.

## Render plan

One `RenderPlan` records:

- exact source `Revision`;
- `RenderTicket`;
- authoritative `SurfaceAddress`;
- current `OverlayStep`;
- slide `Size`;
- embedded `ResourceManifest`;
- non-empty ordered layers; and
- zero or more render-scheduled animations for the current overlay beat.

`mkRenderPlan` accepts only an opaque, validated `AnimationTimeline`, never an
unchecked animation list. The presentation timeline has already proved unique
ids and backward-only, cycle-free dependencies. The plan retains each current
beat animation with a concrete `AnimationStart`: beat entry, target click,
timeline offset, with a named prior animation, or after a named prior
animation. A playback host therefore does not reconstruct dependency semantics
from list position.

The fixed back-to-front layer order is:

1. background;
2. rear furniture;
3. connector geometry;
4. object geometry/images;
5. content/media;
6. front furniture.

Layers may be omitted, but cannot be repeated or reordered. Selection handles,
snap guides, editor rulers, and similar host-only overlays are not artifact
layers.

The primitive/layer matrix is closed:

| Layer                | Allowed primitives               |
| -------------------- | -------------------------------- |
| background           | shape, image                     |
| rear/front furniture | shape, content, image            |
| connector            | connector path and endpoint tips |
| object               | shape, image                     |
| content              | structured content, binary media |

Each `RenderItem` additionally carries:

- stable multipart identity;
- visible or hidden-but-reserved overlay state;
- explicit affine transform;
- optional clip outline;
- explicit hit region;
- inert or element-selection interaction; and
- decorative or labelled accessibility state.

`ElementRender` and `FurnitureRender` both include a non-empty `RenderPart`.
Consequently a node's shape/content or a furniture item's backing/logo/label
remain distinct stable paint identities. Background identities are likewise
surface-local and multipart.

Element identity and primitive kind are correlated:

| Element identity | Allowed primitive kinds                 |
| ---------------- | --------------------------------------- |
| node             | shape, structured content, image, media |
| connector        | connector path and endpoint tips        |
| group            | no leaf paint primitive                 |

Groups are semantic containers; their children emit the direct paint parts.
Lowering must distribute group geometry/animation to the appropriate child
parts rather than disguising a group as an unrelated leaf primitive.

Construction rejects:

- a render identity outside the plan surface;
- an identity in the wrong layer;
- a primitive in the wrong layer;
- an element-id variant paired with an incompatible primitive kind;
- repeated or reversed layers;
- a duplicate multipart render identity;
- an interaction outside the surface;
- an interaction selecting an element other than its owning
  `ElementRender`;
- interaction attached to furniture/background;
- an interactive item without a hit region;
- missing or wrong-kind resources;
- an animation track whose element target has no `ElementRender` part in the
  plan; and
- a click-trigger target whose element has no `ElementRender` part in the plan.

Whole-slide animation targets are valid. A hidden-but-reserved element remains
a valid animation target because its identity and geometry remain mounted.

## Failure and stale-state behavior

All expected failures are typed and construction is atomic. There is no
partially accepted plan or measurement set.

A plan may be painted only for the exact session lease that requested its
`Revision × RenderTicket × SurfaceAddress`. The overlay step and size are also
part of the value rather than mutable host assumptions. A resize, font/resource
change, theme change, source revision, surface switch, or new measurement
attempt produces a new ticket/plan; late results stay disposable.

## Executable laws

`packages/slideblaster-render/test/Main.hs` proves:

- relative placement resolves against measured ports and preserves input
  order;
- a placement cycle retains its dependency path;
- incomplete measurement batches fail and complete batches index exactly;
- measurement refuses an absent embedded font;
- revision/ticket/surface/step/size/resource fences survive construction;
- duplicate and cross-surface render identities fail;
- reversed layers fail;
- a content primitive in the object layer fails;
- element A cannot select element B;
- missing and wrong-kind resources fail;
- animation targets must occur in the plan;
- one furniture id may safely emit several distinct parts;
- zero-width measurement constraints fail;
- unordered gradients, zero-width strokes, negative radii, and degenerate
  polygons fail before they can enter a plan;
- links, direct highlighting, math presentation, table spans, and inline
  hidden-reserved content survive the closed content tree;
- a node identity cannot own connector geometry;
- an absent click target fails independently of track targets; and
- filled connector arrow tips are directly representable.

The suite is compiled with warnings promoted to errors under native GHC and the
installed `wasm32-wasi` GHC. The Wasm executable is also run under Node/WASI;
file existence alone is not runtime evidence.

## Downstream migration

This correction intentionally removes the initial open render API:

- `MeasurementRequest` replaces `Content + NodeProperties` with
  `RenderContent`; `mkMeasurementBatch` additionally requires
  `ResourceManifest`.
- `NodeLayoutInput` replaces `Node + Size + NodeProperties` with
  `NodeId + Placement + Size`.
- render-owned `ResolvedNode` and `LayoutError` replace the Canvas values and
  `CanvasLayoutError` wrapper.
- `ShapePrimitive`, `ContentPrimitive`, `ConnectorPrimitive`, and image/stencil
  lowering now require direct render geometry/style/content/resource values.
- `AssetPrimitive` and `StencilPrimitive` no longer exist.
- `FurnitureRender` additionally requires `RenderPart`.
- `RenderItem` additionally requires transform, clip, and hit-region fields.
- `mkRenderPlan` additionally requires `ResourceManifest` and a validated
  `AnimationTimeline` rather than an animation list.
- `ConnectorPrimitive` additionally requires explicit `RenderArrowTips`.
- `RenderText` additionally requires a direct `RenderHighlight`.
- invalid style/geometry constructors are replaced by smart constructors and
  closed inspection views.

The application fixture and runtime measurement port must migrate to these
constructors. The browser protocol must not expose the general measurement or
render-plan path until it can validate and faithfully translate this contract.

## Deliberately deferred vertical increments

This slice defines and proves the closed boundary; it does not claim:

- a full `Presentation/Picture/Theme -> RenderPlan` lowerer;
- resource format decoders or font shaping;
- complete semantic connector-to-direct-arrow-geometry lowering;
- browser protocol codecs for this vocabulary;
- general DOM/SVG mounting;
- print pagination; or
- editor selection/snap-guide overlay drawing.

Those increments consume this plan. They must not reopen it by pushing theme,
source, or layout decisions into JavaScript.
