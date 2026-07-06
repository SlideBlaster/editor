# auth-stub dev launcher

`pnpm --filter @slideblaster/auth-stub dev` starts the stub on
`SB_AUTH_STUB_PORT` (default 8788) via `createAuthStubServer`. Env:

- `SB_AUTH_STUB_PORT` — listen port (default 8788).
- `SB_AUTH_STUB_PAT` — a fine-grained repo PAT `/mint` hands back, to reach a real
  GitHub repo through the git-proxy.

The web-shell's Vite dev server proxies `/auth`, `/me`, `/mint`, `/capabilities`,
and `/signout` to this port so the browser talks to it same-origin.
