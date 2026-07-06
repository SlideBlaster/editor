# Cloudflare account setup

One-time account/zone wiring the CI cannot do for us. After this, `wrangler deploy`
(from CI) is all that runs.

## Zone + DNS

1. Add the zone `slideblaster.app` to Cloudflare (nameservers at the registrar).
2. DNS records (proxied):
   - `app` → the Pages project (Pages attaches this automatically as a custom domain).
   - `git` → a placeholder AAAA `100::` proxied record; the Worker route binds it.

## Workers + routes

Each Worker's `wrangler.toml` declares its route, so CI deploy is declarative:

- **auth Worker** (`services/auth-worker/wrangler.toml`):
  ```toml
  routes = [
    { pattern = "app.slideblaster.app/auth/*", zone_name = "slideblaster.app" },
    { pattern = "app.slideblaster.app/me", zone_name = "slideblaster.app" },
    { pattern = "app.slideblaster.app/mint", zone_name = "slideblaster.app" },
    { pattern = "app.slideblaster.app/capabilities", zone_name = "slideblaster.app" },
    { pattern = "app.slideblaster.app/signout", zone_name = "slideblaster.app" },
  ]
  kv_namespaces = [{ binding = "SB_SESSIONS", id = "<created via wrangler kv namespace create>" }]
  ```
  Worker routes take precedence over Pages for these paths; Pages serves the rest.
- **git-proxy** (`services/git-proxy/wrangler.toml`): add
  `routes = [{ pattern = "git.slideblaster.app/*", zone_name = "slideblaster.app" }]`.

## Pages project

- Create a Pages project (dashboard or `wrangler pages project create slideblaster-app`),
  custom domain `app.slideblaster.app`.
- CI builds `packages/web-shell` and runs `wrangler pages deploy dist`.

## KV namespace (sessions)

```sh
cd services/auth-worker
wrangler kv namespace create SB_SESSIONS      # paste the id into wrangler.toml
```

## GitHub App callback

Update the App's Callback URL to `https://app.slideblaster.app/auth/github/callback`
(keep `http://localhost:4000/...` as a second entry for local dev). Client secret
and `.pem` go in via `wrangler secret put` — see [secrets.md](./secrets.md).
