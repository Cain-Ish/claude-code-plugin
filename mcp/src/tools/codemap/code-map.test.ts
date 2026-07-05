import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { codeMap } from './code-map.js';
import { codemapDir, writeGraph } from './store.js';
import type { CodeGraph, FileNode } from './types.js';

const REV_A = 'a'.repeat(40);
const REV_B = 'b'.repeat(40);

// 40 files, rank desc / id asc (build-graph's tested ordering contract, which
// serialize trusts) with symbol payloads long enough that a 200-token budget
// must drop the tail.
function manyFiles(): FileNode[] {
  return Array.from({ length: 40 }, (_, i) => ({
    id: `src/file${String(i).padStart(2, '0')}.ts`,
    lang: 'ts' as const,
    rank: (40 - i) / 100,
    symbols: ['alpha', 'bravo', 'charlie', 'delta'],
  }));
}

function graphFixture(overrides: Partial<CodeGraph> = {}): CodeGraph {
  return {
    schema: 1,
    slug: 'proj',
    repo_root: join('some', 'repo'),
    git_rev: REV_A,
    dirty: false,
    generated_at: '2026-07-05T00:00:00.000Z',
    generator: 'regex-v1',
    truncated: false,
    files: manyFiles(),
    symbols: [],
    edges: [],
    ...overrides,
  };
}

// SB_CODEMAP_TOKEN_BUDGET leaks into serialize's default-parameter env read --
// clear it so an ambient developer environment cannot skew budget assertions.
const ENV_KEYS = ['SB_CODEMAP_TOKEN_BUDGET'];

describe('codeMap', () => {
  const saved: Record<string, string | undefined> = {};
  const tempDirs: string[] = [];

  beforeEach(() => {
    for (const k of ENV_KEYS) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });

  afterEach(() => {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    for (const d of tempDirs.splice(0)) rmSync(d, { recursive: true, force: true });
  });

  function tempBrain(): string {
    const brain = mkdtempSync(join(tmpdir(), 'sb-codemap-tool-'));
    tempDirs.push(brain);
    return brain;
  }

  async function storeGraph(graph: CodeGraph): Promise<string> {
    const brain = tempBrain();
    await writeGraph(codemapDir(brain, graph.slug), graph, 'unused-map-md\n');
    return brain;
  }

  const sameRev = async () => REV_A;

  it('returns the token-capped map with provenance fields', async () => {
    const graph = graphFixture();
    const brain = await storeGraph(graph);
    const res = await codeMap({ brainDir: brain, slug: 'proj', tokenBudget: 200, revProbe: sameRev });
    if (res.kind !== 'ok') throw new Error(`expected ok, got ${res.kind}`);
    expect(Math.ceil(res.map.length / 4)).toBeLessThanOrEqual(200); // cap invariant threaded through
    expect(res.map).toContain('src/file00.ts'); // highest rank present
    expect(res.map).not.toContain('src/file39.ts'); // lowest rank dropped
    expect(res.map).toContain('more files omitted');
    expect(res.generated_at).toBe('2026-07-05T00:00:00.000Z');
    expect(res.git_rev).toBe(REV_A);
    expect(res.generator).toBe('regex-v1');
    expect(res.truncated).toBe(false);
  });

  it('map is re-serialized from graph.json, not read from map.md', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeMap({ brainDir: brain, slug: 'proj', tokenBudget: 8000, revProbe: sameRev });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(res.map).not.toContain('unused-map-md');
    expect(res.map).toContain('src/file39.ts'); // large budget carries the whole graph
  });

  it('stale:false when the stored rev matches current HEAD', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeMap({ brainDir: brain, slug: 'proj', revProbe: sameRev });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(res.stale).toBe(false);
  });

  it('stale:true when the repo moved past the stored rev', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeMap({ brainDir: brain, slug: 'proj', revProbe: async () => REV_B });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(res.stale).toBe(true);
  });

  it("stale:false when the probe cannot resolve a rev ('nogit' tolerated)", async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeMap({ brainDir: brain, slug: 'proj', revProbe: async () => 'nogit' });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(res.stale).toBe(false);
  });

  it("stale:true when a 'nogit' store faces a real current rev (honest mismatch)", async () => {
    const brain = await storeGraph(graphFixture({ git_rev: 'nogit' }));
    const res = await codeMap({ brainDir: brain, slug: 'proj', revProbe: async () => REV_A });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(res.stale).toBe(true);
  });

  it("probes the graph's own repo_root, not the querying process cwd", async () => {
    const graph = graphFixture();
    const brain = await storeGraph(graph);
    const probed: string[] = [];
    await codeMap({
      brainDir: brain,
      slug: 'proj',
      revProbe: async (root) => {
        probed.push(root);
        return REV_A;
      },
    });
    expect(probed).toEqual([graph.repo_root]);
  });

  it('no store yet -> graceful notice (kind missing), not an error', async () => {
    const brain = tempBrain();
    const res = await codeMap({ brainDir: brain, slug: 'proj', revProbe: sameRev });
    if (res.kind !== 'missing') throw new Error(`expected missing, got ${res.kind}`);
    expect(res.notice).toMatch(/not generated yet/i);
    expect(res.notice).toMatch(/out-of-band/i);
  });

  it('missing store never invokes the rev probe (no pointless git spawn)', async () => {
    const brain = tempBrain();
    let called = 0;
    await codeMap({ brainDir: brain, slug: 'proj', revProbe: async () => { called++; return REV_A; } });
    expect(called).toBe(0);
  });

  it('corrupt graph.json propagates as a throw (fail loud), not a silent notice', async () => {
    const brain = tempBrain();
    const dir = codemapDir(brain, 'proj');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'graph.json'), 'not json {{{');
    await expect(codeMap({ brainDir: brain, slug: 'proj', revProbe: sameRev })).rejects.toThrow();
  });

  it('honors SB_CODEMAP_TOKEN_BUDGET when no explicit budget is passed', async () => {
    const brain = await storeGraph(graphFixture());
    process.env.SB_CODEMAP_TOKEN_BUDGET = '200';
    const res = await codeMap({ brainDir: brain, slug: 'proj', revProbe: sameRev });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(Math.ceil(res.map.length / 4)).toBeLessThanOrEqual(200);
    expect(res.map).toContain('more files omitted');
  });
});

describe('server.ts registration (code_map)', () => {
  const src = readFileSync(new URL('../../server.ts', import.meta.url), 'utf-8');

  it('registers the code_map tool', () => {
    expect(/registerTool\(\s*"code_map"/.test(src)).toBe(true);
  });

  it('read-only: code_map is NOT wrapped in guardDestructive', () => {
    expect(src.includes('guardDestructive("code_map"')).toBe(false);
  });
});
