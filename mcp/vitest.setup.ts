// Global env-bleed firewall for the vitest suite.
//
// All test files share ONE Node process, so a mutation to process.env in one file
// leaks into siblings and flips their behaviour — the class that forced the per-file
// REASSERT hack in knowledge-search.test.ts (episodic-index deletes
// SECOND_BRAIN_DISABLE_EMBEDDINGS in its own beforeEach; under the shared process that
// delete bled into knowledge-search and flipped embeddings on → CI-only RRF-jitter
// flake). Snapshot process.env before EACH test and fully restore it after: keys added
// during a test are deleted, keys changed or removed are put back. No test can bleed
// env into the next one, so per-file re-assertions are no longer needed.
import { beforeEach, afterEach } from 'vitest';

let snapshot: Record<string, string | undefined>;

beforeEach(() => {
  snapshot = { ...process.env };
});

afterEach(() => {
  // Delete any key a test ADDED (not present in the snapshot).
  for (const k of Object.keys(process.env)) {
    if (!(k in snapshot)) delete process.env[k];
  }
  // Restore any key a test CHANGED or REMOVED back to its snapshot value.
  for (const k of Object.keys(snapshot)) {
    const v = snapshot[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
});
