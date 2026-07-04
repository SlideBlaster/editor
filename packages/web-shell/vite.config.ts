import { defineConfig } from 'vite'

/**
 * Web-shell dev/build config. Contract: see vite.config.md.
 *
 * The editor core and adapters are consumed as TypeScript source (workspace deps
 * with no build step), so Vite compiles them directly — nothing to pre-build.
 */
export default defineConfig({
  server: { port: 5173 },
  build: { target: 'es2022' },
})
