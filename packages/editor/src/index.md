# @slideblaster/editor (public surface)

The package entry point. Currently re-exports the port interfaces (`./ports`). The
engine (AST, `fromMarkdown` / `toMarkdown`, TikZ subset parser, layout, renderer,
edit ops, tri-dialect content) attaches here at M1, test-first against the format
invariants.
