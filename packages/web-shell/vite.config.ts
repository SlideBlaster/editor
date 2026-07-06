import { defineConfig } from 'vite'

/**
 * Web-shell dev/build config. Contract: see vite.config.md.
 *
 * The editor core and adapters are consumed as TypeScript source (workspace deps
 * with no build step), so Vite compiles them directly — nothing to pre-build.
 *
 * The Auth-service routes are proxied to a local backend so the browser reaches
 * it same-origin — first-party cookies, no CORS friction. Set VITE_SB_AUTH_URL=/
 * to have the shell use the browser Auth adapter against this proxy. Point the
 * proxy at either backend via SB_AUTH_PORT:
 *   - Phase A: the auth-stub (default 8788)
 *   - Phase B: the real Phoenix Auth service (`SB_AUTH_PORT=4000`)
 * In production these routes live on the Auth-service origin.
 */
const authPort = process.env.SB_AUTH_PORT ?? process.env.SB_AUTH_STUB_PORT ?? 8788
const authTarget = `http://localhost:${authPort}`
const authRoutes = ['/auth', '/me', '/mint', '/capabilities', '/signout']

export default defineConfig({
  server: {
    port: 5173,
    proxy: Object.fromEntries(
      authRoutes.map((route) => [route, { target: authTarget, changeOrigin: true }]),
    ),
  },
  build: { target: 'es2022' },
})
