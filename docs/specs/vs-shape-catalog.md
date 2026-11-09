---
status: proposed
updated: 2026-07-23
---

# VS-CATALOG: complete searchable shape catalog

## Demonstration

Given the packaged catalog bytes, the same shared Haskell code used by native
GHC and GHC Wasm can:

```text
decode and validate 2,257 attributed stencil rows
  -> combine them with 15 native parametric presets
  -> search, group, and look up 2,272 stable presets
  -> return one typed ShapePreset as an ordinary-node insertion seed
```

This is an executable catalog slice. Browser-panel rendering, drag/drop
gestures, source patch generation, and target geometry rendering are subsequent
compositions of this contract.

## Ownership

`Canvas.Outline` owns only generic outline geometry. It contains no concrete
palette rows, catalog priority, catalog search, imported draw.io data, or
third-party license policy.

`slideblaster-catalog` owns:

- `ShapePreset`, `ShapeCatalog`, origin, family, and priority;
- native parametric preset data;
- imported stencil definitions and attribution;
- draw.io snapshot decoding and validation;
- stable lookup, search, category grouping, and family grouping; and
- the packaged snapshot and third-party notice.

A `ShapePreset` contains:

- stable `ShapeId`;
- label, category, keywords, and first-level family;
- P0/P1/P2 palette priority and origin;
- generic `OutlineRef`;
- ordinary `NodePropertyPatch`;
- positive drop `Size`; and
- initial mixed `Content`.

Selecting a preset does not add a shape-kind tag to a semantic node. Insertion
uses `shapePresetNodeSeed` to erase the catalog ID, origin, search metadata, and
attribution while copying outline, properties, minimum size, and content into
the generic `Canvas.Edit.InsertNode` path used by authored source. A
palette-created node and an equivalent authored node are semantically
indistinguishable.

## Catalog sources

### Native parametric catalog

The native catalog contains the fifteen SlideBlaster 1 P0 presets in stable
order:

```text
rectangle, rounded-rectangle, square, ellipse, circle,
diamond, triangle, trapezoid, parallelogram, hexagon, cylinder,
flow-process, flow-decision, flow-terminator, flow-data
```

These use rectangles, rounded rectangles, ellipses, validated polygons, or a
validated path. Their origin is `CuratedCatalogOrigin`; they carry no draw.io
attribution.

### Imported stencil catalog

The migration snapshot contains 2,257 attributed rows from the SlideBlaster 1
generated draw.io registry:

- every row is P2 and has `ImportedDrawIOOrigin`;
- every preset outline is `StencilGeometry` referencing a definition in the
  same decoded library;
- catalog and stencil identity spellings are equal;
- all source IDs remain exact, including qualified segments such as
  `advertising.3-1-rec`;
- all current rows have variable/stretch aspect policy; and
- the snapshot covers 81 categories in 17 first-level families.

P2 means “imported long-tail palette entry,” even when an imported Basic or
Flowchart stencil resembles a native P0 shape. The combined catalog has no
identity collision.

The source decision and unresolved historical upstream pin are governed by
[ADR 0005](../decisions/0005-drawio-catalog-source.md).

### User and extension packs

User and extension packs use the same `ShapePreset` and `StencilDefinition`
types. Their origins are explicit and may carry attribution. Merging fails on
any identity collision; built-in data never silently overrides external data.

## Validation

Decoding is all-or-nothing. It returns a typed failure for:

- malformed JSON or unsupported schema version;
- an empty snapshot;
- an invalid shape or stencil identity;
- a non-positive drop size;
- an empty or slash-delimited family;
- an unknown aspect policy;
- an empty or malformed path;
- duplicate preset or stencil identities; or
- a path that violates the generic canvas path structure.

Qualified catalog IDs require an identifier-like root and non-empty subsequent
segments. Letters, digits, underscore, and hyphen are permitted inside a
segment. Leading, trailing, or doubled dots remain invalid.

## Path grammar

