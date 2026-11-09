---
status: accepted
updated: 2026-07-23
---

# 0001. One Haskell repository targets native GHC and GHC WebAssembly

This is the repository-local implementation record for cross-project
[ADR 0025](../../../design/decisions/0025-slideblaster2-haskell-core.md).

## Decision

Create `slideBlaster2` as one repository beside the existing implementation.
Shared source, semantic, editing, and protocol packages compile under both:

- native GHC for the local CLI and later native compositions;
- `wasm32-wasi` GHC for the browser product.

All project components use `GHC2024` as their declared language baseline.
Platform effects live in separate native and web adapters. Browser JavaScript is
a narrow packaged capability host; it does not implement SlideBlaster semantics.

The existing `editor` repository remains operational as the behaviour and
fixture oracle until explicit retirement gates pass.

## Constraints

- Native-only and web-only dependencies cannot enter shared package closures.
- The pinned native and Wasm compilers must both support `GHC2024`.
- Both applicable targets must build before a shared dependency is accepted.
- Browser source editing, provenance, history, and layout policy remain Haskell.
- Delivery proceeds through end-to-end vertical slices.

## Consequences

The repository can make cross-target interface changes atomically. It also owns
two compiler toolchains and must pin and continuously verify them. Some browser
capabilities necessarily remain JavaScript adapters.
