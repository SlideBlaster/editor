# service: git-proxy

The first-party CORS proxy that lets browser isomorphic-git reach GitHub's git HTTP
endpoints (which are not CORS-enabled). A short-lived, repo-scoped `contents` token
transits it, so it is **non-logging**, locked to github.com git-smart-http endpoints,
and minimal in surface. Flagged in `design/architecture/auth.md` as the token-transit
risk.

## Layout

- `src/handler.ts` — the runtime-agnostic core (`handleProxy`), web-standard
  `Request`/`Response`/`fetch`. All behavior lives here.
- `src/worker.ts` — Cloudflare Worker entry (the production runtime target).
- `src/node.ts` — Node http entry for local dev and the integration test.

Runtime decision (ADR 0013 / roadmap Track 0): **Cloudflare Worker**, with the Node
core kept exercisable without deploying.

## Status (Track-0 spike)

Implemented and unit-tested for the allowlist and CORS envelope
(`src/handler.test.ts`). Exercised end-to-end by the browser-git adapter's
env-gated integration test, which stands up an in-process instance of `node.ts`.

Open, to verify against real traffic:

- **In-browser CORS round-trip** — the unit tests prove the headers are correct; a
  real browser accepting them end-to-end still needs a manual/demo check.
- **Response body framing** — `content-encoding`/`content-length`/`transfer-encoding`
  are intentionally not forwarded (fetch auto-decompresses); confirm against a
  gzipped GitHub response.
- **Redirects** — currently `redirect: follow`; confirm GitHub git-smart-http never
  redirects off github.com.
