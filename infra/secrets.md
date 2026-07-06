# Secrets runbook

Nothing secret lives in the repo. Runtime secrets are Cloudflare-encrypted
(`wrangler secret put`); CI credentials are GitHub Actions secrets.

## Auth Worker (`services/auth-worker`)

Non-secret vars go in `wrangler.toml` `[vars]`; the two secrets are set once:

```sh
cd services/auth-worker
wrangler secret put GITHUB_CLIENT_SECRET      # from the GitHub App page
wrangler secret put APP_PRIVATE_KEY           # paste the full .pem contents
# vars (not secret): GITHUB_APP_ID, GITHUB_CLIENT_ID, WEB_SHELL_ORIGIN
```

`APP_PRIVATE_KEY` holds the PEM as a string; the Worker imports it as a WebCrypto
`CryptoKey` at first use. The hardening pass replaces this secret with a
KMS-access credential (the App key then never leaves the external KMS).

## git-proxy (`services/git-proxy`)

No secrets — it is a stateless relay. The repo token transits it only as a
request header and is never stored or logged.

## CI (GitHub Actions repo secrets)

- `CLOUDFLARE_API_TOKEN` — scoped to _Workers Scripts: Edit_, _Workers KV Storage:
  Edit_, _Pages: Edit_ on this account only.
- `CLOUDFLARE_ACCOUNT_ID`.

## Local dev

`wrangler dev` reads a gitignored `services/auth-worker/.dev.vars` with the same
keys (use a throwaway/dev GitHub App so prod secrets never sit on a laptop).
