# toMarkdown

`toMarkdown(doc) -> string`: the canonical serialization of a document.

## Canonical form

- Frontmatter block (`---` … `---`) only when there are entries, followed by one
  blank line.
- Per slide: `## <title> {#<id>}`, a blank line, a ```slide fence around the
  canonical picture source, then a blank line.
- Joined by `\n`; the trailing blank line yields a final newline (POSIX text).

Deterministic (format invariant 2): the same model always prints byte-identical
text. Together with `fromMarkdown` this is the format spine's round-trip.
