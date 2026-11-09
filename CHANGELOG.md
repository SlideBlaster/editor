# Changelog

All notable product changes are recorded here. Product version `X.Y.Z` maps to
Cabal package version `X.Y.Z.0`.

## [Unreleased]

No unreleased product changes are recorded yet.

## [0.2.0-alpha] - 2026-11-09

### Added

- `sb serve`: the Haskell core runs natively behind a `/session` WebSocket; the browser UI and
  the Tauri desktop app (tray, presentations list) are thin clients of it.
- Markdown decks with Beamer overlays (`\pause`, `\only`, `\uncover`, code-line steps), TikZ and
  draw.io figures, deck-local themes, `\include` of other decks, and branching routes.
- Presenter console and audience window; the audience window fills a second screen.
- `sb build --html` and `sb build --pdf` (headless Chrome), with out-of-bounds warnings.
- Editor free zoom (pinch, Ctrl+wheel, Ctrl +/-) and live theme reload.

## [0.1.0] - 2026-07-26

### Added

- Bootstrap SlideBlaster 2 Haskell implementation with shared native and
  WebAssembly package boundaries and the bounded source/TikZ vertical slice.
- Dependency-free development session, worktree, metadata, and manual release
  workflow.

### Preservation

- The bootstrap implementation is preserved at development commit `4c39b9a`.
- The old implementation remains the behavioural and fixture oracle until a
  separate accepted decision retires it.
