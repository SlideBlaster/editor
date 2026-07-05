# relative-binding detection (binding.ts)

The E2 counterpart to [snap.ts](./snap.md). Snapping resolves an *absolute* drop;
this decides whether a dragged node should instead **bind** to a peer —
`[<side>=<gap> of <ref>]`. Pure and unit-tested ([binding.test.ts](./binding.test.ts));
[canvas.ts](./canvas.md) prefers a binding over an absolute snap and commits it via the
engine's `placeNodeRelative`. Spec: `design/ux/positioning-snapping.md`.

- **One entry point.** `findBinding(dragged, peers, config) -> Binding | null`.
  `dragged` is `{ center, size }`; each peer is a **named** `BindBox` (binding needs
  the ref name snapping doesn't). `config` is `{ alignTol, maxGap }` in slide units.
- **When a binding is offered.** For each peer and each of the four sides, the node
  qualifies when it is (a) aligned with the peer on the **perpendicular** axis within
  `alignTol`, and (b) sitting just off that side with an edge-to-edge gap in
  `[0, maxGap]` (overlapping → no binding; farther than `maxGap` → none, which is how a
  drag **detaches**). Among all qualifying candidates the most-attached/best-aligned
  wins (smallest `gap + misalignment`).
- **Gap seeding.** The gap is the actual edge-to-edge distance at the drop, rounded to
  0.1u for tidy source. The returned `center` mirrors the engine's `relativeCenter`
  (column/row-aligned to the ref), so the drag preview lands exactly where
  `placeNodeRelative` will render it.
- **Cycle safety is the caller's job.** `findBinding` is pure geometry and doesn't see
  the placement graph, so it can offer a ref that already depends on the dragged node.
  canvas.ts excludes such refs (`dependentsOf`) before calling, and the engine op
  refuses a cycle as a backstop.
