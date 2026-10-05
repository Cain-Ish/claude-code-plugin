// The parser-2 migration (R1#3) must re-embed ONLY the rows whose text it cleaned. The
// embedding cache is keyed `episodic:<id>` and checked against a hash of the exact text, so a
// cleaned row misses once and an unchanged row is served from the cache. This needs the
// embedding path to actually run, which SECOND_BRAIN_DISABLE_EMBEDDINGS=1 short-circuits before
// the cache is ever read — so the model is replaced by a counting fake instead.
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

const { calls } = vi.hoisted(() => ({ calls: [] as string[] }));
vi.mock('@huggingface/transformers', () => ({
  pipeline: async () => async (text: string) => {
    calls.push(text);
    const v = new Float32Array(384);
    for (let i = 0; i < text.length; i++) v[i % 384] += text.charCodeAt(i) / 1000;
    return { data: v };
  },
}));

import { buildEpisodicIndex } from './episodic-search.js';
import { embedTexts } from './embeddings.js';

const FILE = 's1_proj_2026-10-01.txt';
const RAW_TN = '<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>';
const ARCHIVE = [
  '--- session-meta ---', 'session_id: s1', 'project_slug: proj', 'date: 2026-10-01', '---', '',
  'USER: how do we archive the transcripts safely before telemetry runs',
  'ASSISTANT:',
  '  We copy them with a checked append and advance the cursor after.',
  `USER: ${RAW_TN}`,
  'ASSISTANT:',
  '  The background suite finished green, so the archive change is verified.',
  '',
].join('\n');

describe('episodic re-embed on a parser bump', () => {
  let brainDir: string;
  beforeEach(() => {
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;   // vitest.setup restores it afterwards
    brainDir = mkdtempSync(join(tmpdir(), 'epi-reembed-'));
    mkdirSync(join(brainDir, 'transcripts'), { recursive: true });
    process.env.SB_BRAIN_DIR = brainDir;
    writeFileSync(join(brainDir, 'transcripts', FILE), ARCHIVE, 'utf-8');
    calls.length = 0;
  });
  const readIndex = () => JSON.parse(readFileSync(join(brainDir, 'episodic-index.json'), 'utf-8'));

  it('a fresh build embeds every row once, a no-op rebuild embeds nothing', async () => {
    await buildEpisodicIndex(brainDir);
    expect(calls).toHaveLength(2);
    expect(readIndex().exchanges.every((e: any) => e.embedding.length === 384)).toBe(true);
    calls.length = 0;
    await buildEpisodicIndex(brainDir);
    expect(calls).toHaveLength(0);
  });

  it('migrating a parser-1 index re-embeds only the cleaned row', async () => {
    await buildEpisodicIndex(brainDir);
    const idx = readIndex();
    const [human, machine] = idx.exchanges;
    // Recreate what parser 1 left behind: the machine row stored (and embedded) the raw
    // boilerplate, and the file entry is a bare hash string.
    machine.userSnippet = RAW_TN;
    const parser1Text = `${machine.userSnippet}\n${machine.assistantSnippet}`.slice(0, 512);
    await embedTexts([parser1Text], join(brainDir, 'transcripts'), [`episodic:${machine.id}`]);
    idx.indexed_files[FILE] = idx.indexed_files[FILE].hash;
    writeFileSync(join(brainDir, 'episodic-index.json'), JSON.stringify(idx), 'utf-8');
    calls.length = 0;

    await buildEpisodicIndex(brainDir);

    // Exactly one model call, for the cleaned machine row; the human row hit the cache.
    expect(calls).toEqual([`\n${machine.assistantSnippet}`]);
    const after = readIndex();
    expect(after.exchanges.map((e: any) => e.id)).toEqual([human.id, machine.id]);
    expect(after.exchanges[1].userSnippet).toBe('');
    expect(after.exchanges.every((e: any) => e.embedding.length === 384)).toBe(true);
  });
});
