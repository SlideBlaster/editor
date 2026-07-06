# toMarkdown

`toMarkdown(doc) -> string`: the canonical serialization of a document.

## Canonical form

- Frontmatter block (`---` … `---`) only when there are entries, followed by one
  blank line.
- Per slide: `## <title> {#<id>}`, a blank line, a fenced `slide` block around the
  canonical picture source; then, only when `Frame.notes` is present, a blank line and
  a fenced `notes` block around the canonical notes-picture source (ADR 0019); then a
  blank line. A slide with no notes emits no `notes` block (round-trip law 6).
- Joined by `\n`; the trailing blank line yields a final newline (POSIX text).

Deterministic (format invariant 2): the same model always prints byte-identical
text. Together with `fromMarkdown` this is the format spine's round-trip.