The imported path grammar is the generated absolute SVG subset:

```text
M x y
L x y
Q cx cy x y
C c1x c1y c2x c2y x y
A rx ry rotation large-flag sweep-flag x y
Z
```

Coordinates are normalized from the source `[0,1]` y-down plane to the canvas
`[-1,1]` y-up outline plane. Arc radii double, rotation changes sign, and sweep
orientation reverses under that reflection. Redundant consecutive `Z` commands
are one SVG no-op spelling and normalize to one semantic close. No other
structural repair is performed.

Every decoded path begins with `M`. A close requires a drawn segment; drawing
after a close requires another `M`.

## Search and grouping

`searchCatalog`:

- strips and case-folds the query;
- matches label and keyword substrings;
- returns all entries for an empty query; and
- preserves catalog order.

It does not implicitly match category text unless that text is also a keyword.

`catalogSections` groups equal categories globally in first-seen order.
`catalogFamilies` places caller-named pinned families first in caller order,
sorts the remaining families by display text, and preserves catalog order
inside each family. These semantics support the original lazy panel without
placing UI state in the catalog package.

`ShapeCatalog` stores both a stable `NonEmpty` sequence and an indexed map.
Enumeration/search preserves source order; exact lookup does not linearly scan
all 2,272 presets.

## Runtime composition

The decoder, catalog, search, and grouping APIs are pure and target-neutral.

- Native composition reads installed Cabal data files through its storage/data
  adapter and passes exact bytes to `decodeDrawIOCatalog`.
- Browser composition packages `catalog-v1.json` and
  `THIRD_PARTY_NOTICES.md` under `hosts/web/dist/catalog/`. The next catalog UI
  slice loads the exact bytes through the web asset adapter and passes them to
  the same Wasm decoder.

The shared package does not call the filesystem, fetch a network resource, or
invoke JavaScript. A missing packaged asset is an adapter/infrastructure
failure; invalid bytes are a `DrawIOCatalogError`.

The 2.4 MiB snapshot should be loaded as an asset, not compiled into Haskell
source and not duplicated in JavaScript. The panel may render families lazily,
but it must not own a second catalog or geometry registry.

## Attribution

The package installs its third-party notice beside the JSON. The JSON also
retains the legacy title, author, license label, and source URL. Any UI that
offers these imported stencils must provide access to that notice/credit.

The historical upstream commit is not known. The snapshot’s legacy CC BY 4.0
notice must be preserved, while current upstream sources must undergo their own
license review and must not inherit that label by assumption.

## Acceptance evidence

The focused native/Wasm test suite must prove:

- all 2,257 imported rows decode;
- all 2,257 catalog IDs and stencil definitions are unique and paired;
- all fifteen native presets construct;
- the merged count is exactly 2,272;
- representative first/last/native/qualified IDs look up;
- search is case-insensitive and stable;
- category/family grouping covers every preset exactly once;
- duplicate and malformed dotted identities fail;
- `M/L/Q/C/A/Z`, coordinate reflection, arc reflection, and redundant close
  normalization are exact;
- malformed operands, numbers, flags, structures, sizes, families, and aspect
  policies return typed failures;
- exact SlideBlaster 1 source revisions/hashes remain recorded; and
- the packaged attribution names CC BY 4.0 and JGraph.

The deterministic migration check reruns
`tools/catalog-migration/migrate-slideblaster1.mjs` against the checksum-locked
SlideBlaster 1 registries and compares its bytes with the checked-in snapshot.

## Deliberately deferred

- choosing and licensing an exact upstream draw.io pin;
- a general upstream mxGraph XML importer;
- the Wasm asset request/decoder command and lazy catalog rail;
- thumbnail and canvas rendering through one resolved geometry path;
- drag/drop and source-verified node insertion;
- visual QA for all 2,257 paths;
- fixed-aspect letterboxing if a future snapshot introduces fixed rows; and
- LaTeX/PGF lowering for stencil geometry.
