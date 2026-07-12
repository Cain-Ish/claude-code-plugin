import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync, existsSync } from 'fs';
import { fileURLToPath } from 'url';

// P1 observability FIREWALL (docs/plans/2026-07-13-p1-observability.md Task 5).
//
// The P1 tranche records loop telemetry: utilization-counts.json (skill/agent
// invocation counts), .injected-manifest-* (per-session injection manifests), and
// value-loop / compound-loop TRACE rows. That data is OBSERVATION ONLY. The moment
// ranking, forgetting, graph, or search code reads it, the system grows the
// rich-get-richer usage-frequency feedback this repo has deliberately rejected
// THREE times (undo rows 16-18; access-counts.json's `acc` is likewise excluded
// from the forget score by the v4 correction).
//
// This lock exists BEFORE the telemetry ships so the guarantee is never a prose
// promise. It greps the consumer surfaces for the telemetry identifiers and fails
// on ANY reference. Legitimate future exceptions must edit this test in the same
// commit — a deliberate, git-blameable choice.

const root = fileURLToPath(new URL('../../', import.meta.url));
const read = (rel: string) => readFileSync(root + rel, 'utf-8');

// Identifiers that mark telemetry data (filenames + TRACE row kinds).
const TELEMETRY_IDS = [
  'utilization-counts',
  '.injected-manifest',
  'value-loop',
  'compound-loop',
];

// The consumer surfaces that must stay blind to telemetry: ranking, forgetting,
// graph, similarity/dedup, and the codemap rankers.
const RANKING_SURFACES: string[] = [
  'mcp/src/tools/knowledge-search.ts',
  'mcp/src/tools/episodic-search.ts',
  'mcp/src/tools/knowledge-fetch.ts',
  'mcp/src/tools/graph-store.ts',
  'scripts/wiki-forget-score.sh',
  'scripts/wiki-forget-candidates.sh',
];

describe('P1 telemetry firewall (observation-only — undo rows 16-18)', () => {
  it('sanity: the guarded surfaces exist', () => {
    const missing = RANKING_SURFACES.filter(f => !existsSync(root + f));
    expect(missing, `guarded surface moved/renamed — update the firewall: ${missing.join(', ')}`).toEqual([]);
  });

  it('no ranking/forgetting surface references telemetry data', () => {
    const offenders: string[] = [];
    for (const f of RANKING_SURFACES.filter(f => existsSync(root + f))) {
      const src = read(f);
      for (const id of TELEMETRY_IDS) {
        if (src.includes(id)) offenders.push(`${f}: "${id}"`);
      }
    }
    expect(offenders, `telemetry leaked into a ranking surface: ${offenders.join(' | ')}`).toEqual([]);
  });

  it('no codemap module references telemetry data (PageRank stays structural)', () => {
    const dir = root + 'mcp/src/tools/codemap/';
    const offenders: string[] = [];
    for (const f of readdirSync(dir).filter(f => f.endsWith('.ts'))) {
      const src = readFileSync(dir + f, 'utf-8');
      for (const id of TELEMETRY_IDS) {
        if (src.includes(id)) offenders.push(`codemap/${f}: "${id}"`);
      }
    }
    expect(offenders, `telemetry leaked into the code map: ${offenders.join(' | ')}`).toEqual([]);
  });
});
