import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { serialize } from './serialize.js';
import type { CodeGraph, FileNode } from './types.js';

function graphOf(files: FileNode[]): CodeGraph {
  return {
    schema: 1,
    slug: 'proj',
    repo_root: '/repo',
    git_rev: 'abc1234',
    dirty: false,
    generated_at: '2026-07-05T00:00:00.000Z',
    generator: 'regex-v1',
    truncated: false,
    files,
    symbols: [],
    edges: [],
  };
}

function fileNode(id: string, rank: number, symbols: string[]): FileNode {
  return { id, lang: 'ts', rank, symbols };
}

/** n files, rank-desc -- the build-graph output ordering serialize trusts. */
function bigGraph(n: number): CodeGraph {
  const files: FileNode[] = [];
  for (let i = 0; i < n; i++) {
    files.push(
      fileNode(`src/f${String(i).padStart(3, '0')}.ts`, (n - i) / (10 * n), [
        `alpha${i}`,
        `beta${i}`,
        `gamma${i}`,
      ]),
    );
  }
  return graphOf(files);
}

/** chars/4 -- the same coarse token model the serializer budgets with. */
function estimateTokens(text: string): number {
  return text.length / 4;
}

describe('serialize', () => {
  let savedBudget: string | undefined;

  beforeEach(() => {
    savedBudget = process.env.SB_CODEMAP_TOKEN_BUDGET;
    delete process.env.SB_CODEMAP_TOKEN_BUDGET;
  });

  afterEach(() => {
    if (savedBudget === undefined) delete process.env.SB_CODEMAP_TOKEN_BUDGET;
    else process.env.SB_CODEMAP_TOKEN_BUDGET = savedBudget;
  });

  it('renders "path <emdash> symbol, symbol" lines in graph.files (rank-desc) order', () => {
    const g = graphOf([
      fileNode('src/main.ts', 0.5, ['run', 'Main']),
      fileNode('src/util.ts', 0.3, []),
    ]);
    expect(serialize(g, 2000)).toBe('src/main.ts \u2014 run, Main\nsrc/util.ts\n');
  });

  it('returns an empty string for an empty graph', () => {
    expect(serialize(graphOf([]), 2000)).toBe('');
  });

  it('INVARIANT: never exceeds the budget for an overflowing graph', () => {
    const budget = 100;
    const md = serialize(bigGraph(80), budget);
    expect(estimateTokens(md)).toBeLessThanOrEqual(budget);
    // Highest-rank file present, lowest-rank omitted.
    expect(md).toContain('src/f000.ts');
    expect(md).not.toContain('src/f079.ts');
  });

  it('footer counts exactly the files the cap omitted', () => {
    const md = serialize(bigGraph(80), 100);
    const m = md.match(/\(\+(\d+) more files omitted\)\n$/);
    expect(m).not.toBeNull();
    const omitted = Number(m![1]);
    expect(omitted).toBeGreaterThan(0);
    const included = md.trimEnd().split('\n').length - 1; // minus the footer line
    expect(included + omitted).toBe(80);
  });

  it('emits every file and no footer when the budget fits everything', () => {
    const g = bigGraph(5);
    const md = serialize(g, 2000);
    for (const f of g.files) expect(md).toContain(f.id);
    expect(md).not.toContain('omitted');
  });

  it('is deterministic: identical input yields byte-identical output', () => {
    const g = bigGraph(40);
    expect(serialize(g, 150)).toBe(serialize(g, 150));
  });

  it('reads the default budget from SB_CODEMAP_TOKEN_BUDGET', () => {
    process.env.SB_CODEMAP_TOKEN_BUDGET = '100';
    expect(serialize(bigGraph(80))).toBe(serialize(bigGraph(80), 100));
  });

  it('falls back to 2000 when the env override is unset or invalid', () => {
    // 400 files overflow a 2000-token budget, so the equality below is only
    // true if the fallback default actually bites (not a vacuous pass).
    const g = bigGraph(400);
    const at2000 = serialize(g, 2000);
    expect(md_omits(at2000)).toBe(true);
    delete process.env.SB_CODEMAP_TOKEN_BUDGET;
    expect(serialize(g)).toBe(at2000);
    process.env.SB_CODEMAP_TOKEN_BUDGET = 'abc';
    expect(serialize(g)).toBe(at2000);
    process.env.SB_CODEMAP_TOKEN_BUDGET = '0';
    expect(serialize(g)).toBe(at2000);
  });

  it('falls back to 2000 on a negative or garbage env budget instead of throwing', () => {
    // Regression: `Number(env)||default` passed -500 through as truthy,
    // serialize threw, the fail-soft CLI swallowed it, and codemap generation
    // was PERMANENTLY disabled for that environment. 400 files overflow the
    // 2000 default, so the equality proves the fallback bites (non-vacuous).
    const g = bigGraph(400);
    const at2000 = serialize(g, 2000);
    expect(md_omits(at2000)).toBe(true);
    process.env.SB_CODEMAP_TOKEN_BUDGET = '-500';
    expect(() => serialize(g)).not.toThrow();
    expect(serialize(g)).toBe(at2000);
    process.env.SB_CODEMAP_TOKEN_BUDGET = 'abc';
    expect(serialize(g)).toBe(at2000);
  });

  it('INVARIANT holds when the top-ranked line alone exceeds the whole budget', () => {
    const budget = 100; // capChars = 380; the giant line is ~515 chars
    const g = graphOf([
      fileNode('src/giant.ts', 0.9, ['w'.repeat(500)]),
      fileNode('src/small-a.ts', 0.5, []),
      fileNode('src/small-b.ts', 0.4, []),
    ]);
    const md = serialize(g, budget);
    expect(estimateTokens(md)).toBeLessThanOrEqual(budget);
    expect(md).not.toContain('src/giant.ts');
    // The unemittable line is counted in the footer, never silently lost.
    const m = md.match(/\(\+(\d+) more files omitted\)\n$/);
    expect(m).not.toBeNull();
    expect(Number(m![1])).toBe(3);
  });

  it('throws (fail loud) on a non-positive or non-finite explicit budget', () => {
    const g = bigGraph(3);
    expect(() => serialize(g, 0)).toThrow(/tokenBudget/);
    expect(() => serialize(g, -5)).toThrow(/tokenBudget/);
    expect(() => serialize(g, Number.NaN)).toThrow(/tokenBudget/);
  });

  it('throws (fail loud) when the budget cannot even fit the omission footer', () => {
    expect(() => serialize(bigGraph(10), 2)).toThrow(/too small/);
  });
});

function md_omits(md: string): boolean {
  return /\(\+\d+ more files omitted\)\n$/.test(md);
}
