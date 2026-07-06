# service: auth-worker

The Auth service as a **Cloudflare Worker** (ADR 0010, 0020). Holds the GitHub App
identity, mints short-lived repo-scoped tokens, manages sessions + capability flags.
The security-critical seam. Runs on a route of the app domain so the session cookie
is **first-party same-site** (no cross-site CORS).

Speaks the **exact HTTP contract** the Phase-A stub fakes
(`../auth-stub/src/handler.md`), so it is a drop-in for `BrowserAuthAdapter` — the
adapter and app are unchanged, and the stub stays as the offline dev/test double.

## User flow (hosted web shell)

Sign in once via GitHub SSO; work fully offline; the network is needed only to sync.

1. **Sign in (SSO).** `GET /auth/github` → user-to-server OAuth → identity + session.
2. **Work offline.** Editing + local git commits (browser working copy, M3) — no token.
3. **Install per repo, on demand.** The first commit to a repo the App is not on →
   `/mint` 403 → the shell sends the user to `GET /auth/github/install` (GitHub's
   repo picker) → back. A one-click grant, not a settings dig.
4. **Mint on commit.** `/mint` authorizes the user against that repo's installation
   and returns a single-repo, `contents:write`, ≤1h token; the client pushes/pulls
   through the git-proxy. Re-minted on expiry; never persisted.

## HTTP contract

| Route                                 | Behavior                                                                                                                                                                                   |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `GET /auth/github?return_to=`         | SSO: 302 to `login/oauth/authorize`. Stash `return_to` in an HttpOnly `sb_flow` cookie.                                                                                                    |
| `GET /auth/github/install?return_to=` | 302 to the App's `installations/new` (resolved via `GET /app`).                                                                                                                            |
| `GET /auth/github/callback`           | Recover `return_to` (query `state` or `sb_flow`); exchange `code`; `GET /user`; create session; set `sb_session` (HttpOnly) + `sb_csrf` (readable); 302 to `return_to`. Serves both flows. |
| `GET /me`                             | Session → `Identity {login,id,avatarUrl}`; none → 401.                                                                                                                                     |
| `POST /mint {owner,name,scope}`       | Session (else 401) + `x-sb-csrf` == csrf (else 403). 200 `{value, expiresAt}` (expiresAt = epoch ms); **403 if the App is not installed on that repo** → client launches install.          |
| `GET /capabilities`                   | Session → `CapabilityFlags`; none → 401.                                                                                                                                                   |
| `POST /signout`                       | Drop session; expire cookies; 204.                                                                                                                                                         |

## Mint flow (authorize, then mint)

`installationForRepo` (as the App) → `authorizeUserRepo` (as the user — confirms
they can reach the repo through that installation, no confused deputy) →
`installationToken` (`POST /app/installations/{id}/access_tokens` with
`repository_ids` + `contents:write`, ≤1h). GitHub returns an ISO `expires_at`; we
convert to epoch ms. The token is never persisted, never logged.

## Layout

- `src/handler.ts` — runtime-agnostic contract core (routes, cookies, CSRF, CORS);
  takes injected deps so it runs on Workers and under Node (tests).
- `src/worker.ts` — Cloudflare entry: wires config + KV sessions + GitHub client.
- `src/github.ts` — GitHub REST: OAuth exchange, identity, authorize-then-mint, install URL.
- `src/appJwt.ts` — RS256 App JWT via the signing seam.
- `src/mintingKey.ts` — the **KMS-swappable** seam. `createLocalMintingKey` imports
  the App `.pem` as a WebCrypto `CryptoKey` (wrapping PKCS#1 → PKCS#8); a KMS key
  later is an HTTPS call to GCP/AWS KMS. Only this module changes at the KMS pass.
- `src/sessions.ts` — session + pending-OAuth store; Workers KV (prod) or in-memory
  (tests). The GitHub user token stays server-side, never in a client cookie.
- `src/config.ts`, `src/encoding.ts` — settings/wire types; base64url + token helpers.

## Run (dev)

```sh
cp .dev.vars.example .dev.vars     # fill GITHUB_CLIENT_SECRET + APP_PRIVATE_KEY (.pem)
npx wrangler dev                   # http://localhost:8787
```

Point the web shell at it with `SB_AUTH_PORT=8787` (Vite proxies the auth routes
same-origin) and `VITE_SB_AUTH_URL=/`. Unit tests: `pnpm --filter @slideblaster/auth-worker test`.

## Status

Built + unit-tested (contract, mint gating, and RS256 App-JWT signing verified
against a real PKCS#1 key). App key held locally behind `MintingKey` (KMS deferred).
Live GitHub push/pull needs the client secret + `.pem` in place.

## Deferred to the hardening pass

External KMS for `MintingKey`; revocation webhooks; mint-rate limits; a durable
session store if strong consistency is ever needed (KV is eventually consistent).
