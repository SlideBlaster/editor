# @slideblaster/web-shell

The web application: a Vite static app that wires the browser adapters into the
editor core and ships to the browser. A launch prerequisite alongside
`desktop-shell` (ADR 0013).

Milestone **M2** (dogfood). Built incrementally:

- **W1 (landed)** — scaffold + live render mount. Runs the engine pipeline unchanged
  in the browser (`fromMarkdown -> resolveLayout -> renderSlide`), showing a stage
  slide and a clickable filmstrip. Read-only. See `src/main.md`.
- **W2** — code pane (source <-> live slide), frame editing.
- **W3** — DOM-measurement adapter (replaces the naive measurer).
- **W4+** — canvas: select/drag, positioning, snapping, creation menu, inline
  content editing. These depend on engine **edit ops** (not yet built).

## Run

```
corepack pnpm --filter @slideblaster/web-shell dev      # http://localhost:5173
corepack pnpm --filter @slideblaster/web-shell build    # static build
```

See `../../PROJECT.md`.
