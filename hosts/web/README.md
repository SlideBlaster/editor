# SlideBlaster browser host

This dependency-free ES-module host initializes the GHC Wasm reactor and mounts
the source-authoritative `slideblaster.product/2` editor path. The loader still
exposes the older `slideblaster.engine/1` and `slideblaster.product/1` dispatch
methods for compatibility; the packaged UI uses product/2 exclusively.

The host validates the complete closed Haskell response before a render can
reach the DOM. It paints only bounded direct rectangle/connector geometry plus
Haskell-projected static audience/notes plans for every slide. The compact
workspace has a default-visible source editor, vertical thumbnail rail,
continuous deck, active-only writable surface, zoom, and quiet status. It
converts bounded pointer facts into 16×9 y-up exact decimals and returns stable
frame identities and raw events to Haskell. Exact source/history, active
navigation, selection, edit verification, connector behavior, snapping/fallback,
and paint authority remain Haskell policy.

`fixtures/demo.slide` is byte-identical to the Deck and Product-runtime test
copies. Source editing commits quietly on blur or Ctrl/Cmd+Enter through the
revision-fenced Product/2 replacement request; an in-flight response cannot
replace a newer dirty draft. The browser does not parse the deck or choose an
edit/navigation result.

From the repository root:

```sh
npm --prefix hosts/web test
./scripts/build-wasm.sh
./scripts/serve-web.sh
```

Then open `http://127.0.0.1:4173/`. Do not open `index.html` directly: Wasm,
fixture fetches, and ES modules require an HTTP origin.

The bundled WASI Preview 1 shim exposes no filesystem, process, or network
capability. Browser effects continue to cross the audited
`globalThis.slideblasterHost.call` boundary.
