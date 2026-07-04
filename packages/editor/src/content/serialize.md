# content serialize

`serializeContent(content) -> string`: the inverse of `parseContent`, returning the
full braced body token (`{}`, `{…source…}`, or `{…runs…}`) so it drops into a node's
body slot.

- **empty** -> `{}`.
- **error** -> `{source}` — the preserved verbatim source.
- **text** -> `{runs}`, each run emitting its exact surface form: `text` verbatim,
  `math` as `$src$`/`$$src$$`, `latex` as `\command{…}`, `markdown` as `**…**`/`*…*`,
  `html` as `<tag>…</tag>`. Children recurse.

`serializeRuns(runs)` is exposed (no braces) for content-level round-trip tests.

## Contract

- **Deterministic** — one content model prints one string.
- **Round-trip** — `serializeContent(parseContent(body))` equals `{body}` for
  canonical `body`, provenance included (format invariant 2 for node content).
