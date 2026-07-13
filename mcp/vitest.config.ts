import { defineConfig } from 'vitest/config';

// Run ONLY the source tests. Without this, vitest's default glob also picks up
// the COMPILED `dist/**/*.test.js` copies — stale build artifacts that diverge
// from src the moment a test changes, so CI ran an old copy of a fixed test and
// flaked. The runtime ships bundles, never per-file compiled tests; dist test
// files are never the source of truth.
//
// The former separate `test/` tree was folded into co-located `src/**` siblings, so
// the include is src-only now. setupFiles wires the global env-bleed firewall
// (vitest.setup.ts) that snapshots+restores process.env around every test.
export default defineConfig({
  test: {
    include: ['src/**/*.test.ts'],
    exclude: ['node_modules/**', 'dist/**'],
    setupFiles: ['./vitest.setup.ts'],
  },
});
