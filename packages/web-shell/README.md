# @slideblaster/web-shell

The web application: a thin Vite shell that mounts the shared editor app
(`@slideblaster/app`) in the browser and, as they land, wires the **browser** port
adapters (IndexedDB/FSA storage, isomorphic-git + CORS proxy, browser export). A
launch prerequisite alongside `desktop-shell` (ADR 0013).

All editor UI and behaviour lives in `@slideblaster/app` so it is shared with the
desktop shell (implement once). This package owns only `index.html`,
`vite.config.ts`, and `src/main.ts` (the mount + future adapter wiring).

Milestone **M2** (dogfood) built the editor incrementally (render mount, code pane,
DOM-measurement layout, canvas select/drag/snap, creation menu, inline editing,
connectors, properties, undo/redo, export) — that work now lives in the shared app
package. Next: browser Storage + Git adapters (M3).

## Run

```
corepack pnpm --filter @slideblaster/web-shell dev      # http://localhost:5173
corepack pnpm --filter @slideblaster/web-shell build    # static build
```

See `../../PROJECT.md`.
