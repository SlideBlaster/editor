# External source workspace

This directory separates reviewable provenance from local third-party checkouts.

- `manifests/` contains tracked Markdown or text manifests identifying an
  upstream source, exact revision, included paths, license/provenance evidence,
  and reproduction steps.
- Every other direct child is a local checkout and is ignored by Git.
- `drawio/` is an existing large, unpinned local checkout. It is not an accepted
  source manifest and must not be traversed, modified, or committed.

A manifest records an accepted or investigated source; it does not itself make
that source an approved product dependency. Follow the applicable user gate in
`AGENTS.md` and any source-specific ADR.
