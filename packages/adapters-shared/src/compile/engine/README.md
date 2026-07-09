# WASM latexml engine

Produces the `LatexmlEngine` the Compile adapter is injected with: a single
self-contained WASM module (Perl + XS + C libs) plus a preloaded virtual
filesystem (LaTeXML + XSLT resources), driven **in-process** — no fork/exec, one
Perl process running the LaTeXML API (`$converter->convert`).

Not built yet. The Track-0 feasibility spike (project-root `spikes/wasm-latexml/`)
proved it feasible (~5-6 MB gzipped) and produced this build plan. Build outputs
(`emperl.wasm`, `emperl.data`, `vendor/`) are gitignored; only the recipe is
tracked.

## Dependency inventory (empirical, from a real table conversion)

XS modules that need an external C library compiled to WASM:

| XS module           | C library                 | Notes                                                                        |
| ------------------- | ------------------------- | ---------------------------------------------------------------------------- |
| XML::LibXML         | libxml2 2.9.14            | pin XML::LibXML **2.0134** — predates Alien::Libxml2, accepts `LIBS=`/`INC=` |
| XML::LibXSLT        | libxslt + libexslt 1.1.37 | several LaTeXML stylesheets use EXSLT                                        |
| DB_File             | Berkeley DB               | `Post.pm` `use DB_File` is unconditional — build libdb or patch out          |
| Compress::Raw::Zlib | zlib                      | emscripten built-in port (`-sUSE_ZLIB=1`)                                    |

Self-contained XS (no external lib): Clone, JSON::XS. Core XS (Storable, Encode,
POSIX, …) already ship in webperl.

## Build pipeline

Based on webperl (Emscripten Perl): configure Perl with `emconfigure`, static-link
the XS via Perl's `static_ext` (webperl's `EMPERL_STATIC_EXT`), link with `emcc`,
package the Perl+LaTeXML tree into `emperl.data`.

1. **P0** reproduce vanilla webperl on a matched emsdk (1.39.16) → `perl -e` in node.
2. **P1** C libs to WASM — `./build-clibs.sh` (libxml2 + libxslt + libexslt; done
   in the spike). Add zlib; decide DB_File/libdb.
3. **P2** static-link the XS modules against the WASM C libs. **The main risk.**
4. **P3** preload LaTeXML + pure-Perl deps + `resources/XSLT/*.xsl` into `emperl.data`.
5. **P4** the ~15-line Perl driver + a JS wrapper resolving to `LatexmlEngine`.

The JS wrapper (P4 output) is what `../wasmLatexmlCompiler.ts` imports as the
engine. Golden-file tests compare its output to native `latexml` on a table corpus.

## Runtime artifacts (GitHub Release)

The browser runtime is three files — `perl-web.js` (the Emscripten `createPerlModule`
glue), `perl-web.wasm` (~7.9 MB) and `perl-web.data` (~12.7 MB, the preloaded LaTeXML
filesystem) — that together let a fresh clone run the compiler **without** the 500 MB
build toolchain.

They are **not committed to git** (they are git-ignored). They are attached to the
[`engine-v1`](https://github.com/SlideBlaster/editor/releases/tag/engine-v1) GitHub Release
and fetched on demand by **`fetch-dist.sh`**, which is idempotent and sha256-pinned. `make
build` runs it automatically before building the web shell; for a bare clone, run it directly:

    bash packages/adapters-shared/src/compile/engine/fetch-dist.sh

Only the web-shell build consumes these blobs (Vite `?url` in `web-shell/src/main.ts`); the
Node golden tests use the `vendor/` Perl tree, so `make check` needs no fetch. Rebuild the
runtime from source with `build-web.sh` (needs emsdk + the `vendor/` Perl tree), then cut a
new `engine-vN` release (`gh release create engine-vN dist/perl-web.{js,wasm,data}`) and bump
the tag + the three hashes in `fetch-dist.sh`.

## Files

- `build-clibs.sh` — libxml2 + libxslt + libexslt -> WASM static archives (verified).
- `build-web.sh` — links the browser `dist/perl-web.*` runtime via `emcc`.
- `dist/perl-web.{js,wasm,data}` — the shipped runtime (wasm/data via Git LFS).
- `vendor/`, `build/`, `tmp/`, other `*.wasm`/`*.data` — gitignored build artifacts.
