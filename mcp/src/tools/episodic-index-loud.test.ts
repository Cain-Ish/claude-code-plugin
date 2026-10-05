// The episodic index fails loud (R1 review): a build that leaves rows without a vector, and a
// corrupt index that gets reset, each leave an error-log.jsonl row. Before, both were silent: a
// vectorless archive looked healthy, and a bare `catch {}` swapped a corrupt index for an empty one.
// The explicit opt-out (SECOND_BRAIN_DISABLE_EMBEDDINGS=1) stays quiet; episodic-index.test.ts
// locks that half.
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

const { state } = vi.hoisted(() => ({ state: { nullEmbed: false } }));
vi.mock('./embeddings.js', async (importOriginal) => {
  const orig = await importOriginal<typeof import('./embeddings.js')>();
  return {
    ...orig,
    embedTexts: async (...a: Parameters<typeof orig.embedTexts>) => (state.nullEmbed ? null : orig.embedTexts(...a)),
  };
});

import { buildEpisodicIndex, episodicSearch } from './episodic-search.js';

const ARCHIVE = [
  '--- session-meta ---', 'session_id: s1', 'project_slug: proj', 'date: 2026-10-01', '---', '',
  'USER: how do we archive the transcripts safely before telemetry runs',
  'ASSISTANT:',
  '  We copy them with a checked append and advance the cursor after.',
  'USER: why does the drain skip the heads beyond the tail cap',
  'ASSISTANT:',
  '  Because the tail cap keeps only the last 200 KB of each archive.',
  '',
].join('\n');

let brainDir: string;
const errorRows = (): any[] => {
  const p = join(brainDir, 'error-log.jsonl');
  return existsSync(p) ? readFileSync(p, 'utf-8').trim().split('\n').map(l => JSON.parse(l)) : [];
};

beforeEach(() => {
  state.nullEmbed = false;
  brainDir = mkdtempSync(join(tmpdir(), 'epi-loud-'));
  mkdirSync(join(brainDir, 'transcripts'), { recursive: true });
  writeFileSync(join(brainDir, 'transcripts', 's1_proj_2026-10-01.txt'), ARCHIVE, 'utf-8');
});

describe('buildEpisodicIndex — a vectorless archive is loud', () => {
  it('logs the pending count when embedTexts returns null', async () => {
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;   // vitest.setup restores it
    state.nullEmbed = true;
    const r = await buildEpisodicIndex(brainDir);
    expect(r.pending).toBe(2);
    const rows = errorRows().filter(e => e.script === 'episodic-index');
    expect(rows).toHaveLength(1);
    expect(rows[0].message).toMatch(/2 of 2 rows have no embedding/);
    expect(rows[0]).toEqual({ timestamp: expect.stringMatching(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/),
      script: 'episodic-index', message: expect.any(String), exit_code: 1 });
  });
});

describe('loadIndex — a corrupt index is reset loudly, a partial one is normalized', () => {
  beforeEach(() => { process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1'; });

  it.each([
    ['unparseable JSON', '{"model": "x", "exchanges": ['],
    ['exchanges not an array', '{"model": "x", "indexed_files": {}, "exchanges": {}}'],
    ['a JSON array', '[]'],
  ])('%s: logged, reset and rebuilt', async (_label, body) => {
    writeFileSync(join(brainDir, 'episodic-index.json'), body, 'utf-8');
    const r = await buildEpisodicIndex(brainDir);
    expect(r.total).toBe(2);
    const rows = errorRows().filter(e => e.script === 'episodic-index');
    expect(rows.length).toBeGreaterThanOrEqual(1);
    expect(rows[0].message).toMatch(/corrupt episodic index reset/);
  });

  it('a missing indexed_files becomes {} and the build proceeds', async () => {
    writeFileSync(join(brainDir, 'episodic-index.json'), '{"model": "x", "exchanges": []}', 'utf-8');
    const r = await buildEpisodicIndex(brainDir);
    expect(r.total).toBe(2);
    expect(errorRows()).toEqual([]);
  });

  it('a missing index file is the normal first run: no error row', async () => {
    const res = await episodicSearch({ query: 'archive' }, brainDir);
    expect(res.results).toEqual([]);
    expect(errorRows()).toEqual([]);
  });
});
