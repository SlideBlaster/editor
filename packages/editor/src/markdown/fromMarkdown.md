# fromMarkdown

`fromMarkdown(text) -> SlideDocument`. Parses the container: optional `---`
frontmatter of `key: value` lines, then one or more `## Title {#id}` slide sections,
each with exactly one fenced ```slide block whose body is parsed by the TikZ parser.

## Contract

- Lenient where it does not lose information; strict where structure is required
  (throws on a non-heading at slide level, or a missing ```slide block).
- Frontmatter is captured as raw ordered key/value entries; one blank line after the
  closing `---` is consumed.
- The inverse of `toMarkdown` for canonical text (invariant 2); the model it yields
  round-trips through `toMarkdown` (invariant 1).
