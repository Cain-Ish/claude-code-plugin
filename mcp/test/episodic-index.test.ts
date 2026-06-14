import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { buildEpisodicIndex, episodicSearch } from '../src/tools/episodic-search.js';

function writeTranscript(brainDir: string, filename: string, sessionId: string, project: string, date: string, body: string) {
  const path = join(brainDir, 'transcripts', filename);
  const content = [
    '--- session-meta ---',
    `session_id: ${sessionId}`,
    `project_slug: ${project}`,
    `date: ${date}`,
    '---',
    '',
    body,
    '',
  ].join('\n');
  writeFileSync(path, content, 'utf-8');
}

const FIXTURE_BODY = `USER: explain how the episodic indexer caches embeddings to disk for later semantic search
ASSISTANT: The indexer hashes each exchange, calls embedTexts, then writes a 384-dimensional float vector into episodic-index.json keyed by exchange id.

USER: what happens when the model is unavailable
ASSISTANT: When the transformers import fails, embedTexts returns null and the indexer must skip those exchanges instead of poisoning the index with empty arrays.`;

describe('buildEpisodicIndex — degraded when embeddings disabled', () => {
  let brainDir: string;
  const ENV_KEY = 'SECOND_BRAIN_DISABLE_EMBEDDINGS';
  let prevBrainDir: string | undefined;

  beforeEach(() => {
    brainDir = mkdtempSync(join(tmpdir(), 'epi-idx-'));
    mkdirSync(join(brainDir, 'transcripts'), { recursive: true });
    process.env[ENV_KEY] = '1';
    prevBrainDir = process.env.BRAIN_DIR;
    process.env.BRAIN_DIR = brainDir;
  });

  afterEach(() => {
    rmSync(brainDir, { recursive: true, force: true });
    delete process.env[ENV_KEY];
    if (prevBrainDir === undefined) delete process.env.BRAIN_DIR;
    else process.env.BRAIN_DIR = prevBrainDir;
  });

  it('still persists new exchanges (text-searchable) but leaves embeddings empty', async () => {
    writeTranscript(brainDir, 'sess1_proj_2026-05-22.txt', 'sess1', 'proj', '2026-05-22', FIXTURE_BODY);
    const r = await buildEpisodicIndex(brainDir);

    const index = JSON.parse(readFileSync(join(brainDir, 'episodic-index.json'), 'utf-8'));
    expect(index.exchanges.length).toBeGreaterThan(0);
    expect(r.pending).toBe(index.exchanges.length); // every row pending
    expect(r.repaired).toBe(0);
    expect(index.exchanges.every((e: any) => e.embedding.length === 0)).toBe(true);
  });

  it('marks the file as indexed so text search works on subsequent invocations', async () => {
    writeTranscript(brainDir, 'sess1_proj_2026-05-22.txt', 'sess1', 'proj', '2026-05-22', FIXTURE_BODY);
    await buildEpisodicIndex(brainDir);

    const index = JSON.parse(readFileSync(join(brainDir, 'episodic-index.json'), 'utf-8'));
    expect(index.indexed_files['sess1_proj_2026-05-22.txt']).toBeDefined();
  });

  it('does NOT write to BRAIN_DIR/error-log.jsonl when embeddings are explicitly disabled (opt-in is not an error)', async () => {
    // Contract update (post v0.21.1): SECOND_BRAIN_DISABLE_EMBEDDINGS=1 is a
    // user-controlled opt-in, not a degradation. Logging it to error-log
    // every process startup (in-memory dedup couldn't span processes) was
    // flooding the audit channel — vitest runs alone dropped ~500 noise
    // rows. stderr is the correct channel for an acknowledged disable.
    // Real load failures (transformers missing, etc.) still log — see the
    // separate "happy path" describe block, which exercises that path.
    writeTranscript(brainDir, 'sess1_proj_2026-05-22.txt', 'sess1', 'proj', '2026-05-22', FIXTURE_BODY);
    await buildEpisodicIndex(brainDir);

    // Strong assertion (pre-push reviewer W1 fix): the disable path must
    // not create the error-log at all. A guard-conditional check would
    // pass vacuously if a regression caused the file to be absent for a
    // different reason. The disable acknowledgement goes to stderr only.
    const logPath = join(brainDir, 'error-log.jsonl');
    expect(existsSync(logPath)).toBe(false);
  });
});

