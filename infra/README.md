# infra — deploy as code

How the three production pieces are hosted and shipped. Everything is on
**Cloudflare**, free-tier, deployed by **CI on push to `main`** (no manual steps
after secrets are set once). Decision: ADR
[0020](../../design/decisions/0020-cloudflare-all-in-hosting.md), refining
[0010](../../design/decisions/0010-auth-token-minting.md) (auth runs as a Worker,
not Phoenix) and [0013](../../design/decisions/0013-build-and-launch-strategy.md).

## Topology (one domain + one subdomain)

```
  app.slideblaster.app            git.slideblaster.app
  ────────────────────            ────────────────────
  /                → Pages         /*  → git-proxy Worker
  /auth/*          → auth Worker        (relays browser git to github.com;
  /me /mint             │                carries the minted token as an
  /capabilities         │                Authorization header, not a cookie,
  /signout         → auth Worker         so cross-origin is fine)
```

- **The app and the auth Worker share one origin** (`app.slideblaster.app`), so the
  session cookie is **first-party same-site** — no `SameSite=None`, no CORS. This
  is the main reason for the all-Cloudflare move.
- **The git-proxy is its own subdomain.** It only ever sees the short-lived repo
  token as an `Authorization` header (never the session cookie), so it does not
  need to be same-origin; keeping it separate avoids path-prefix rewriting.

The client is configured with `VITE_SB_AUTH_URL=""` (same-origin) and
`VITE_SB_GIT_PROXY="https://git.slideblaster.app"`.

## The three deployables

| Piece              | Source                                                           | Cloudflare product | Route                                                        |
| ------------------ | ---------------------------------------------------------------- | ------------------ | ------------------------------------------------------------ |
| Web shell (static) | `packages/web-shell` (vite build)                                | **Pages**          | `app.slideblaster.app/*`                                     |
| Auth service       | `services/auth-worker` (TS Worker; replaced the Phoenix service) | **Worker**         | `app.slideblaster.app/{auth/*,me,mint,capabilities,signout}` |
| git-proxy          | `services/git-proxy` (exists)                                    | **Worker**         | `git.slideblaster.app/*`                                     |

Per repo convention, each Worker keeps its own `wrangler.toml` next to its code;
this directory holds the cross-cutting plan, the account/secrets runbooks, and the
CI wires it together.

## Auth Worker

Built in [`services/auth-worker`](../services/auth-worker/README.md). Same HTTP
contract as the Phase-A stub (drop-in for `BrowserAuthAdapter`), on the Workers
runtime:

- **App-JWT signing** via WebCrypto `SubtleCrypto.sign('RSASSA-PKCS1-v1_5', …)` —
  native RS256, no library. The `MintingKey` seam survives as a module boundary:
  `LocalKey` = the App `.pem` imported as a `CryptoKey` from a Worker Secret;
  `KmsKey` (later) = an HTTPS call to GCP/AWS KMS `asymmetricSign` (Cloudflare has
  no KMS, so the hardened key lives in an external KMS the Worker calls).
- **Sessions in Workers KV** (`SB_SESSIONS`, TTL = session lifetime). The GitHub
  user token stays server-side in KV — never in a client cookie. `sb_session`
  cookie carries the KV key; `sb_csrf` the double-submit token.
- Routes, mint flow (authorize against the user's installations → single-repo,
  `contents:write`, ≤1h token), and the SSO + install-per-repo flows live in
  [`services/auth-worker`](../services/auth-worker/README.md).

## CI (fully automated, on push to `main`)

`/.github/workflows/deploy.yml` (alongside the existing `ci.yml`):

1. **gate** — reuse `ci.yml` (format:check → typecheck → test). Deploy jobs `need` it.
2. **deploy-auth-worker** — `wrangler deploy` in `services/auth-worker`.
3. **deploy-git-proxy** — `wrangler deploy` in `services/git-proxy`.
4. **deploy-pages** — `vite build` `packages/web-shell` → `wrangler pages deploy`.

CI auth: repo secrets `CLOUDFLARE_API_TOKEN` (scoped: Workers Scripts + Pages +
Workers KV edit) and `CLOUDFLARE_ACCOUNT_ID`. Deploys are declarative — the routes,
KV binding, and Pages project live in `wrangler.toml` / the Pages config, so CI
just runs `deploy`.

## Secrets (never in the repo)

Runtime secrets are set once per Worker via `wrangler secret put` (encrypted by
Cloudflare, not in CI logs); see [secrets.md](./secrets.md).

| Secret                                          | Where                  | Notes                                                 |
| ----------------------------------------------- | ---------------------- | ----------------------------------------------------- |
| `GITHUB_APP_ID`, `GITHUB_CLIENT_ID`             | auth Worker vars       | not sensitive                                         |
| `GITHUB_CLIENT_SECRET`                          | auth Worker **secret** | OAuth code exchange                                   |
| `APP_PRIVATE_KEY`                               | auth Worker **secret** | the `.pem`; later replaced by a KMS-access credential |
| `WEB_SHELL_ORIGIN`                              | auth Worker var        | cookie/redirect allowlist                             |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | GitHub Actions secrets | CI deploy only                                        |

Local dev uses `wrangler dev` with a gitignored `.dev.vars` (same keys).

## Execution order

1. **Port auth → `services/auth-worker`** — **done.** TS Worker, contract + RS256
   signing unit-tested, bundles clean; Phoenix service retired.
2. **Routes + Pages**: `wrangler.toml` routes for both Workers; create the Pages
   project; DNS for `app` + `git`. Runbook: [cloudflare.md](./cloudflare.md).
   _(needs a Cloudflare account)_
3. **CI**: add `deploy.yml`.
4. **Wire prod env** into the web-shell build (`VITE_SB_AUTH_URL`,
   `VITE_SB_GIT_PROXY`) and ship.
5. **Live end-to-end** on the real domain: SSO → install-on-commit → push/pull.
6. **Hardening pass** (separate): external-KMS `MintingKey`; revocation webhooks;
   mint-rate limits.
