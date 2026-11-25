# SlideBlaster 2

SlideBlaster 2 is the Haskell implementation of SlideBlaster: a
source-preserving presentation editor with a browser WebAssembly target and
native local tools.

The implementation is built in vertical slices. The shared GHC2024 semantic
backbone now represents canvas objects/properties, mixed-language content,
themes, coherent scenes in a non-empty presentation, overlays, timed animation,
presenter state, measurement/layout/resource-closed render plans, multi-target
export, exact source history, per-surface paint authority, and application
command policy. A separate catalog package supplies creation presets and
attributed stencil data; the canvas kernel retains only ordinary nodes and
generic outline geometry after insertion.

Target-neutral runtime ports give native and browser compositions the same
storage, Git, measurement, presenter, export, compile, clock, and logging
contracts. Each adapter either implements a capability or reports it
unavailable; it cannot replace Haskell source, layout, presenter, or export
policy. The current web measurement shim deliberately fails closed because its
legacy plain-text operation cannot honor structured render content and exact
embedded fonts.

The packaged browser actively mounts the source-authoritative
`slideblaster.product/2` path. One long-lived Haskell `AppModel` owns exact
source, branching history, accepted analysis, and per-surface paint leases;
the bounded private TikZ adapter projects admitted syntax into the common
Document/Canvas/Presentation model and verified local edits back to source.
The common Render plan is delivered by a real GHC-Wasm `MVar` reactor, while
the packaged JavaScript host only validates projections, paints, translates
pointer events, and interprets browser capabilities.

The older `slideblaster.product/1` endpoint is frozen for compatibility and is
not used by the packaged host. Its removal is deferred to a separately approved
migration. The native CLI and `slideblaster.engine/1` remain available as
bounded source/TikZ tooling; they are not the active browser application state.

To try the browser build locally:

```sh
make dev
```

Then open `http://127.0.0.1:4173/`. Use `make dev PORT=4180` to select another
port.

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

The existing implementation in `../editor/` remains the behavioural and fixture
oracle during migration. [`.META/design/`](.META/design/README.md) and
[`.META/knowledge/`](.META/knowledge/README.md) are the repository-local
destination authorities. The legacy `../design/` and `../knowledge/` trees
remain read-only and searchable until a dedicated, reviewed migration transfers
and reindexes them.


## Try the alpha (0.2.0-alpha, Desktop-first)

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
