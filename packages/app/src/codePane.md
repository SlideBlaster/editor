# code pane (codePane.ts)

The editable source view. The `.slideBlaster.md` text is the source of truth (A1),
so the pane simply exposes it as an editable string and reports changes.

- **Swappable widget.** `createCodePane(host, {value, onChange})` returns a `CodePane`
  (`getValue`/`setValue`/`replaceRange`). W2 implements it with a `<textarea>`; Monaco
  (roadmap workstream 2) replaces the implementation without changing the controller —
  the contract is just a source string plus a change callback.
- **`replaceRange(start, end, text)`** splices a single range in place (via
  `setRangeText`, caret/scroll preserved) — the code half of a node-scoped commit
  (ADR 0016). The controller derives the range from `minimalDiff` ([sourceDelta.md](./sourceDelta.md))
  so a canvas edit updates the pane without a caret-collapsing whole-value reset. An
  empty no-op edit is ignored.
- **Not the round-trip owner.** The pane holds no document state and does no parsing.
  The controller (`main.ts`) owns `source -> fromMarkdown -> render`, so canvas edits
  (W4+, via engine edit ops) can drive the same `setValue` seam later.
