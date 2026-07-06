# web-shell vite config

Vite dev server + static build for the web application (ADR 0013, ADR 0008). The
editor core (`@slideblaster/editor`) and browser adapters are workspace deps shipped
as TypeScript **source** (no build step), so Vite type-strips and bundles them
directly — there is nothing to compile ahead of time.

- `es2022` build target matches `tsconfig.base.json`.
- Dev on port 5173; `pnpm --filter @slideblaster/web-shell dev`.
- **Auth proxy (M4 local dev):** the routes `/auth`, `/me`, `/mint`,
  `/capabilities`, `/signout` proxy to the auth-stub on
  `http://localhost:${SB_AUTH_STUB_PORT ?? 8788}`, so the browser reaches it
  same-origin (first-party cookies, no CORS). Set `VITE_SB_AUTH_URL=/` to use the
  browser Auth adapter against this proxy. In production these routes live on the
  Auth-service origin, not here.
