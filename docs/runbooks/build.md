---
status: accepted
updated: 2026-07-27
---

# Build and run

## Prerequisites

Native:

- GHC 9.10.1 or newer with `GHC2024`;
- Cabal-install 3.14 or another version compatible with the selected compiler.

Web:

- a ghcup/`ghc-wasm-meta` `wasm32-wasi` GHC 9.10.1 or newer;
- the matching `wasm32-wasi-ghc-pkg` and `wasm32-wasi-hsc2hs`;
- Node.js 22 or newer;
- Python 3 for the dependency-free local server.

The verified toolchain on 2026-07-23 was:

```text
native GHC       9.10.3
Wasm GHC         9.14.1.20260330
Cabal-install    3.14.2.0
Node.js          22.21.1
```

The build script discovers the installed `wasm32-wasi-ghc-9.14` first. Override
it with `WASM_GHC` and the matching `WASM_GHC_PKG` / `WASM_HSC2HS` only when
using a differently named installed toolchain.

## Lint

The cheapest rung of the verification ladder. `make lint` enforces the totality
rules in [STYLE.md](../../STYLE.md) mechanically and syntax-checks the browser
host. `make dev` runs it before building, and `make check` runs it before the
tests.

```bash
make lint
```

## Native

```bash
cabal --project-file=cabal.project.native build all
cabal --project-file=cabal.project.native test all --test-show-details=direct
cabal --project-file=cabal.project.native run exe:sb -- version
```

Native persistence uses ordinary Haskell filesystem libraries. It rechecks the
expected bytes, writes a temporary sibling, copies portable permissions, and
renames the sibling over the target. It is a best-effort conditional save:
another process may still write during the narrow recheck-to-rename window.
It does not promise atomic external-writer compare-and-exchange, ownership,
ACL, extended-attribute, special-mode-bit, or crash-durability preservation.

## WebAssembly

```bash
make dev
```

This builds the GHC-Wasm reactor and serves the packaged browser host at
`http://127.0.0.1:4173/`. Override the port with `make dev PORT=4180`. Press
Ctrl-C to stop the server.

The underlying build and host checks remain available separately:

```bash
./scripts/build-wasm.sh
./scripts/serve-web.sh 4173

cabal --project-file=cabal.project.native test \
  slideblaster-tikz-tests \
  slideblaster-app-tests \
  slideblaster-engine-tests \
  slideblaster-protocol-tests \
  slideblaster-product-protocol-tests \
  slideblaster-product-v2-protocol-tests \
  --test-show-details=direct

cd hosts/web
npm test
npm run test:browser
```

The packaged page actively uses `slideblaster.product/2`: it loads the tracked
3,115-byte provisional STR-007 `demo.slide`, projects three Haskell-owned
navigator entries, paints the active bounded canvas, performs lease-fenced
parent-lifted drag transactions, and supports deterministic New Slide plus
exact-source undo/redo. `npm run test:browser` uses Chrome/Chromium when found.
If no compatible executable is installed it prints `SKIP browser smoke: ...`
and exits zero, so a skip is not browser evidence and must be reported as
unverified. The older Product/1 export remains compatibility-only and is
inactive in the host. The `.slide` grammar is a trial and is not a permanent
format decision.

## Cross-target

The native CLI and browser send the same fixtures through
`slideblaster-protocol`. Their decoded source bytes, revisions, edit
acceptance/rejection, and diagnostics must match.

## Current verification status

The session evidence for the active Product/2 slice records focused native
Deck/TikZ/App/Engine/protocol/runtime suites, host Node tests, Wasm packaging,
and a real Chrome run as passing on 2026-07-28. Chrome opened the exact
3,115-byte demo, navigated three Haskell previews without a source revision,
performed a parent-lifted move and exact undo, created a deterministic fourth
slide and undid to the exact original deck with the prior active frame, rejected
a stale request atomically, and reported zero page/console errors. The
repository-wide native matrix still has the pre-existing unrelated
`slideblaster-catalog-tests` failure on `sports.camper-1`; do not report `test
all` as green until that baseline issue is resolved.

Package distribution metadata is not release-ready: the project intentionally
has no selected license yet, so `cabal check` reports `license: NONE`. License
selection requires an explicit project decision rather than an inferred
default.

## Related procedures

- [Development sessions](development.md)
- [Session worktrees](worktrees.md)
- [Release and main promotion](release.md)
