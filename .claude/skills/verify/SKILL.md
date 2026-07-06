---
name: verify
description: Build, launch, and drive the SlideBlaster editor (web-shell) to verify changes at the running surface. Use when verifying engine/app/adapter changes end-to-end in the browser.
---

# Verifying SlideBlaster changes

The surface for engine (`packages/editor`), app (`packages/app`), and browser
adapter (`packages/adapters-browser`) changes is the **web-shell in a browser**.
Unit tests (`npx pnpm test` from `editor/`) are CI's job, not verification.

## Launch

```bash
cd editor/packages/web-shell
npx pnpm dev > /tmp/vite.log 2>&1 &   # serves http://localhost:5173
# NOTE: `pnpm` is not on PATH in this environment; always go through `npx pnpm`.
# Passing --port via `pnpm dev -- --port N` does NOT reach vite; it lands on 5173.
```

## Drive (headless)

Playwright works but only cached browser revisions launch. As of 2026-07,
`~/.cache/ms-playwright` has chromium 1208/1217 — `npm install playwright@1.58
--no-save` in a scratch dir matches 1208. `npx playwright install` also works if
downloading is acceptable.

Key selectors (defined in `packages/app/src/chrome.ts`):
`#side-panel` (hidden until ports wired), `#file-tree`, `#git-panel`,
`#editor-head` (open doc path), `#code textarea` (code pane), `.sb-slide`
(rendered slide), `.sb-handle` (draggable node hit area), `#status`, `#error`.
File tree rows: `.tree-dir` / `.tree-file .tree-name`; git panel:
`.git-identity button` (sign in/out), `.git-commit input|button`.

The file tree uses `window.prompt`/`confirm` — handle `page.on('dialog')`.

## Gotchas

- Each fresh Playwright context = fresh IndexedDB (clean working copy seeded
  with `sample.slideBlaster.md`) and fresh localStorage.
- LightningFS flushes its superblock on a ~500 ms idle debounce: wait ~1.2 s
  after a write before `page.reload()` or the file/dir may not persist.
- Autosave debounce is 400 ms: wait ~900 ms after typing before asserting the
  git status changed.
- App errors surface in `#status` (git panel errors) and `#error` (parse/boot);
  check both plus console/pageerror when a panel renders empty.

## Flows worth driving

Edit code pane -> git status dirty -> reload persists; sign in -> commit ->
log entry + clean status; New deck (nested `talks/demo` path) -> opens; delete
open doc -> app re-boots onto a survivor; drag a node on the canvas -> source
changes -> persists across reload.
