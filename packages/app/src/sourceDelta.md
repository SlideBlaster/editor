# source delta (sourceDelta.ts)

The source half of the node-scoped commit (ADR
[0016](../../../../design/decisions/0016-incremental-per-construct-editing.md)).

A canvas content edit re-serializes the whole document with `toMarkdown` (pure, cheap
— _not_ the whole-scene repaint we avoid). `minimalDiff(old, new)` reduces that to the
one contiguous range that changed — the longest common prefix and non-overlapping
common suffix — so the code pane applies it via `replaceRange` and keeps the caret,
instead of a whole-document `setValue`.

- `minimalDiff(old, new) -> {start, end, text}` — splice `text` into `[start, end)` of
  `old` to get `new`. Identical strings yield an empty edit at their end (a no-op edit
  moves nothing). Single-range only: a node-scoped edit changes exactly one region.
- `applyRange(s, edit)` — the inverse.

## Invariant (the non-divergence guardrail)

```
applyRange(old, minimalDiff(old, new)) === new     ∀ old, new
```

This is why the incremental source delta can never drift from a full re-serialize: the
code pane ends up byte-identical to `toMarkdown(doc')` by construction. It is the
first test of the feature.
