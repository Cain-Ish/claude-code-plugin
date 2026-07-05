import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, readFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { codeNeighbors } from './code-neighbors.js';
import { codemapDir, writeGraph } from './store.js';
import type { CodeEdge, CodeGraph } from './types.js';

function fileNode(id: string, rank: number) {
  return { id, lang: 'ts' as const, rank, symbols: [] };
}

// A -> B, C -> B (the plan's fixture), plus B -> D for depth transitivity and
// two same-basename files for the ambiguity case.
function graphFixture(edges?: CodeEdge[]): CodeGraph {
  return {
    schema: 1,
    slug: 'proj',
    repo_root: join('some', 'repo'),
    git_rev: 'a'.repeat(40),
    dirty: false,
    generated_at: '2026-07-05T00:00:00.000Z',
    generator: 'regex-v1',
    truncated: false,
    files: [
      fileNode('src/a.ts', 0.5),
      fileNode('src/b.ts', 0.4),
      fileNode('src/c.ts', 0.3),
      fileNode('src/d.ts', 0.2),
      fileNode('lib/util.ts', 0.1),
      fileNode('sub/util.ts', 0.05),
    ],
    symbols: [{ id: 'src/b.ts#bee', kind: 'function', file: 'src/b.ts', rank: 0.4 }],
    edges: edges ?? [
      { from: 'src/a.ts', to: 'src/b.ts', type: 'imports' },
      { from: 'src/c.ts', to: 'src/b.ts', type: 'imports' },
      { from: 'src/b.ts', to: 'src/d.ts', type: 'imports' },
    ],
  };
}

const ENV_KEYS = ['SB_CODEMAP_NEIGHBORS_MAX'];

