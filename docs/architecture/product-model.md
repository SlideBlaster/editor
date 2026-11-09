---
status: accepted
updated: 2026-07-23
---

# Product semantic model

SlideBlaster is a source-authored presentation editor, not a TikZ viewer with
editing controls. Its shared Haskell model must represent the whole product:
ordered slides, audience and notes surfaces, mixed-language content, canvas
objects and their real properties, themes, overlays, timed animation, presenter
beats, and export compatibility. A reader may support only a stated concrete
syntax subset, but it elaborates into this common vocabulary rather than
creating a format-specific application.

This document fixes the semantic ownership and dependency direction. The
concrete types live in the packages named below; Haddock and tests are the
executable detail.

## Authorities

Four values exist for different reasons and must not be conflated:

| Value                     | Meaning                                                                         | May be saved?                                                             |
| ------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `SourceBufferSnapshot`    | Exact authored bytes and revision.                                              | Yes; this is the source authority, including invalid intermediate source. |
| `DocumentSnapshot syntax` | Source-locked CST, diagnostics, optional semantic presentation, and provenance. | Its source bytes may be saved.                                            |
| `Presentation`            | Format-independent meaning derived for one exact revision.                      | No; it is edited only through a verified projection back to source.       |
| `RenderPlan`              | Measured, resolved, target-neutral drawing and interaction instructions.        | Never; it is a disposable cache.                                          |

The application may show a last-good `RenderPlan` while newer source is invalid.
That plan is visibly inert and cannot issue an edit.

## Semantic root

The domain root has this shape:

```haskell
data Presentation = Presentation
  { presentationId       :: PresentationId
  , presentationMetadata :: PresentationMetadata
  , presentationTheme    :: ThemeRef
  , presentationSlides   :: NonEmpty Frame
  , presentationAssets   :: AssetManifest
  , presentationCitations :: CitationDatabaseRef
  }

data Frame = Frame
  { frameId         :: FrameId
  , frameTitle      :: Maybe Content
  , frameAudience   :: Picture
  , frameNotes      :: Maybe Picture
  , frameTransition :: Maybe SlideTransition
  , frameRotation   :: SlideRotation
  }
```

An identity is stable semantic identity, never a list index or DOM identifier.
Every editable canvas address includes all three axes:

```text
FrameId × Surface(audience | notes) × ObjectId
```

That prevents a notes edit from accidentally changing the audience picture and
allows reorder operations without invalidating object addresses.

`PresentationMetadata` carries title, authors, language, aspect ratio, theme
selection, bibliography/citation style, default content dialect, and export
defaults. Workspace paths and Git state are not presentation semantics.

### Projects and document kinds

A working copy is a project containing source documents, themes, assets,
bibliographies, and project settings. Its filesystem and Git metadata stay in
the app/ports layer. The semantic document opened from one source file is:

```haskell
data SemanticDocument
  = PresentationDocument Presentation
  | PictureDocument Picture
  | ThemeDocument Theme
```

`PictureDocument` lets a standalone `.tikz` figure reuse the same canvas,
properties, layout, edit, and export paths without manufacturing a one-slide
deck. A source directive may choose a compiled view-only figure, but that is a
diagnosed capability result and never replaces the editable semantic path.

Readers are selected by an explicit `FormatId` plus detection evidence. The
planned format family includes SlideBlaster Markdown, bare/wrapped TikZ,
bounded authored LaTeX/Beamer, structured theme JSON, and bibliography/assets.
Format packages own CSTs and inverse projections; they do not introduce new
canvas object types.

## Picture and ordered objects

A `Picture` is an ordered sequence of source-backed statements. The editable
object cases are nodes and connectors; named coordinates, groups, and opaque
statements remain in the ordering because they can affect meaning or form a
safe z-order barrier.

```haskell
data PictureItem
  = NodeItem Node
  | ConnectorItem Connector
  | CoordinateItem NamedCoordinate
  | GroupItem Group
  | OpaqueItem OpaqueSemantic
```

Later adjacent node statements paint in front of earlier nodes. Reordering a
node crosses only another reorderable node. A connector, coordinate, group, or
opaque statement is a barrier unless a format adapter proves a stronger rule.

### Node

A node is the common semantic object behind text, basic shapes, flowchart
symbols, UML/ER shapes, images, tables, imported stencils, and empty boxes:

```haskell
data Node = Node
  { nodeId         :: NodeId
  , nodePlacement  :: Placement
  , nodeSizing     :: Sizing
  , nodeTransform  :: Transform
  , nodeRole       :: StyleRole
  , nodeOutline    :: OutlineRef
  , nodePaint      :: PaintOverride
  , nodeTypography :: TypographyOverride
  , nodeContent    :: Content
  , nodeOverlay    :: Maybe OverlaySpec
  , nodeAnimations :: [AnimationRef]
  , nodeA11y       :: Accessibility
  }
```

Properties are algebraic values, not an untyped string map. Format adapters may
also retain ordered/repeated source options in their CST and provenance. A
derived semantic property never erases those concrete options.

