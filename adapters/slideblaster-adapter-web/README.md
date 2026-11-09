# slideblaster-adapter-web

This package is the only place where the Wasm application imports browser
capabilities through JSFFI. It exposes one asynchronous import:

```text
globalThis.slideblasterHost.call(requestJson) -> Promise<responseJson>
```

Both sides use the numeric host protocol `version: 1` envelope. Requests contain
`id`, `capability`, `operation`, and `payload`; responses echo `id` and contain
either `payload` or a structured `error`.

The initial capabilities are deliberately small:

- `storage.list`, `storage.read`, and `storage.write`
- `measure.text`
- `log.write`

The package is Wasm-only because `GHC.Wasm.Prim` is supplied by the
`wasm32-wasi` GHC toolchain's `ghc-experimental` package.
