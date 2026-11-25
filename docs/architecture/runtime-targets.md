---
status: accepted
updated: 2026-07-27
---

# Native and WebAssembly runtime targets

The browser is the primary product target. The native CLI is a first-class
development, automation, and conformance target.

```text
        shared Source/Document/Canvas/Presentation/Render/App
                  |                           |
          engine + native CLI          Product/2 protocol state
                                              |
                                      GHC wasm32-wasi reactor
                                      (one forced MVar cell)
                                              |
                                packaged browser ES modules
                                  validation / paint / events
                                              |
                                  host capability protocol
```

Shared packages compile unchanged under both compilers. Platform-specific
dependencies appear only in adapters and executable composition roots.

The engine protocol carries retained source/engine tooling commands. The active
browser application uses the separately versioned Product/2 protocol, while the
host protocol points in the other direction when Wasm requests platform
capabilities from JavaScript. None is an untyped substitute for another.

## Web composition

The Wasm artifact is a reactor loaded by a small packaged browser host. The host
provides browser capabilities such as:

- persistent browser storage;
- DOM measurement;
- logging;
- download and printing;
- later Git, collaboration, and compile-engine JavaScript dependencies.

The host contains no parser, source-editing rule, semantic layout policy, or
document-history logic. Browser view preferences and DOM lifetime are host
concerns; source revisions, document history, and semantic commit acceptance
are Haskell concerns. All target-owned JavaScript and dependencies are packaged
with the web artifact; production does not rely on a CDN.

The active ABI exports `sb_product_v2_dispatch`. A dedicated Product/2 adapter
serializes requests through a real `MVar` and forces both successor state and
response before release. The packaged host calls this export and mounts the
closed common render/gesture projection. Retained `sb_dispatch` and
`sb_product_dispatch` exports preserve engine and frozen Product/1 compatibility;
Product/1 is inactive in the packaged UI and its removal is separately gated.
Parsing and evaluation should move to a Worker only when latency evidence earns
that change.

## Native composition

The first native composition is a CLI using native Haskell file operations. It
exists now to prove that shared code has not accidentally become browser-only
and to provide deterministic fixtures for the Wasm target.

Native persistence uses the ordinary Haskell `bytestring`, `directory`,
`filepath`, and `base` APIs. It re-reads the target and checks the exact bytes,
writes a temporary sibling in the same directory, copies the target's portable
permissions, closes the handle, and renames the sibling over the target.

The standard Haskell filesystem surface does not provide an atomic
external-writer compare-and-exchange. Another process can change the target
between the final re-read and rename. The adapter therefore promises a
best-effort conflict check and an ordinary same-directory replacement, not
universal CAS, crash durability, ownership/ACL/xattr preservation, or an
external file-watching guarantee. A stronger platform backend may be added
later behind the same capability only if a real product requirement earns that
complexity.

The desktop application (`apps/desktop`, since 2026-11-25) is not a native composition of the
core: it embeds the web artifact and runs the same Wasm reactor in its own page. Its shell adds
only the project folder (list, read, conditional write, watch) and runs the native CLI once per
figure compile or PDF export (`sb render`, `sb build --pdf`). It starts no server.

## Capability equivalence

Adapters share semantic contracts but may have explicit platform capabilities.
For identical source and capability results, native and Wasm must agree on:

- protocol version and decoded command;
- exact source bytes;
- revision behaviour;
- diagnostic ordering;
- edit acceptance or rejection;
- semantic and render-plan values once those enter the slice.

Browser own-write observation and native external filesystem watching are
different capabilities and must not be weakened into false parity.