Placement distinguishes authored meaning from resolved geometry:

- absolute point and anchor;
- relative side, gap, target, and anchors;
- source-backed derived/expanded placement that is renderable but read-only;
- generated placement for a newly inserted object.

Sizing distinguishes content-sized boxes, minimum floors, fixed width/height,
and aspect-lock policy. `Transform` carries rotation, scale, and flips. Paint
carries fill, stroke, line width, dash pattern, opacity, corner treatment,
gradient, and shadow. Typography carries family, size, weight, posture,
decoration, colour, alignment, wrapping, and line spacing. Theme defaults and
node overrides remain separate so precedence is explicit.

### Shapes and stencils

A palette shape is a named `ShapePreset`, not a second canvas object hierarchy.
Dropping it creates a normal `Node` with a role, outline, size floor, paint, and
optional seed content. Hand-authored source that produces the same properties
is indistinguishable after elaboration.

The catalog is data and can contain all curated basic, flowchart, arrow,
callout, UML, ER, container, and icon presets. The renderer is not a closed enum
of catalog entries. `OutlineRef` resolves to a small generic geometry language:

- rectangle, rounded rectangle, ellipse, and arc;
- arbitrary polygon;
- typed path segments;
- compound groups of primitives;
- asset-backed SVG/raster stencil with attribution;
- a diagnosed unsupported outline retained as source-backed read-only content.

This lets new presets and imported stencil sets enter as data. New engine code
is required only for a genuinely new geometry primitive, not for every catalog
row. Container/swimlane presets do not claim containment semantics until their
`Group` contract is implemented.

### Connectors

A connector owns style and a typed path:

```haskell
data Anchor
  = NodeAnchor NodeId BorderPort
  | AbsoluteAnchor Point
  | RelativeAnchor RelativeAdvance Vector

data Segment
  = Straight
  | Orthogonal CornerOrder
  | Cubic ControlPoint ControlPoint
```

Open and closed path cardinality is validated. Node anchors re-resolve against
the current node box. Orthogonal elbows are derived; cubic controls are stored.
Connector properties include stroke, dash, arrow start/end and tip, line join,
curve controls, labels, and overlay/animation references. Unsupported path
syntax stays exact and render-only or read-only according to the format tier.

## Freely mixed content

`Content` is a recursive semantic tree whose every authored construct retains
its input dialect:

```haskell
data Dialect = Markdown | LaTeX | HTML

data Content
  = EmptyContent
  | FlowContent [Block]
  | ImageContent ImageRef
  | TableContent Table
  | IncludeContent IncludeRef
  | GroupContent GroupContent
  | UnsupportedContent SourceBackedReason
```

Blocks and inline runs cover text, emphasis, strong, underline, strike,
highlight, links, code, lists, math, citations, line breaks, tables, columns,
matrices, images, transparent containers, and inline overlay constructs. Math
and explicitly opaque constructs retain literal payloads. Containers recurse
through the same dialect precedence, so Markdown, LaTeX, and HTML can nest
freely.

Dialect and provenance are different concerns:

- dialect says which surface language expressed a semantic construct;
- provenance says which exact source slot owns it and whether an inverse edit
  exists.

An unsupported construct is not discarded or guessed. It remains source-backed,
diagnosed, and non-editable.

Includes, tables, citations, and compiled figures expose explicit unresolved,
loading, ready, and failed derived states. Storage and compilation are
capabilities; their results are caches keyed by source and inputs. A compiler
never becomes the authority for the node's authored content.

## Theme

A `Theme` has three structured layers:

1. `ThemeStyle`: palette, type scale, semantic role defaults, list markers, and
   default relative-placement spacing.
2. `MasterLayout`: relative named regions used for creation seeding, guides,
   and snapping. Regions never reflow or reclassify moved nodes and are not
   exported.
3. `Furniture`: safe area, headers/footers, logo, running text, and page number
   placed relative to the slide and rendered in editor, presenter, HTML, PDF,
   and representable LaTeX output.

Style resolution is:

```text
built-in fallback
  < selected theme role
  < presentation/frame override
  < explicit node or connector property
  < transient editor preview
```

Only the first four can contribute to an artifact. The theme source is
canonical structured JSON in the working copy; CSS and LaTeX style files are
derived outputs.

## Overlays and timed animation

Overlays and animation share a timeline but are not the same feature.

### Overlay builds

An `OverlaySpec` is the parsed meaning plus raw Beamer-compatible spelling.
Whole-node specs and inline `pause`, `appear`, `only`, `uncover`, `visible`,
`invisible`, `alert`, and item specs derive a finite audience step count.

Overlay geometry is the union of all steps. Inactive material reserves its
measured space, so advancing a build never reflows a slide. Notes render at the
audience step and cannot extend the audience step count.

### Timed animation

An `Animation` identifies a target and contains:

- a trigger: beat entry, click, after previous, with previous, or explicit
  timeline offset;
- delay, duration, easing, repeat, direction, and fill behavior;
- an effect category: entrance, emphasis, exit, motion path, property track, or
  slide transition;
