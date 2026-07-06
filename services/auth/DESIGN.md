# Auth service — Phase B design (Phoenix)

The real `AuthPort` backend (ADR 0010, `design/architecture/auth.md`). Speaks the
**exact HTTP contract** the Phase-A stub fakes (`services/auth-stub/src/handler.md`),
so the deployed service drops in with **zero adapter/app changes**. The browser
`BrowserAuthAdapter` cannot tell the stub from the real service — that is the test.

Phoenix/Elixir for the runtime (concurrency/perf). Vertical-slice first: real
GitHub push/pull with the App key held **locally** behind a swappable `MintingKey`
seam; KMS is a later pass that replaces `LocalKey` only.

## HTTP contract (must match the stub 1:1)

| Route                                    | Behavior                                                                                                                                                                                                                      |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /auth/github?return_to=`            | Begin real GitHub **user-to-server** OAuth. Stash `return_to` (path-only, no open redirect) + a state nonce in a short signed cookie; 302 to `https://github.com/login/oauth/authorize`.                                      |
| `GET /auth/github/callback?code=&state=` | Verify state; exchange `code` at `https://github.com/login/oauth/access_token`; `GET /user` for identity; create session; set `sb_session` (HttpOnly+Secure+SameSite=Lax) + `sb_csrf` (readable) cookies; 302 to `return_to`. |
| `GET /me`                                | Session → `Identity` JSON; none → 401.                                                                                                                                                                                        |
| `POST /mint` `{owner,name,scope}`        | Session (else 401) **and** `x-sb-csrf` == session csrf (else 403). Authorize + mint (below). 200 `{value, expiresAt}`; 403 if the user has no App install granting that repo.                                                 |
| `GET /capabilities`                      | Session → `CapabilityFlags`; none → 401 (adapter falls back to free tier).                                                                                                                                                    |
| `POST /signout`                          | Drop session; expire both cookies (Max-Age=0); 204.                                                                                                                                                                           |
| `OPTIONS *`                              | Credentialed CORS preflight; echo Origin (allowlist the web-shell origin), `Allow-Credentials: true`, allow `x-sb-csrf`.                                                                                                      |

`Identity` = `{ login, name, avatarUrl }`. `CapabilityFlags` = free tier for the
slice (`{ managedStorage:false, premiumCollab:false, seatCap:1 }`).

## Mint flow (the security-critical bit)

Client calls `POST /mint {owner,name,scope}` for repo `owner/name`. The service:

1. **Load session** → the signed-in GitHub `login` + user access token (from OAuth).
2. **Authorize (no confused deputy).** Resolve the App installation that covers
   `owner/name` and verify **this user** may use it — via the user access token:
   `GET /user/installations` then `GET /user/installations/{id}/repositories`, or
   `GET /repos/{owner}/{name}/installation` cross-checked against the user's list.
   No match → **403**. Never mint for a repo the session user can't reach.
3. **App JWT.** Build RS256 claims `{ iss: APP_ID, iat: now-30, exp: now+540 }`
   (≤10 min). Sign via the `MintingKey` seam — key material is **not** in the
   claim-builder's hands.
4. **Installation token.** `POST /app/installations/{id}/access_tokens` (auth:
   `Bearer <appJwt>`) with body
   `{ repository_ids:[<repoId>], permissions:{ contents:"write" } }`.
   GitHub returns `{ token, expires_at }` (TTL ≤ 1h, single repo, contents-only).
5. **Return** `{ value: token, expiresAt: expires_at }`. **Not persisted**
   server-side; **never logged**; the value is opaque to the service.

The client uses `value` only as git HTTP basic-auth `x-access-token:<value>`,
in memory, re-minted on expiry/reload (already implemented in the adapter).

## `MintingKey` seam (KMS-swappable)

A behaviour with one job — turn signing input into an RS256 signature — so the
App private key's _location_ is the only thing that changes at the KMS pass.

```elixir
defmodule SbAuth.MintingKey do
  @callback sign(signing_input :: binary()) :: {:ok, binary()} | {:error, term()}
  @callback key_id() :: String.t()   # for rotation / multi-key
end
```

- **`SbAuth.MintingKey.Local`** (slice) — reads the App `.pem` from a gitignored
  path (`APP_PRIVATE_KEY_PATH`), RS256-signs in-process. Dev/self-host only.
- **`SbAuth.MintingKey.Kms`** (later) — sends the JWT signing input's digest to
  AWS/GCP KMS `asymmetricSign`; key material never leaves the KMS. Swapping this
  in touches **only** this module + config; contract, mint flow, and client are
  untouched. This is why the seam exists now.

Selected by config (`config :sb_auth, minting_key: SbAuth.MintingKey.Local`).

## Sessions & CSRF

- Opaque session id + per-session csrf token, stored in **ETS** (slice) keyed by
  id; `sb_session` HttpOnly cookie carries the id, `sb_csrf` (readable) carries
  the csrf. Double-submit: `/mint` and `/signout` require `x-sb-csrf` == session
  csrf. (Later: swap ETS for Postgres/Redis when multi-node.)
- Cookies: `Secure` in prod, off for `http://localhost` dev (mirror the stub's
  `secureCookies`). `SameSite=Lax` so the OAuth redirect round-trip keeps the
  session; the CSRF double-submit covers `/mint`.

## Secrets & config (nothing secret in the repo)

Env only, gitignored (`.env`, `config/*.secret.exs`):
`GITHUB_APP_ID`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_WEBHOOK_SECRET`
(later), `APP_PRIVATE_KEY_PATH` (the `.pem`), `WEB_SHELL_ORIGIN` (CORS allowlist),
`SESSION_SIGNING_SALT`. Nothing token-shaped is logged (Plug logger scrubs
`authorization`, `x-sb-csrf`, `code`, `token`).

## Deferred to the KMS/hardening pass (not this slice)

- `MintingKey.Kms` + real KMS key; retire `Local`.
- Split the mint step into a **separate minimal minting service** — the only
  component with KMS access (ADR 0010). For the slice it's one Phoenix app.
- Revocation **webhooks** (`installation`, `installation_repositories`,
  permission changes), HMAC-verified, dropping sessions + denying mint.
- Mint-rate monitoring / per-user limits.

## Verification

The adapter↔stub integration test already pins the contract. Point the same test
(and the web-shell) at this service via `VITE_SB_AUTH_URL` / the adapter `baseUrl`
and it must pass unchanged, then a live run does a real push/pull to the test repo.
