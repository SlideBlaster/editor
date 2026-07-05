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

`serializeBody(content) -> string` is the un-braced body (`serializeContent` minus the
outer braces): `''` for empty, `source` for error, `serializeRuns(runs)` for text. It
is the exact inverse of `parseContent` (which takes an un-braced body), so an inline
editor seeds from it and re-parses on commit: `parseContent(serializeBody(c))` round-
trips `c`.

## Contract

- **Deterministic** — one content model prints one string.
- **Round-trip** — `serializeContent(parseContent(body))` equals `{body}` for
  canonical `body`, provenance included (format invariant 2 for node content).
