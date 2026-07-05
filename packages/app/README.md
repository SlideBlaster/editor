# @slideblaster/app

The shared editor application — the whole interactive editor UI, factored out of the
shells so it is implemented once and mounted by both. `web-shell` and `desktop-shell`
each build their platform adapters and call `createApp(root)`; everything the user
sees and touches lives here.

It is platform-agnostic DOM + engine code, so it runs unchanged in a browser tab and
in a Tauri webview. The shells differ only in which port adapters they wire around it
(none wired yet — see `../../PROJECT.md`, milestone M5).

## What's inside

- **`createApp.ts`** — the reactive render + edit controller (the two-way loop between
  the `.slideBlaster.md` source and the live deck).
- **`chrome.ts`** — the workspace shell markup (app bar, panes, rails).
- **UI modules** — deck, canvas, code pane, properties, creation menu, connector
  editor, snapping, zoom/pan, DOM measurer, math (KaTeX), export.
- **`export.ts`** — the self-contained presenter/PDF document builder. Works in any
  webview today; a native save-dialog path is a later refinement for desktop.

Every `.ts` has a companion `.md` describing its contract (Code Database).

## KaTeX stylesheet

`src/katexInlineCss.ts` is generated (embedded woff2 fonts, offline/CSP-safe).
Regenerate after upgrading katex:

```
corepack pnpm --filter @slideblaster/app gen:katex
```

See `../../PROJECT.md`.
