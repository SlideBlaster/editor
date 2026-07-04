import { defineConfig } from 'vitest/config'

// One root config covers every package. Tests live next to sources as
// *.test.ts / *.spec.ts.
export default defineConfig({
  test: {
    include: ['packages/**/*.{test,spec}.ts'],
    exclude: ['**/node_modules/**', '**/dist/**'],
  },
})
