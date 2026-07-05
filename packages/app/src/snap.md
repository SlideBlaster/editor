# drag snapping (snap.ts)

The pure geometry behind M2 snapping: given a dragged node's proposed box and its
peers, nudge the drop point onto a meaningful alignment and report the guides to draw.
UI-free and fully unit-tested ([snap.test.ts](./snap.test.ts)); [canvas.ts](./canvas.md)
maps its result to a pixel preview and commit. Spec: `design/ux/positioning-snapping.md`.

- **One entry point.** `resolveSnap(dragged, peers, config) -> { center, guides }`.
  `dragged` and each peer are `{ center, size }` boxes in slide space (0..16 x 0..9,
  y-up). `config` is `{ threshold, grid, slideWidth, slideHeight }`, all in slide
  units. `center` is the snapped position; `guides` are line segments to render.
- **Per-axis, independent.** X and Y resolve separately (a box can align on one axis
  and space on the other). Each box is projected to `{ c, half, pc, phalf }` — center
  and half-extent _along_ the axis, and _across_ it (for spacing overlap) — so one
  routine serves both axes.
- **Precedence per axis:** `alignment` > `spacing` > `grid`. The first that lands
  within `threshold` wins; nothing within threshold leaves that axis free (exact).
  - **alignment** — the dragged node's near-edge / center / far-edge meets a peer's
    edge/center or a **slide guide** (edges 0 and extent, center, and the two thirds).
    Nearest candidate wins. Emits a full-span `align` guide at that coordinate.
  - **spacing** — the dragged node centers in an **equal gap** between the nearest
    flanking peer on each side that **overlaps it on the other axis**. The centered
    position is the midpoint of the two inner edges (size-independent). Emits two
    dashed `space` segments marking the equal gaps.
  - **grid** — the dragged **center** snaps to the nearest multiple of `grid`
    (`grid: 0` disables). No guide.
- **Threshold is a slide-unit radius.** The caller converts a fixed **pixel** radius
  (`SNAP_PX`) to units per drag using the slide rect, so snapping feels identical at
  any zoom. Keep `threshold < grid/2` or the grid captures every point and free
  placement is impossible — the pixel-derived threshold satisfies this in practice, and
  the tests assert it.
- **Scope.** This resolves the **absolute** drop only. The relative-binding drop
  (anchor-drop -> `[below=of img]`, E2) lives in [binding.ts](./binding.md), which
  canvas.ts tries first; `resolveSnap` never touches it. `SnapLine.kind` includes
  `'bind'` for that resolver's connector, but `resolveSnap` only emits `align`/`space`.
  Equal-spacing here is the two-flanker "center in the gap" case, not full N-way
  distribution (a later refinement).
