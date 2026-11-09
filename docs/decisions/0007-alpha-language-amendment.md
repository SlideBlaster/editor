---
status: proposed
updated: 2026-11-06
---

# Alpha language amendment (D2, D3, D7, D8)

This amends ADR 0004 (product semantic backbone) for the alpha, following
`docs/architecture/alpha.md`.

- **D2, format.** The deck format is `*.slideBlaster.md`, specified in
  `docs/specs/slideblaster-md-alpha.md`. The provisional `.slide` reader remains
  in `SlideBlaster.Deck` only until the product runtime moves to the new
  analyzer, then retires. New code lives in `SlideBlaster.Deck.Container`,
  `.Frontmatter`, `.Markdown` and `.Edit`.
- **D3, two tiers, one scene.** The flow body lowers to generated-placement
  `title`/`body` region nodes; a ```` ```slide ```` fence adds absolutely placed
  nodes to the same scene. The canvas content model gains `CodeContent`,
  `BoxContainer`, `FigureContainer`, `ColumnContainer` and `HeadingContainer`;
  consumers must handle them or project children.
- **D7, overlays.** Overlay specs use Beamer grammar, parsed by
  `SlideBlaster.Syntax.Overlay` and lowered to `OverlayHook` values. Beats derive
  from the audience scene only.
- **D8, unknown syntax.** Unknown commands, environments and containers are kept
  exactly, lowered to opaque content, and reported with non-hard diagnostics.
  Only container-level failures block semantic readiness. This supersedes the hard
  error of ADR 0015 for body content.
- **Identifiers.** File paths cannot be `SourceRef`/`AssetId` values; figures and
  images receive deterministic handles and a separate resource record.
