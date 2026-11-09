# Alpha fixture corpus

Skeleton for the 0.2.0-alpha corpus (docs/architecture/alpha.md, section 6).
Sources below were copied unmodified from their original locations; the originals
are never edited. Lane A (core language) owns the contents from here on.

| Directory | Origin | Role |
| --- | --- | --- |
| `unit/` | written here | `all-features.slideBlaster.md` is the normative sample from section 3.5 (not yet readable by the current reader); small `unit/*` decks are added by lane A |
| `se-p4check/` | a legacy-div presentation deck | legacy-div import fixture (F16) |
| `p4devdays/` | the P4 Developer Days Beamer talk (`presentation.tex`, `config.tex`, `references.bib`, `figures/*.tikz`) | acceptance deck, to be re-authored in the new format; the `.tex` is the Beamer beat-count oracle |
| `ldwg/` | a Beamer lecture deck (`main.tex`, `arch.tex`, `references.bib`) | source for the ~12-frame excerpt: tikz, `\only`, listings, tabular |
