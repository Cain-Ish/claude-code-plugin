// R2#6 (0.56.0): the episodic index stores each vector as int8 components plus one per-vector
// scale, base64 (`e8`, `es`), not a float JSON array. The index is parsed on every prompt and a
// float array was ~8 KB of JSON text per row. Old float rows still read; the build (the index's
// only writer) writes them back compact, atomically, and a failed write-back is logged, never
// silent. Also here: item 3, an archive scrubbed in place (same line count, ORIGINAL mtime) is
// re-derived, and only its changed rows re-embed.
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { promises as fsp, mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, statSync, utimesSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

const h = vi.hoisted(() => {
  const calls: string[] = [];
  const state = { failIndexWrite: false };
  // A deterministic "model": a hashed bag of words, normalized, so cosine = word overlap.
  function fakeVec(text: string): Float32Array {
    const v = new Float32Array(384);
    for (const w of text.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean)) {
      let x = 7;
      for (let i = 0; i < w.length; i++) x = (x * 31 + w.charCodeAt(i)) >>> 0;
      v[x % 384] += 1 + (x % 7) / 10;
    }
    let n = 0;
    for (let i = 0; i < v.length; i++) n += v[i] * v[i];
    n = Math.sqrt(n) || 1;
    for (let i = 0; i < v.length; i++) v[i] /= n;
    return v;
  }
  return { calls, state, fakeVec };
});

vi.mock('@huggingface/transformers', () => ({
  pipeline: async () => async (text: string) => {
    h.calls.push(text);
    return { data: h.fakeVec(text) };
  },
}));

// The index write can be made to fail (ENOSPC, EACCES): both writers' contracts are kept, the
// swallowing one logs to stderr and returns, the strict one rejects. Only the index path fails.
vi.mock('./atomic-write.js', async (importOriginal) => {
  const orig = await importOriginal<typeof import('./atomic-write.js')>();
  const failing = (p: string) => h.state.failIndexWrite && p.endsWith('episodic-index.json');
  return {
    ...orig,
    atomicWriteJson: async (p: string, v: unknown) => {
      if (failing(p)) { console.error(`atomicWriteJson: FAILED to write ${p}: simulated ENOSPC`); return; }
      return orig.atomicWriteJson(p, v);
    },
    atomicWriteJsonStrict: async (p: string, v: unknown) => {
      if (failing(p)) throw new Error('ENOSPC: no space left on device (simulated)');
      return orig.atomicWriteJsonStrict(p, v);
    },
  };
});

import {
  buildEpisodicIndex, episodicSearch, quantizeEmbedding, embeddingSimilarity,
} from './episodic-search.js';
import { embedTexts } from './embeddings.js';

const FILE = 's1_proj_2026-10-01.txt';
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
const indexPath = () => join(brainDir, 'episodic-index.json');
const readIndex = () => JSON.parse(readFileSync(indexPath(), 'utf-8'));
const errorRows = (): any[] => {
  const p = join(brainDir, 'error-log.jsonl');
  return existsSync(p) ? readFileSync(p, 'utf-8').trim().split('\n').map(l => JSON.parse(l)) : [];
};
const embedText = (r: any) => `${r.userSnippet}\n${r.assistantSnippet}`.slice(0, 512);
/** A row's stored vector, whichever format holds it (the item-3 lock is format-agnostic). */
const vecOf = (r: any): number[] => (typeof r.e8 === 'string' && r.e8
  ? Array.from(new Int8Array(Buffer.from(r.e8, 'base64'))).map(q => q * r.es)
  : Array.isArray(r.embedding) ? r.embedding : []);
const dot = (a: ArrayLike<number>, b: ArrayLike<number>) => {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i] * b[i];
  return s;
};

/** What a pre-0.56.0 writer left on disk: float `embedding` arrays, no e8/es. */
function writeLegacyIndex(): string {
  const idx = readIndex();
  idx.exchanges = idx.exchanges.map((r: any) => {
    const { e8: _e8, es: _es, embedding: _emb, ...rest } = r;
    return { ...rest, embedding: Array.from(h.fakeVec(embedText(r))) };
  });
  const body = JSON.stringify(idx);
  writeFileSync(indexPath(), body, 'utf-8');
  return body;
}

beforeEach(() => {
  delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;   // vitest.setup restores it afterwards
  h.state.failIndexWrite = false;
  h.calls.length = 0;
  brainDir = mkdtempSync(join(tmpdir(), 'epi-compact-'));
  mkdirSync(join(brainDir, 'transcripts'), { recursive: true });
  process.env.SB_BRAIN_DIR = brainDir;
  writeFileSync(join(brainDir, 'transcripts', FILE), ARCHIVE, 'utf-8');
});

