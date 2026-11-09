---
status: proposed
updated: 2026-07-23
---

# ADR 0005: source the draw.io-derived catalog from an explicit, licensed pin

## Decision owner and present state

The durable upstream source mechanism is a product-owner decision. This ADR
therefore remains proposed.

For the migration, SlideBlaster 2 keeps the existing SlideBlaster 1 generated
artifact as a quarantined, checked-in snapshot. It does not add a draw.io Git
submodule and does not claim that the snapshot can currently be reproduced from
upstream XML.

The implementation separates three kinds of palette data:

1. **Native parametric presets.** Fifteen SlideBlaster-owned P0 presets use the
   generic canvas outline language. They do not depend on draw.io.
2. **Imported draw.io stencils.** The 2,257-row SlideBlaster 1 registry is
   migrated as attributed P2 stencil data. P2 describes its long-tail palette
   role; it does not create a different canvas object kind.
3. **User and extension packs.** These enter through the same validated
   `ShapePreset` and stencil-library contracts, with an explicit origin and
   optional attribution. They are not merged into the built-in snapshot.

The combined built-in catalog has 2,272 unique identities. All fifteen native
identities are intentionally absent from the imported snapshot. There are no
identity collisions. Five native concepts have label-level overlap with six
imported rows (`Trapezoid`, `Process` twice, `Decision`, `Terminator`, and
`Data`); these remain distinct geometry presets with distinct IDs.

## Why a submodule is not being added now

A Git submodule would make an exact upstream revision visible and would provide
the XML source next to the converter. It would also:

- checkout the full draw.io repository when only selected stencil paths are
  required;
- make recursive clone/update behavior part of every contributor and CI flow;
- expose vendor packs and other files that are deliberately outside the clean
  import scope;
- make an accidental submodule update look like an ordinary dependency bump;
  and
- import the terms of the selected upstream revision, which must be reviewed
  independently of the draw.io source-code license.

Most importantly, SlideBlaster 1 did not record the draw.io commit from which
its generated registries came. Choosing today’s commit would not establish
provenance for the existing geometry.

The [current official draw.io repository
README](https://github.com/jgraph/drawio) distinguishes the Apache-2.0 source
code from icon/stencil assets and states an additional restriction on using
those assets in Atlassian products or marketplace software. That current source
must not be described simply as CC BY 4.0. The migrated legacy registry retains
the CC BY 4.0 notice under which SlideBlaster 1 imported it, but the missing
historical upstream pin is an explicit provenance and license-review gap.

## Alternatives

### A. Full draw.io Git submodule

Benefits:

- exact commit appears in the parent tree;
- upstream XML and notices are available offline; and
- regeneration can run directly against the checkout.

Costs and risks:

- very broad checkout and contributor/CI complexity;
- easy to expose or accidentally import excluded vendor libraries;
- dependency and license changes arrive together; and
- no known commit currently reproduces the legacy snapshot.

This is not selected.

### B. Pinned source archive plus manifest

Store or fetch one immutable upstream archive, selected by a 40-character
commit, and check a manifest containing:

- repository URL and commit;
- archive SHA-256;
- included stencil paths and per-file hashes;
- excluded library rules;
- upstream license/notice hashes;
- converter schema/version; and
- expected output row count and hash.

Benefits:

- smaller and clearer than a submodule;
- a single reviewable supply-chain boundary;
- exact source can be retained or fetched reproducibly; and
- the manifest can gate excluded vendor packs.

Costs and risks:

- the correct historical or replacement commit must first be identified;
- distribution and license obligations must be reviewed for that exact pin;
  and
- a network fetch requires an explicit vendoring/cache policy.

This is the recommended future mechanism, subject to user approval and legal
provenance review.

### C. Checked-in generated artifact only

Benefits:

- deterministic, offline, and immediately usable by native and browser builds;
- smallest migration from the already-reviewed SlideBlaster 1 behavior; and
- exact SlideBlaster 1 input revisions and hashes can be recorded.

Costs and risks:

- it is derived geometry, not the original upstream XML;
- the unknown upstream commit prevents a clean-room regeneration claim; and
- a generated artifact alone is a weak long-term source-provision story.

This is the current migration baseline, not the final upstream strategy.

### D. Optional local checkout named by a manifest

Let the converter accept a user-supplied draw.io checkout only when it matches
the approved manifest. This avoids recursive clones while permitting offline
development. It complements option B; it does not replace the pin or license
review.

## Migration snapshot contract

`packages/slideblaster-catalog/data/drawio/catalog-v1.json` records:

- 2,257 rows;
- the exact SlideBlaster 1 definitions revision and SHA-256;
- the exact SlideBlaster 1 geometry revision and SHA-256;
- the draw.io repository URL;
- a null upstream commit with an explicit explanation; and
- the legacy attribution carried by SlideBlaster 1.

`tools/catalog-migration/migrate-slideblaster1.mjs` refuses inputs whose hashes
do not match those revisions. It cannot be repointed at a newer generated file
and silently emit provenance for the old one.

The package ships `THIRD_PARTY_NOTICES.md` beside the JSON. Browser packaging
must carry both files; native packaging must install both Cabal data files.

## Decision still needed

Before any regeneration from current draw.io sources:

1. choose full submodule or pinned archive/manifest;
2. identify the exact upstream commit;
3. review asset terms and every included stencil family at that commit;
4. decide whether source XML is vendored or fetched into a verified cache; and
5. accept a new snapshot only after visual and identity compatibility tests.

