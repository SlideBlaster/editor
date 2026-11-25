# Provisional STR-007 implicit-canvas deck trial

STR-007 tests a lossless `.slide` parent CST around bounded TikZ audience
bodies. `slideblaster-deck` owns parent bytes/spans, slide/note association,
per-slide admission, verified child-to-parent edits, and deterministic New Slide
insertion. Product/2 owns navigation and paint correlation in Haskell; the JS
host only validates, forwards facts, and paints projections.

This is explicitly provisional P0 syntax, not the permanent SlideBlaster format.
Literal triple quotes in raw bodies, notes editing, complex TikZ paths, and
unsupported/expanded placements are retained but read-only or syntax-only. See
`docs/specs/str-007-implicit-canvas-slide-trial.md` and the package Haddock.
