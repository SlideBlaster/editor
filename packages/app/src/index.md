# app entry (index.ts)

The public surface of `@slideblaster/app`, the shared editor UI. It exports one
thing: `createApp(root, opts?)` (and its `CreateAppOptions`). Both shells depend on
this package and do nothing but build their platform adapters (none yet) and call
`createApp` against a root element.

Everything else in the package — the controller ([createApp.ts](./createApp.md)),
the chrome ([chrome.ts](./chrome.md)), and the UI modules (deck, canvas, code pane,
properties, creation menu, zoom, measurer, export) — is internal. The package is a
Vite-consumable TypeScript source workspace dep (no build step); the shells compile
it directly.
