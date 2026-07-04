# content styles

Derived semantic reads over surface-faithful runs — the tri-dialect equivalence made
computable without storing it.

- `dialectOf(run) -> 'md' | 'latex' | 'html' | undefined` — the dialect a run was
  written in (undefined for dialect-neutral `text`/`math`).
- `inlineStyleOf(run) -> 'bold' | 'italic' | 'underline' | 'strike' | undefined` —
  the style a run expresses regardless of dialect: `\textbf` = `**x**` = `<b>` =
  `bold`; `\emph` = `\textit` = `*x*` = `<i>`/`<em>` = `italic`; etc. Undefined when
  the run is not a style wrapper.

## Contract

- **Pure and derived** — computed from the run's stored surface form; never mutates
  and never persisted, so it cannot desynchronize from the serialization truth (same
  discipline as `../tikz/options`).
- These feed the canvas (a toolbar showing whether a selection is bold, ADR 0014) and
  the renderer (choosing an HTML element per run); they are not part of the model or
  the round-trip.
