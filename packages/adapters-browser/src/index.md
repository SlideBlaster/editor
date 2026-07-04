# @slideblaster/adapters-browser (public surface)

Browser implementations of the editor ports. Currently exposes the Git port:
`IsomorphicGitAdapter` (the injectable core) and `createBrowserGitAdapter` (the
browser wiring). Storage, Collab, Compile, and Export adapters attach here at their
milestones.
