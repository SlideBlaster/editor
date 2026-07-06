# service: auth-stub

The **local dev double** for the Auth + minting service (ADR 0010). It speaks the
exact HTTP contract `BrowserAuthAdapter` calls, so the whole signed-in client
path — sign in, session, token minting, capabilities, sign out — works locally
with no GitHub App and no real backend. This is Phase A of M4(a): build and prove
the client against a stub, then replace the stub wholesale with the real Auth
service (`services/auth-worker`, a Cloudflare Worker — ADR 0019) at deployment
(Phase B). The adapter and app code do not change across that swap.

## What it fakes (and how the real service differs)

- `GET /auth/github` — instantly "authenticates" a fixed dev identity and 302s
  back, instead of round-tripping GitHub OAuth.
- `POST /mint` — returns a configured PAT or a synthetic per-repo dev token,
  instead of authorizing the user against the repo's App installation and
  minting a KMS-signed, single-repo installation token. **The stub grants all.**
- Sessions live in process memory; cookies are `SameSite=Lax` and `Secure` only
  when asked (off for http://localhost).

Everything else — the endpoints, cookie/CSRF shape, status codes — matches the
real contract (`design/architecture/auth.md`).

## Layout

- `src/handler.ts` — runtime-agnostic core (`createAuthStub().handle`), web
  `Request`/`Response`.
- `src/node.ts` — Node http entry (`createAuthStubServer`, `listen`); used by the
  dev launcher and in-process tests.
- `src/dev.ts` — `pnpm --filter @slideblaster/auth-stub dev` on
  `SB_AUTH_STUB_PORT` (default 8788). The web-shell's Vite dev server proxies the
  auth routes here so the browser talks to it **same-origin** (first-party
  cookies, no CORS friction).

## Real-GitHub path

Set `SB_AUTH_STUB_PAT` to a fine-grained PAT scoped to one repo (contents:write):
`/mint` then hands back that PAT, so the client can push/pull a real GitHub repo
through the git-proxy — the same seam the browser-git spike used — while the rest
of the auth infra is still stubbed.
