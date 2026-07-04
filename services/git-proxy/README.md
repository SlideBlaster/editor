# service: git-proxy

The first-party CORS proxy that lets browser isomorphic-git reach GitHub's git HTTP
endpoints (which are not CORS-enabled). A short-lived, repo-scoped `contents` token
transits it, so it must be **non-logging**, locked to github.com git endpoints, and
minimal in surface. Flagged in `design/architecture/auth.md` as the token-transit
risk.

Scaffolded here because it is the browser-git spike's server half (Track 0). Runtime
(Cloudflare Worker vs. tiny Node service) is part of that spike. Design TBD.