describe('quantizeEmbedding / embeddingSimilarity', () => {
  it('stores 384 int8 components and a scale; similarity is the dot with the dequantized vector', () => {
    const v = h.fakeVec('archive the transcripts before telemetry runs safely');
    const q = h.fakeVec('archive transcripts safely');
    const row = quantizeEmbedding(v);
    const bytes = new Int8Array(Buffer.from(row.e8, 'base64'));
    expect(bytes.length).toBe(384);
    const maxAbs = Math.max(...Array.from(v, Math.abs));
    expect(row.es).toBeCloseTo(maxAbs / 127, 12);
    expect(Math.max(...Array.from(bytes, Math.abs))).toBe(127);       // the full int8 range is used
    for (let i = 0; i < 384; i++) expect(Math.abs(bytes[i] * row.es - v[i])).toBeLessThanOrEqual(row.es / 2 + 1e-9);
    expect(Math.abs(embeddingSimilarity(Array.from(q), row) - dot(q, v))).toBeLessThan(2e-3);
    // A dense vector (a real model's shape): every component within half a step.
    const dense = Float32Array.from({ length: 384 }, (_, i) => Math.sin(i * 1.7 + 0.3) / 14);
    const d = quantizeEmbedding(dense);
    const db = new Int8Array(Buffer.from(d.e8, 'base64'));
    for (let i = 0; i < 384; i++) expect(Math.abs(db[i] * d.es - dense[i])).toBeLessThanOrEqual(d.es / 2 + 1e-9);
  });

  it('a zero vector is a valid vector with similarity 0 (no NaN)', () => {
    const row = quantizeEmbedding(new Float32Array(384));
    expect(row.es).toBe(0);
    expect(embeddingSimilarity(Array.from(h.fakeVec('anything')), row)).toBe(0);
  });
});

describe('episodic index format', () => {
  it('a build stores e8/es and never a float array', async () => {
    await buildEpisodicIndex(brainDir);
    expect(h.calls).toHaveLength(2);
    const rows = readIndex().exchanges;
    expect(rows).toHaveLength(2);
    for (const r of rows) {
      expect(r).not.toHaveProperty('embedding');
      expect(typeof r.e8).toBe('string');
      expect(Buffer.from(r.e8, 'base64')).toHaveLength(384);
      expect(r.es).toBeGreaterThan(0);
      // The stored vector is the model's vector, to within half a quantization step.
      const want = h.fakeVec(embedText(r));
      const got = vecOf(r);
      for (let i = 0; i < 384; i++) expect(Math.abs(got[i] - want[i])).toBeLessThanOrEqual(r.es / 2 + 1e-9);
    }
  });

  it('a legacy float index is read as-is by search (which never writes) and migrated by the next build without a model call', async () => {
    await buildEpisodicIndex(brainDir);
    const legacy = writeLegacyIndex();
    const ids = readIndex().exchanges.map((r: any) => r.id);
    h.calls.length = 0;

    // The per-prompt path reads the legacy rows' vectors and leaves the file alone: the builder
    // is the index's only writer (a search that loaded before a build and saved after it would
    // drop the build's rows).
    const before = await episodicSearch({ query: 'archive transcripts telemetry', mode: 'vector' }, brainDir);
    expect(before.degraded).toBeUndefined();
    expect(before.results[0].userSnippet).toMatch(/^how do we archive/);
    expect(readFileSync(indexPath(), 'utf-8')).toBe(legacy);

    h.calls.length = 0;
    const r = await buildEpisodicIndex(brainDir);
    expect(h.calls).toEqual([]);                    // converted, not re-embedded
    expect(r.pending).toBe(0);
    const after = readIndex();
    expect(after.exchanges.map((e: any) => e.id)).toEqual(ids);
    for (const e of after.exchanges) {
      expect(e).not.toHaveProperty('embedding');
      expect(Buffer.from(e.e8, 'base64')).toHaveLength(384);
    }

    // Same ranking and near-identical scores from the compact rows.
    const res = await episodicSearch({ query: 'archive transcripts telemetry', mode: 'vector' }, brainDir);
    expect(res.results.map(x => x.lineStart)).toEqual(before.results.map(x => x.lineStart));
    res.results.forEach((x, i) => expect(Math.abs(x.similarity - before.results[i].similarity)).toBeLessThanOrEqual(0.005));

    // Written back once: a second build leaves the bytes alone.
    const once = readFileSync(indexPath(), 'utf-8');
    await buildEpisodicIndex(brainDir);
    expect(readFileSync(indexPath(), 'utf-8')).toBe(once);
  });

  it('a failed write-back keeps the legacy index intact and is logged; the next build migrates', async () => {
    await buildEpisodicIndex(brainDir);
    const legacy = writeLegacyIndex();
    h.state.failIndexWrite = true;

    await buildEpisodicIndex(brainDir);

    expect(readFileSync(indexPath(), 'utf-8')).toBe(legacy);    // no torn or emptied index
    const rows = errorRows().filter(e => e.script === 'episodic-index');
    expect(rows).toHaveLength(1);
    expect(rows[0].message).toMatch(/episodic index write failed/);
    expect(rows[0].message).toMatch(/ENOSPC/);

    h.state.failIndexWrite = false;
    await buildEpisodicIndex(brainDir);
    expect(readIndex().exchanges.every((e: any) => typeof e.e8 === 'string' && !('embedding' in e))).toBe(true);
  });

  it('a stored e8 that is not 384 components is dropped, logged and re-embedded', async () => {
    await buildEpisodicIndex(brainDir);
    const idx = readIndex();
    const good = idx.exchanges[1];
    const { embedding: _emb, ...bad } = idx.exchanges[0];
    idx.exchanges[0] = { ...bad, e8: Buffer.from(new Int8Array(10)).toString('base64'), es: 0.01 };
    idx.exchanges[1] = { ...good, ...quantizeEmbedding(h.fakeVec(embedText(good))) };
    delete idx.exchanges[1].embedding;
    writeFileSync(indexPath(), JSON.stringify(idx), 'utf-8');
    // Without the cache, a re-embed is a model call, so "only the bad row" is observable.
    rmSync(join(brainDir, 'transcripts', '.embeddings-cache.json'), { force: true });
    h.calls.length = 0;

    const r = await buildEpisodicIndex(brainDir);

    expect(h.calls).toEqual([embedText(idx.exchanges[0])]);     // only the bad row
    expect(r.pending).toBe(0);
    const after = readIndex();
    expect(Buffer.from(after.exchanges[0].e8, 'base64')).toHaveLength(384);
    expect(after.exchanges[1].e8).toBe(idx.exchanges[1].e8);
    const rows = errorRows().filter(e => e.script === 'episodic-index');
    expect(rows).toHaveLength(1);
    expect(rows[0].message).toMatch(/1 stored vector.*not 384 components/);
  });
});

