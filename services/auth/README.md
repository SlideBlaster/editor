# service: auth

The isolated Auth service (Phoenix/Elixir). Holds the GitHub App identity, mints
short-lived repo-scoped tokens, manages sessions and capability flags. The
security-critical seam (ADR 0010, `design/architecture/auth.md`).

Speaks the **exact HTTP contract** the Phase-A stub fakes
(`../auth-stub/src/handler.md`), so it replaces the stub with **zero adapter/app
changes** — the browser `BrowserAuthAdapter` cannot tell them apart. Design +
mint flow: [`DESIGN.md`](./DESIGN.md). Module contracts live in the `@moduledoc`s.

## Layout

- `lib/sb_auth_web/auth_controller.ex` — the HTTP contract (`/auth/github`,
  `/auth/github/callback`, `/me`, `/mint`, `/capabilities`, `/signout`); cookies +
  CSRF double-submit.
- `lib/sb_auth/github.ex` — GitHub REST: OAuth exchange, identity, authorize-then-mint.
- `lib/sb_auth/app_jwt.ex` — builds the RS256 App JWT via the signing seam.
- `lib/sb_auth/minting_key.ex` — the **KMS-swappable** signing seam
  (`Local` now, `Kms` later). The only module the KMS pass touches.
- `lib/sb_auth/session_store.ex` — in-memory (ETS) session + pending-OAuth store.
- `lib/sb_auth_web/plugs/cors.ex` — credentialed CORS for a cross-origin shell.

## Run (dev)

Needs Elixir ≥ 1.15 + OTP 25 (precompiled Elixir is fine; the App-JWT crypto uses
Erlang `:public_key`). Configure secrets in a gitignored `.env` (see `.env.example`):

```sh
cp .env.example .env         # fill GITHUB_CLIENT_SECRET; drop the App .pem in secrets/
mix deps.get
set -a; source .env; set +a
mix phx.server               # http://localhost:4000
```

Point the web shell at it: run the shell with `SB_AUTH_PORT=4000` (Vite proxies the
auth routes here, same-origin) and `VITE_SB_AUTH_URL=/`.

## Status

Vertical slice built and unit-tested (`mix test`): full contract, real OAuth +
installation-token minting, App-JWT signing verified against a generated key. The
App private key is held **locally** behind `MintingKey` (KMS deferred). Live
GitHub push/pull needs the client secret + `.pem` in place.

## Deferred to the KMS/hardening pass

`MintingKey.Kms` + real KMS key; split the mint step into a separate minimal
service; revocation webhooks; durable session store; mint-rate limiting. See
`DESIGN.md`.
