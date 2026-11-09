# slideblaster-web-wasm

This package links the shared source, engine, and protocol packages into a
`wasm32-wasi` reactor. It exports:

- `sb_start()`
- `sb_dispatch(engineRequestJson)`

`sb_dispatch` accepts and returns the exact JSON encoding owned by
`slideblaster-protocol`; authored bytes are base16-encoded by protocol v1.
Browser effects are imported only through `slideblaster-adapter-web`.

Build from the `slideBlaster2` directory:

```sh
./scripts/build-wasm.sh
./scripts/serve-web.sh
```

The supported baseline is the ghcup `wasm32-wasi` GHC 9.14 toolchain with Cabal
3.14 and Node.js available for GHC's `post-link.mjs`. The build script also
accepts explicit `WASM_GHC`, `WASM_GHC_PKG`, `WASM_HSC2HS`, and `WASM_CABAL`
paths.