// Item 3: R2-A's sb_scrub_archive_file rewrites an archive in place: same line count, different
// size, ORIGINAL mtime restored with `touch -r`. The indexer decides what to re-parse from a hash
// of the file's (invisible-stripped) CONTENT, never mtime or size, so the scrubbed file is
// re-derived. Row ids come from path + line range, so they hold; the vector carry-over keeps
// every row whose snippet text is unchanged, and the cache key's text hash re-embeds the rest.
describe('re-derivation after an in-place archive scrub', () => {
  const KEY = 'sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_xyz';
  const SECRET_ARCHIVE = [
    '--- session-meta ---', 'session_id: s2', 'project_slug: proj', 'date: 2026-10-02', '---', '',
    `USER: the deploy failed, here is the key ${KEY} please rotate it today`,
    'ASSISTANT:',
    '  Rotated. The old key is revoked in the console and the deploy is green.',
    'USER: how do we archive the transcripts safely before telemetry runs',
    'ASSISTANT:',
    '  We copy them with a checked append and advance the cursor after.',
    '',
  ].join('\n');
  const SFILE = 's2_proj_2026-10-02.txt';
  const ORIGINAL_MTIME = new Date('2026-10-02T08:00:00Z');

  it('a same-line-count rewrite with the original mtime is re-derived; only the changed row re-embeds', async () => {
    const sp = join(brainDir, 'transcripts', SFILE);
    writeFileSync(sp, SECRET_ARCHIVE, 'utf-8');
    utimesSync(sp, ORIGINAL_MTIME, ORIGINAL_MTIME);
    await buildEpisodicIndex(brainDir);
    const before = readIndex().exchanges.filter((r: any) => r.sessionId === 's2');
    expect(before).toHaveLength(2);
    expect(before[0].userSnippet).toContain(KEY);

    // The scrub: same lines, a different size, the original mtime.
    const scrubbed = SECRET_ARCHIVE.replace(KEY, '[redacted:anthropic]');
    writeFileSync(sp, scrubbed, 'utf-8');
    utimesSync(sp, ORIGINAL_MTIME, ORIGINAL_MTIME);
    expect(scrubbed.split('\n')).toHaveLength(SECRET_ARCHIVE.split('\n').length);
    expect(scrubbed.length).not.toBe(SECRET_ARCHIVE.length);
    expect(statSync(sp).mtimeMs).toBe(ORIGINAL_MTIME.getTime());
    h.calls.length = 0;

    const r = await buildEpisodicIndex(brainDir);

    const after = readIndex().exchanges.filter((x: any) => x.sessionId === 's2');
    expect(after.map((x: any) => x.id)).toEqual(before.map((x: any) => x.id));
    expect(after[0].userSnippet).toBe('the deploy failed, here is the key [redacted:anthropic] please rotate it today');
    expect(h.calls).toEqual([embedText(after[0])]);               // the changed row, once
    expect(vecOf(after[1])).toEqual(vecOf(before[1]));            // the unchanged row kept its vector
    expect(vecOf(after[0]).length).toBe(384);
    expect(r.pending).toBe(0);
    expect(readFileSync(indexPath(), 'utf-8')).not.toContain('sk-ant-');
  });
});

