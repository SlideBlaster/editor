# document model

The top of the AST: a `SlideDocument` is `meta` (frontmatter) + an ordered list of
`Frame`s (slides). This is the in-memory truth that `markdown/` round-trips to and
from `*.slideBlaster.md` text, and that the CRDT is seeded from / materialized to.

## Contract

- `SlideDocument.frames` is ordered; order is significant (slide order).
- `DocumentMeta.entries` is an ordered list of raw frontmatter key/value pairs.
  Order and raw values are preserved so the round-trip is lossless; a typed
  frontmatter schema (title, theme, aspect ratio) layers on top later. `getMeta`
  reads the first value for a key.
- `Frame.id` is the stable slide identity (from the heading `{#id}`); `Frame.title`
  is navigation metadata (not duplicated into the picture); `Frame.picture` is the
  slide's TikZ picture (see `tikz.md`).
- `Frame.notes` is the optional presenter-notes sidecar (ADR 0019): a second TikZ
  picture shown only to the presenter and driven by the same overlay step counter as
  `picture` (cap to slide — see `overlay.md`/`slide.md`). Absent when the slide has no
  notes; its presence is what makes `markdown/` emit a ```notes block.

Invariants over this model live in `invariants/`.
