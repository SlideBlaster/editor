import { defineConfig } from 'vite'

/**
 * Web-shell dev/build config. Contract: see vite.config.md.
 *
 * The editor core and adapters are consumed as TypeScript source (workspace deps
 * with no build step), so Vite compiles them directly — nothing to pre-build.
 *
 * In local dev (Phase A of M4) the Auth-service routes are proxied to the
 * auth-stub so the browser reaches it same-origin — first-party cookies, no CORS
 * friction. Set VITE_SB_AUTH_URL=/ to have the shell use the browser Auth adapter
 * against this proxy. In production these routes live on the Auth-service origin.
 */
const authTarget = `http://localhost:${process.env.SB_AUTH_STUB_PORT ?? 8788}`
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
