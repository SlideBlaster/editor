# app entry (index.ts)

The public surface of `@slideblaster/app`, the shared editor UI. It exports
`createApp(root, opts?)` (with `CreateAppOptions`) and the `AppPorts` type — the
port bundle (storage/git/auth) a shell builds from its platform adapters and
passes as `opts.ports`. Both shells depend on this package and do nothing but
build adapters and call `createApp` against a root element; passing no ports
runs the bundled in-memory sample.

Everything else in the package — the controller ([createApp.ts](./createApp.md)),
the chrome ([chrome.ts](./chrome.md)), the working-copy glue
([workspace.ts](./workspace.md), [fileTree.ts](./fileTree.md),
[gitPanel.ts](./gitPanel.md)), and the UI modules (deck, canvas, code pane,
properties, creation menu, zoom, measurer, export) — is internal. The package is a
Vite-consumable TypeScript source workspace dep (no build step); the shells compile
it directly.
