# SlideBlaster

SlideBlaster is a presentation editor for people who write slides as text. A deck is a Markdown
file with Beamer-style commands (`\pause`, `\only<2>{…}`, TikZ and draw.io figures, math); the
editor shows every slide as you type, and what you save is exactly the file you wrote.

**Status: 0.2.0-alpha.** It is used for real talks, but expect rough edges.

## What it does

- **Live editing:** source on the left, every slide on the right, repainted as you type; Save
  writes the file byte for byte
- **Overlays as in Beamer:** `\pause`, `\only`, `\uncover`, step-by-step code highlighting
  (```` ```text {1|2-3|4} ````)
- **Figures:** TikZ (compiled with `latex` + `dvisvgm`), draw.io, SVG and images, cached
- **Themes:** a deck uses `themes/<name>/` next to it (layout, CSS, logos); the editor, the
  presenter and the PDF all use the same theme
- **Decks of decks:** `\include{../other-talk}` imports another deck as a section; routes let the
  talk branch
- **Presenting:** a presenter console (notes, next slide, timer) and an audience window; with a
  second screen connected, the audience window fills it, borderless
- **PDF export:** one page per slide or per step, through headless Chrome; it warns about any
  text that runs off the slide or onto another element
- **Free zoom** in the editor: pinch, Ctrl+wheel or Ctrl +/−, about the pointer; middle-drag pans
- **Desktop app** (Tauri) with a list of presentations in the system tray, or any browser

## Quick start

```sh
# toolchain: GHC 9.10.3 + cabal (ghcup), node 22, Rust (for the desktop app),
# latex + dvisvgm (TikZ figures), Chrome or Chromium (PDF export)
cabal build exe:sb --project-file=cabal.project.native
(cd hosts/web && npm ci && npm run build)

# a deck in the browser
$(cabal list-bin exe:sb --project-file=cabal.project.native) serve path/to/talk-folder

# a PDF, with a warning for every slide that overflows
$(cabal list-bin exe:sb --project-file=cabal.project.native) build --pdf path/to/talk.slideBlaster.md

# the desktop app
(cd apps/desktop/src-tauri && cargo build --release)
apps/desktop/install-desktop.sh        # installs the `slideblaster` launcher
```

`sb check <deck>` reports diagnostics without opening anything. A tour of every feature is in
`fixtures/corpus/unit/all-features.slideBlaster.md`.

## A deck

````markdown
---
slideblaster: 1
title: "My talk"
theme: fns
aspect: 16:9
---

## A slide {#first}

- One point
\pause
- Another, after a click

```notes
- What to **say** here
```
````

## Developing

The core is Haskell (GHC2024): parsing, layout, overlays, history and the presenter are all
computed there, natively inside `sb serve` or as WebAssembly. The TypeScript host in
`hosts/web` only paints what the core sends and reports measurements and input.

Start with:

- [AGENTS.md](AGENTS.md) for workflow, roles, and documentation governance;
- [STYLE.md](STYLE.md) for Haskell and browser-host style;
- [PROJECT.md](PROJECT.md) for the package map;
- [docs/runbooks/development.md](docs/runbooks/development.md) for sessions and integration;
- [docs/runbooks/worktrees.md](docs/runbooks/worktrees.md) for safe session worktrees;
- [docs/runbooks/release.md](docs/runbooks/release.md) for product-owner promotion;
- [docs/runbooks/build.md](docs/runbooks/build.md) for build commands;
- [VERSION](VERSION) and [CHANGELOG.md](CHANGELOG.md) for product release state;
- [docs/architecture/README.md](docs/architecture/README.md) for the architecture;
- [docs/architecture/alpha.md](docs/architecture/alpha.md) for the accepted 0.2.0-alpha build design;
- [docs/architecture/capability-map.md](docs/architecture/capability-map.md) for
  the exact feature-by-feature implementation and wiring status.

## License

MIT, see [LICENSE](LICENSE).

## Running from source (details)

The Haskell core runs natively inside `sb serve`; the browser UI is a thin client of
its `/session` WebSocket (see `docs/specs/session-v1-protocol.md`).

```sh
# toolchain: GHC 9.10.3 + cabal (ghcup), node 22, latex + dvisvgm (for TikZ figures)
cabal build exe:sb --project-file=cabal.project.native
(cd hosts/web && npm ci && npm run build)
$(cabal list-bin exe:sb --project-file=cabal.project.native) serve fixtures/corpus/unit
# open the printed URL with ?entry=all-features.slideBlaster.md appended, for example
#   http://127.0.0.1:4173/?entry=all-features.slideBlaster.md
```

Edit in the source pane (the preview repaints), press Save (byte-exact write to the
file), Present opens the presenter windows. A TikZ `\figure{...}` compiles through
`latex` + `dvisvgm` and is cached under `.slideblaster/cache/`; without those tools
it shows a labelled placeholder and a diagnostic. `sb check <deck>` reports
diagnostics. Desktop shell: `apps/desktop` (Tauri; starts `sb serve` as a sidecar).
