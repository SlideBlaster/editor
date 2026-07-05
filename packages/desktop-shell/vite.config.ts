import { defineConfig } from 'vite'

/**
 * Desktop-shell (Tauri) dev/build config. Contract: see vite.config.md.
 *
 * The frontend is the same shared app source as the web shell (workspace deps shipped
 * as TypeScript source — nothing to pre-build). Tauri runs this Vite server in dev and
 * loads the static build in production, so the config follows Tauri's conventions:
 * fixed port, no clearScreen (so Rust logs stay visible), and src-tauri excluded from
 * the file watcher.
 */
export default defineConfig({
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: { ignored: ['**/src-tauri/**'] },
  },
  // Expose TAURI_* env vars to the frontend alongside VITE_*.
  envPrefix: ['VITE_', 'TAURI_'],
  build: { target: 'es2022' },
})