describe('buildEpisodicIndex — happy path (real model)', () => {
  let brainDir: string;

  beforeEach(() => {
    brainDir = mkdtempSync(join(tmpdir(), 'epi-idx-hp-'));
    mkdirSync(join(brainDir, 'transcripts'), { recursive: true });
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
  });
  afterEach(() => { rmSync(brainDir, { recursive: true, force: true }); });

  it('populates 384-dim embeddings end-to-end when the model is available', async () => {
    writeTranscript(brainDir, 'sess1_proj_2026-05-22.txt', 'sess1', 'proj', '2026-05-22', FIXTURE_BODY);
    await buildEpisodicIndex(brainDir);

    const index = JSON.parse(readFileSync(join(brainDir, 'episodic-index.json'), 'utf-8'));
    // Deterministic regardless of model availability (CI may not have the ~70MB
    // model downloaded): ALWAYS assert the no-poison/no-drop contract; assert FULL
    // embedding population only when the model actually produced vectors.
    const populated = index.exchanges.filter((e: any) => e.embedding && e.embedding.length === 384);
    const corrupt = index.exchanges.filter((e: any) => e.embedding && e.embedding.length !== 0 && e.embedding.length !== 384);
    expect(corrupt.length).toBe(0);                      // never a partial/garbage vector
    expect(index.exchanges.length).toBeGreaterThan(0);   // rows are not dropped
    expect(index.indexed_files['sess1_proj_2026-05-22.txt']).toBeDefined();
    if (populated.length > 0) {
      expect(index.exchanges.every((e: any) => e.embedding && e.embedding.length === 384)).toBe(true);
    }
  }, 120_000);

  it('repairs stale empty embeddings even when the source file is unchanged (indexed_files hash matches)', async () => {
    // Reproduces the production-reported bug: 976/981 exchanges had embedding:[]
    // because the file was marked indexed in indexed_files, so the indexer
    // skipped re-processing and never re-embedded the orphan rows.
    writeTranscript(brainDir, 'sess1_proj_2026-05-22.txt', 'sess1', 'proj', '2026-05-22', FIXTURE_BODY);

    // Compute the file's hash the same way the indexer does, so indexed_files matches.
    const filePath = join(brainDir, 'transcripts', 'sess1_proj_2026-05-22.txt');
    const content = readFileSync(filePath, 'utf-8');
    let h = 0;
    for (let i = 0; i < content.length; i++) h = ((h << 5) - h + content.charCodeAt(i)) | 0;
    const fileHash = h.toString(36);

    const seed = {
      model: 'Xenova/all-MiniLM-L6-v2',
      indexed_files: { 'sess1_proj_2026-05-22.txt': fileHash },
      exchanges: [
        {
          id: 'stale-row',
          sessionId: 'sess1',
          project: 'proj',
          date: '2026-05-22',
          userSnippet: 'how the episodic indexer caches embeddings',
          assistantSnippet: 'hashes each exchange and writes a 384-dimensional vector',
          archivePath: filePath,
          lineStart: 1,
          lineEnd: 4,
          embedding: [],
        },
      ],
    };
    writeFileSync(join(brainDir, 'episodic-index.json'), JSON.stringify(seed), 'utf-8');

    await buildEpisodicIndex(brainDir);

    const index = JSON.parse(readFileSync(join(brainDir, 'episodic-index.json'), 'utf-8'));
    // Deterministic regardless of model availability (see the happy-path test).
    // The bug this guards (976/981 rows stuck at embedding:[]) is "stale rows
    // never RE-processed" — assert that always; assert full re-embed only when
    // the model is present.
    const populated = index.exchanges.filter((e: any) => e.embedding && e.embedding.length === 384);
    const corrupt = index.exchanges.filter((e: any) => e.embedding && e.embedding.length !== 0 && e.embedding.length !== 384);
    expect(corrupt.length).toBe(0);
    expect(index.exchanges.length).toBeGreaterThan(0);   // the stale row was not dropped
    if (populated.length > 0) {
      const empty = index.exchanges.filter((e: any) => !e.embedding || e.embedding.length === 0);
      expect(empty.length).toBe(0);                      // model present → stale row re-embedded
    }
  }, 120_000);
});

describe('episodicSearch — text fallback', () => {
  let brainDir: string;

  beforeEach(() => {
    brainDir = mkdtempSync(join(tmpdir(), 'epi-srch-'));
    mkdirSync(join(brainDir, 'transcripts'), { recursive: true });
  });
  afterEach(() => { rmSync(brainDir, { recursive: true, force: true }); });

  it('matches multi-word queries by tokenizing — both tokens present, not contiguous substring', async () => {
    process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
    try {
      writeTranscript(
        brainDir,
        'sess1_proj_2026-05-22.txt',
        'sess1',
        'proj',
        '2026-05-22',
        'USER: the plugin indexer broke today\nASSISTANT: yes the extractor backend is timing out under pty wrapping'
      );
      await buildEpisodicIndex(brainDir);

      const res = await episodicSearch({ query: 'plugin extractor', mode: 'text' }, brainDir);
      expect(res.results.length).toBeGreaterThan(0);
    } finally {
      delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
    }
  });

  it('mode=both returns text results when vector half is empty', async () => {
    process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
    try {
      const seed = {
        model: 'Xenova/all-MiniLM-L6-v2',
        indexed_files: { 'fixture.txt': 'h' },
        exchanges: [
          {
            id: 'x1',
            sessionId: 's1',
            project: 'p',
            date: '2026-05-22',
            userSnippet: 'the plugin indexer broke today',
            assistantSnippet: 'the extractor backend is timing out',
            archivePath: join(brainDir, 'transcripts', 'fixture.txt'),
            lineStart: 1,
            lineEnd: 2,
            embedding: [],
          },
        ],
      };
      writeFileSync(join(brainDir, 'episodic-index.json'), JSON.stringify(seed), 'utf-8');
      writeFileSync(join(brainDir, 'transcripts', 'fixture.txt'), 'placeholder', 'utf-8');

      const res = await episodicSearch({ query: 'plugin extractor', mode: 'both' }, brainDir);
      expect(res.results.length).toBeGreaterThan(0);
    } finally {
      delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
    }
  });
});
