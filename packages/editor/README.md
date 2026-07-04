# @slideblaster/editor

The platform-agnostic editor core. Owns the document model (AST, `fromMarkdown` /
`toMarkdown`), the TikZ renderer, KaTeX, layout, edit ops, and the UI — and depends
on external capabilities only through the six **port** interfaces in `src/ports`.

Adapters (per platform) implement the ports; shells wire adapters into this core.
See `../../PROJECT.md` and `design/architecture/README.md` (ADR 0008).

At M0 this package contains only the port interfaces. The engine lands at M1.
