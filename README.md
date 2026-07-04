# SlideBlaster

A LaTeX/TikZ-native presentations editor. Your slides are `*.slideBlaster.md` files
in your own GitHub repo; the editor renders them fully client-side and ships as a
web app and a Tauri desktop app.

- **Orient:** [PROJECT.md](./PROJECT.md) — the module map.
- **Design:** the sibling `design/` repo (ADRs, format specs, architecture, roadmap).

## Develop

```
pnpm install
pnpm typecheck
pnpm test
```

Monorepo (pnpm workspaces): editor core + adapters + shells under `packages/`, two
Phoenix services + a git proxy under `services/`. This is an M0 scaffold; see
`PROJECT.md` for status.
