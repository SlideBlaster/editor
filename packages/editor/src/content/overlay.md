# overlay spec interpreter (overlay.ts)

Pure functions over a Beamer overlay spec — the raw text a model `OverlaySpec` stores
(the bit inside `<…>`). Governed by ADR
[0018](../../../../design/decisions/0018-overlays-and-steps.md).

Grammar: a comma-separated union of terms, each `N` (single step), `N-` (from N on),
`-N` (up to N), or `N-M` (closed range). Steps are 1-based positive integers;
whitespace around terms is tolerated. The model keeps the raw text as the round-trip
truth — nothing here is stored or cached.

- `isValidSpec(raw)` — the parser's subset gate: true when every term parses and no
  closed range runs backwards (`4-2`). A malformed spec is rejected as out-of-subset
  (ADR 0015), so it never reaches the model.
- `activeAt(spec, step)` — whether `step` falls in the spec's union. The single
  question the renderer asks per overlay element. Malformed → inactive everywhere.
- `specMaxStep(spec)` — the largest finite step named (0 if none). An open `<2->`
  contributes its lower bound; the slide's step count is the max of these across all
  overlays, so an open range extends the count to its start.
- `specMinStep(spec)` — the smallest step named (1 when open at the start). The step
  floor a `\pause<spec>` sets for the content after it.
- `contentMaxStep(content)` — the highest step a node body references, mirroring the
  renderer's reading-order model (`\pause`/`\appear` raise a per-level floor; overlay
  wrappers and `\item<spec>` contribute their spec max; containers recurse). Always >= 1.
  `render/slide.slideStepCount` combines it with each node's `overlay=<spec>`.