- one or more typed keyframes over transform, opacity, paint, stroke, or other
  explicitly animatable properties;
- a reduced-motion behavior.

Timed animation operates from resolved base geometry. Motion, scale, and
rotation are visual transforms and do not feed back into layout or connector
authorship. A source adapter may initially support only a subset, but the common
model and diagnostics must not collapse everything to a Boolean “animated”
flag.

## Layout

The slide uses a target-independent y-up coordinate space. Aspect ratio and
physical output size are explicit inputs, not baked into node coordinates.

Layout proceeds in named stages:

```text
Presentation + Theme + Measurements
  -> effective style
  -> intrinsic content sizes
  -> authored placement dependency graph
  -> resolved node boxes
  -> resolved connector anchors and paths
  -> furniture boxes
  -> per-slide ResolvedLayout
```

Relative-placement cycles and missing references are typed failures. Browser
measurement is a capability returning measurements keyed by semantic request;
it does not decide layout. Layout is computed once for the maximal overlay
state and reused for every beat.

Snapping is an editor proposal, not a persistent constraint solver:

1. relative binding is offered first;
2. otherwise each axis independently applies alignment, then equal-spacing,
   then grid;
3. a suppression modifier produces an exact free drop;
4. commit produces an absolute or relative typed edit intent.

Theme regions and slide guides participate as snap candidates.

## Render plan

A `RenderPlan` is a closed, validated Haskell value containing:

- background and furniture primitives;
- generic shape/path geometry;
- HTML/content fragments with source-independent semantic IDs;
- boxes, transforms, clip paths, paint and typography;
- overlay visibility and animation tracks;
- hit regions and accessible labels;
- the source revision and layout/measurement keys from which it was derived.

The browser may translate this plan to layered DOM/SVG and attach pointer
events. It must not reinterpret source, resolve theme precedence, invent
geometry, or decide whether an edit is valid.

The layer order is background, rear furniture, SVG geometry, HTML content,
front furniture, then host-only interaction overlays. Editor guides and
selection handles are never artifact content.

## Presenter semantics

The presentation runtime flattens each frame into audience-owned beats:

```text
(frame 1, step 1) ... (frame 1, step N)
(frame 2, step 1) ...
```

One cursor drives both windows. The audience projection contains the current
audience surface only. The presenter projection contains current notes at the
same step, next-beat preview, slide/step counts, and a timer origin. Navigation
supports next, previous, home, and end. The console and audience exchange only
cursor commands and versioned snapshots; neither owns a second deck model.

## Export semantics

All targets consume the same `Presentation`, beats, theme resolution, and
render-plan contract:

| Target            | Semantics                                                                                                                                                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Standalone HTML   | One self-contained offline presenter. It keeps interactive beats and every animation supported by the web renderer.                                                                                                                                                       |
| Rendered PDF      | Browser/native print capability over static beat pages. Overlays become pages. Timed animation is flattened according to policy and diagnosed.                                                                                                                            |
| LaTeX project     | Pure deterministic best-effort Beamer/standalone source plus theme, bibliography, and asset manifest. Native overlays may transfer; unsupported animation or theme fidelity is warned or rejected by policy. SlideBlaster never pretends that generated LaTeX is WYSIWYG. |
| Workspace archive | Deterministic working-copy bytes, excluding implementation-private Git storage and rejecting unsafe paths.                                                                                                                                                                |

Every export returns an `ExportReport`, not just bytes. It contains generated
artifacts, warnings/approximations, and fatal diagnostics. Diagnostics identify
the target and, where possible, frame/object/animation. A configurable
`LossPolicy` chooses whether a lossy feature is a warning with an explicit
approximation or a hard failure. No target silently drops a feature.

## Edit vocabulary

Canvas, properties, theme editor, navigator, notes editor, and CLI use typed
intents such as:

- insert/delete/move/resize/transform/reorder node;
- bind/detach placement;
- set one node, connector, content, overlay, or animation property;
- reshape connector or edit its endpoints;
- edit one mixed-content construct;
- insert/delete/reorder frame;
- add/remove notes surface;
- edit theme/style/region/furniture;
- change presentation metadata.

An intent first produces the intended semantic before/after transaction. Only
a format-specific provenance projector may propose source patches, and only
the document verifier may commit them after reparse, elaboration, and semantic
equality.

## Package ownership

The promoted backbone is:

```text
slideblaster-source
        |
        +----------------------+
        |                      |
        v                      v
slideblaster-canvas --> slideblaster-presentation
        |                      |
        +----------+-----------+
                   v
          slideblaster-document
                   |
          +--------+--------+
          |                 |
          v                 v
 slideblaster-export  slideblaster-app
          |                 |
          +--------+--------+
                   v
       engine / protocol / adapters
                   |
             CLI and Wasm host
```

Format readers depend inward on source/content/canvas/presentation contracts;
they do not redefine those semantics. Export writers depend on the semantic
model, not on CSTs or browser DOM. Ports are small capability records consumed
by app/export compositions; adapters remain target-specific.