describe('codeNeighbors', () => {
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
    const brain = mkdtempSync(join(tmpdir(), 'sb-codemap-nbrs-'));
    tempDirs.push(brain);
    return brain;
  }

  async function storeGraph(graph: CodeGraph): Promise<string> {
    const brain = tempBrain();
    await writeGraph(codemapDir(brain, graph.slug), graph, 'map\n');
    return brain;
  }

  it("in-neighbors of B are its importers {A, C} (blast radius)", async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/b.ts', direction: 'in' });
    if (res.kind !== 'ok') throw new Error(`expected ok, got ${res.kind}`);
    expect(res.node).toBe('src/b.ts');
    expect(res.neighbors.map((r) => r.from)).toEqual(['src/a.ts', 'src/c.ts']);
    expect(res.neighbors.every((r) => r.to === 'src/b.ts' && r.hops === 1)).toBe(true);
  });

  it("out-neighbors of A are its dependencies {B}", async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/a.ts', direction: 'out' });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(res.neighbors).toEqual([{ from: 'src/a.ts', to: 'src/b.ts', type: 'imports', hops: 1 }]);
  });

  it('depth is transitive: in from D at depth 2 reaches A and C via B', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/d.ts', direction: 'in', depth: 2 });
    if (res.kind !== 'ok') throw new Error('expected ok');
    // sorted hops asc, then from asc, then to asc -- the determinism contract
    expect(res.neighbors).toEqual([
      { from: 'src/b.ts', to: 'src/d.ts', type: 'imports', hops: 1 },
      { from: 'src/a.ts', to: 'src/b.ts', type: 'imports', hops: 2 },
      { from: 'src/c.ts', to: 'src/b.ts', type: 'imports', hops: 2 },
    ]);
  });

  it('default depth is 1: in from D stops at B', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/d.ts', direction: 'in' });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(res.neighbors).toEqual([{ from: 'src/b.ts', to: 'src/d.ts', type: 'imports', hops: 1 }]);
  });

  it("default direction 'both': B sees importers {A, C} and dependency {D}", async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/b.ts' });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(res.direction).toBe('both');
    expect(res.neighbors).toHaveLength(3);
  });

  it('min-hop dedup: a diamond edge reachable at hops 1 and 2 reports hops 1 once', async () => {
    const brain = await storeGraph(
      graphFixture([
        { from: 'src/a.ts', to: 'src/b.ts', type: 'imports' },
        { from: 'src/b.ts', to: 'src/d.ts', type: 'imports' },
        { from: 'src/a.ts', to: 'src/d.ts', type: 'imports' },
      ]),
    );
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/a.ts', direction: 'out', depth: 3 });
    if (res.kind !== 'ok') throw new Error('expected ok');
    const ad = res.neighbors.filter((r) => r.from === 'src/a.ts' && r.to === 'src/d.ts');
    expect(ad).toEqual([{ from: 'src/a.ts', to: 'src/d.ts', type: 'imports', hops: 1 }]);
  });

  it('fuzzy: a unique basename resolves to its full id', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'b.ts', direction: 'in' });
    if (res.kind !== 'ok') throw new Error(`expected ok, got ${res.kind}`);
    expect(res.node).toBe('src/b.ts');
    expect(res.neighbors.map((r) => r.from)).toEqual(['src/a.ts', 'src/c.ts']);
  });

  it('fuzzy: an ambiguous basename returns ALL matches, never silently picks one', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'util.ts' });
    if (res.kind !== 'ambiguous') throw new Error(`expected ambiguous, got ${res.kind}`);
    expect(res.matches).toEqual(['lib/util.ts', 'sub/util.ts']);
    expect(res.note).toMatch(/ambiguous/i);
  });

  it('a symbol id resolves to its file (edges are file-level in schema v1)', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/b.ts#bee', direction: 'in' });
    if (res.kind !== 'ok') throw new Error(`expected ok, got ${res.kind}`);
    expect(res.node).toBe('src/b.ts');
    expect(res.neighbors).toHaveLength(2);
  });

  it('unknown node -> kind unknown (empty result), not an error', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'ghost.ts' });
    if (res.kind !== 'unknown') throw new Error(`expected unknown, got ${res.kind}`);
    expect(res.notice).toContain('ghost.ts');
  });

  it('no store yet -> graceful notice, not an error', async () => {
    const brain = tempBrain();
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/a.ts' });
    if (res.kind !== 'missing') throw new Error(`expected missing, got ${res.kind}`);
    expect(res.notice).toMatch(/not generated yet/i);
    expect(res.notice).toMatch(/out-of-band/i);
  });

  it('caps results via the max option and flags truncation', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/b.ts', direction: 'in', max: 1 });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(res.neighbors).toHaveLength(1);
    expect(res.neighbors[0].from).toBe('src/a.ts'); // deterministic slice: sorted first
    expect(res.truncated).toBe(true);
  });

  it('caps results via SB_CODEMAP_NEIGHBORS_MAX when no max option is passed', async () => {
    const brain = await storeGraph(graphFixture());
    process.env.SB_CODEMAP_NEIGHBORS_MAX = '1';
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/b.ts', direction: 'in' });
    if (res.kind !== 'ok') throw new Error('expected ok');
    expect(res.neighbors).toHaveLength(1);
    expect(res.truncated).toBe(true);
  });

  it('negative/garbage SB_CODEMAP_NEIGHBORS_MAX falls back to 50, never corrupts', async () => {
    // Regression: `Number(env)||default` let -3 through and .slice(0, -3)
    // CHOPPED THE TAIL of the result instead of capping it.
    const brain = await storeGraph(graphFixture());
    process.env.SB_CODEMAP_NEIGHBORS_MAX = '-3';
    let res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/b.ts', direction: 'in' });
    if (res.kind !== 'ok') throw new Error(`expected ok, got ${res.kind}`);
    expect(res.neighbors.map((r) => r.from)).toEqual(['src/a.ts', 'src/c.ts']);
    expect(res.truncated).toBe(false);
    process.env.SB_CODEMAP_NEIGHBORS_MAX = 'abc';
    res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/b.ts', direction: 'in' });
    if (res.kind !== 'ok') throw new Error(`expected ok, got ${res.kind}`);
    expect(res.neighbors).toHaveLength(2);
    expect(res.truncated).toBe(false);
  });

  it('ambiguous matches list is capped by max with a "showing N" note', async () => {
    const brain = await storeGraph(graphFixture());
    const res = await codeNeighbors({ brainDir: brain, slug: 'proj', node: 'util.ts', max: 1 });
    if (res.kind !== 'ambiguous') throw new Error(`expected ambiguous, got ${res.kind}`);
    expect(res.matches).toEqual(['lib/util.ts']); // sorted, then capped -- deterministic slice
    expect(res.note).toContain('2 files match');
    expect(res.note).toContain('showing 1');
  });

  it('rejects an out-of-range depth (fail loud below the zod surface)', async () => {
    const brain = await storeGraph(graphFixture());
    await expect(
      codeNeighbors({ brainDir: brain, slug: 'proj', node: 'src/a.ts', depth: 9 }),
    ).rejects.toThrow(/depth/);
  });

  // Plan C1: "code_map/code_neighbors compute stale the same way at query
  // time so a query between regens is honest" -- blast-radius answers from a
  // stale graph must carry the warning (skeptic-review finding: the flag was
  // missing here while code_map had it).
  it('ok result carries a query-time stale flag via the shared drift predicate', async () => {
    const brain = await storeGraph(graphFixture());
    const sameRev = async () => `${'a'.repeat(40)}\n`;
    const otherRev = async () => `${'b'.repeat(40)}\n`;
    const fresh = await codeNeighbors({
      brainDir: brain, slug: 'proj', node: 'src/b.ts', direction: 'in', runGit: sameRev,
    });
    if (fresh.kind !== 'ok') throw new Error(`expected ok, got ${fresh.kind}`);
    expect(fresh.stale).toBe(false);
    const drifted = await codeNeighbors({
      brainDir: brain, slug: 'proj', node: 'src/b.ts', direction: 'in', runGit: otherRev,
    });
    if (drifted.kind !== 'ok') throw new Error(`expected ok, got ${drifted.kind}`);
    expect(drifted.stale).toBe(true);
  });
});

describe('server.ts registration (code_neighbors)', () => {
  const src = readFileSync(new URL('../../server.ts', import.meta.url), 'utf-8');

  it('registers the code_neighbors tool', () => {
    expect(/registerTool\(\s*"code_neighbors"/.test(src)).toBe(true);
  });

  it('read-only: code_neighbors is NOT wrapped in guardDestructive', () => {
    expect(src.includes('guardDestructive("code_neighbors"')).toBe(false);
  });
});