// Recall parity on a fixed, seeded 700-row fixture (the live index holds ~707 rows): int8 ranks
// the same top 10 as float for >= 99% of the slots, and the stored rows are >= 5x smaller.
describe('recall parity and size, int8 vs float', () => {
  function rng(seed: number): () => number {
    let s = seed >>> 0;
    return () => {
      s = (s + 0x6d2b79f5) >>> 0;
      let t = s;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function fixture() {
    const r = rng(20261006);
    const gauss = () => Math.sqrt(-2 * Math.log(r() || 1e-12)) * Math.cos(2 * Math.PI * r());
    const unit = (v: number[]) => { const n = Math.sqrt(dot(v, v)) || 1; return v.map(x => x / n); };
    const noise = (scale: number) => Array.from({ length: 384 }, () => gauss() * scale / Math.sqrt(384));
    const centers = Array.from({ length: 35 }, () => unit(noise(1)));
    const rows = Array.from({ length: 700 }, (_, i) => {
      const n = noise(1);
      return unit(centers[i % 35].map((c, k) => c + n[k]));
    });
    const queries = Array.from({ length: 50 }, (_, j) => {
      const n = noise(0.8);
      return unit(rows[(j * 13) % 700].map((x, k) => x + n[k]));
    });
    return { rows, queries };
  }
  const topK = (scores: number[], k: number) =>
    scores.map((s, i) => [s, i] as const).sort((a, b) => b[0] - a[0]).slice(0, k).map(x => x[1]);

  it('top-10 overlap >= 0.99 over 50 queries and the stored vectors are >= 5x smaller', () => {
    const { rows, queries } = fixture();
    const compact = rows.map(v => quantizeEmbedding(v));
    let overlap = 0;
    for (const q of queries) {
      const f = topK(rows.map(v => dot(q, v)), 10);
      const c = new Set(topK(compact.map(row => embeddingSimilarity(q, row)), 10));
      overlap += f.filter(i => c.has(i)).length / 10;
    }
    expect(overlap / queries.length).toBeGreaterThanOrEqual(0.99);
    const floatBytes = JSON.stringify(rows.map(v => ({ embedding: v }))).length;
    const compactBytes = JSON.stringify(compact).length;
    expect(floatBytes / compactBytes).toBeGreaterThanOrEqual(5);
  });
});

// The per-prompt query embed passes no cache key, so the embedding cache can never answer it (only
// keyed entries are ever saved). It used to parse transcripts/.embeddings-cache.json (5.7 MB on the
// live box, ~9 ms) on every prompt anyway.
describe('embedTexts — a keyless (query) embed does not read the cache', () => {
  it('skips the cache file for a query, still reads and writes it for keyed texts', async () => {
    const dir = join(brainDir, 'transcripts');
    writeFileSync(join(dir, '.embeddings-cache.json'),
      JSON.stringify({ model: 'Xenova/all-MiniLM-L6-v2', entries: {} }), 'utf-8');
    const spy = vi.spyOn(fsp, 'readFile');
    try {
      const q = await embedTexts(['archive transcripts'], dir, ['']);
      expect(q?.[0]).toHaveLength(384);
      const cacheReads = () => spy.mock.calls.filter(c => String(c[0]).endsWith('.embeddings-cache.json')).length;
      expect(cacheReads()).toBe(0);
      await embedTexts(['archive transcripts'], dir, ['episodic:x']);
      expect(cacheReads()).toBe(1);
      expect(JSON.parse(readFileSync(join(dir, '.embeddings-cache.json'), 'utf-8')).entries['episodic:x']).toBeDefined();
    } finally {
      spy.mockRestore();
    }
  });
});
