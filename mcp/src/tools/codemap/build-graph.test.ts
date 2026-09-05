import { describe, it, expect } from 'vitest';
import { buildGraph, type GraphMeta } from './build-graph.js';
import { pagerank } from './pagerank.js';
import type { ExtractResult, ExtractedSymbol, Lang, ScannedFile } from './types.js';

const META: GraphMeta = {
  slug: 'proj',
  repoRoot: '/repo',
  gitRev: 'abc1234',
  dirty: false,
  generatedAt: '2026-07-05T00:00:00.000Z',
  truncated: false,
};

function sf(id: string, lang: Lang = 'ts'): ScannedFile {
  return { id, abs: '/repo/' + id, lang };
}

function ex(symbols: ExtractedSymbol[], imports: string[], externalImports = 0): ExtractResult {
  return { symbols, imports, externalImports };
}

// a -> b, a -> c, b -> c: c outranks b outranks a (mirrors the pagerank fixture).
function chainFixture(): { scanned: ScannedFile[]; extracted: Map<string, ExtractResult> } {
  const scanned = [sf('src/a.ts'), sf('src/b.ts'), sf('src/c.ts')];
  const extracted = new Map<string, ExtractResult>([
    ['src/a.ts', ex([{ name: 'foo', kind: 'function' }], ['src/b.ts', 'src/c.ts'])],
    ['src/b.ts', ex([{ name: 'Bar', kind: 'class' }], ['src/c.ts'])],
    ['src/c.ts', ex([{ name: 'baz', kind: 'const' }], [])],
  ]);
  return { scanned, extracted };
}

describe('buildGraph', () => {
  it('assembles files sorted by rank desc with ranks from the file import graph', () => {
    const { scanned, extracted } = chainFixture();
    const g = buildGraph(scanned, extracted, META);
    expect(g.files.map((f) => f.id)).toEqual(['src/c.ts', 'src/b.ts', 'src/a.ts']);
    const ranks = pagerank(
      ['src/a.ts', 'src/b.ts', 'src/c.ts'],
      [
        ['src/a.ts', 'src/b.ts'],
        ['src/a.ts', 'src/c.ts'],
        ['src/b.ts', 'src/c.ts'],
      ],
    );
    for (const f of g.files) expect(f.rank).toBe(ranks.get(f.id)!);
    expect(g.files[0]!.lang).toBe('ts');
    expect(g.files[0]!.symbols).toEqual(['baz']);
  });

  it('symbol nodes inherit their file rank (v1 contract) and sort rank desc, id asc', () => {
    const { scanned, extracted } = chainFixture();
    const g = buildGraph(scanned, extracted, META);
    expect(g.symbols.map((s) => s.id)).toEqual(['src/c.ts#baz', 'src/b.ts#Bar', 'src/a.ts#foo']);
    const fileRank = new Map(g.files.map((f) => [f.id, f.rank]));
    for (const s of g.symbols) {
      expect(s.rank).toBe(fileRank.get(s.file)!);
      expect(s.id).toBe(s.file + '#' + (s.id.split('#')[1] ?? ''));
    }
    expect(g.symbols[0]).toMatchObject({ kind: 'const', file: 'src/c.ts' });
  });

  it('emits sorted, deduped edges; drops self-imports and imports to unscanned ids', () => {
    const scanned = [sf('src/a.ts'), sf('src/b.ts')];
    const extracted = new Map<string, ExtractResult>([
      // duplicate b, a self-import, and a truncation-dropped target must all collapse/vanish
      ['src/a.ts', ex([], ['src/b.ts', 'src/b.ts', 'src/a.ts', 'src/dropped.ts'])],
      ['src/b.ts', ex([], [])],
    ]);
    const g = buildGraph(scanned, extracted, META);
    expect(g.edges).toEqual([{ from: 'src/a.ts', to: 'src/b.ts', type: 'imports' }]);
  });

  it('records meta: schema/slug/repo_root/git_rev/dirty/generated_at/generator/truncated', () => {
    const { scanned, extracted } = chainFixture();
    const g = buildGraph(scanned, extracted, { ...META, truncated: true, dirty: true });
    expect(g.schema).toBe(1);
    expect(g.slug).toBe('proj');
    expect(g.repo_root).toBe('/repo');
    expect(g.git_rev).toBe('abc1234');
    expect(g.dirty).toBe(true);
    expect(g.generated_at).toBe('2026-07-05T00:00:00.000Z');
    expect(g.generator).toBe('regex-v1');
    expect(g.truncated).toBe(true);
  });

  it('is byte-identical for identical input regardless of array/Map ordering', () => {
    const { scanned, extracted } = chainFixture();
    const g1 = buildGraph(scanned, extracted, META);
    const reversedScanned = [...scanned].reverse();
    const reversedExtracted = new Map([...extracted.entries()].reverse());
    const g2 = buildGraph(reversedScanned, reversedExtracted, META);
    expect(JSON.stringify(g2)).toBe(JSON.stringify(g1));
  });

  it('breaks rank ties by id asc (stable ordering for the token-capped slice)', () => {
    // Two edgeless files have identical base ranks => id decides.
    const scanned = [sf('src/z.ts'), sf('src/y.ts')];
    const extracted = new Map<string, ExtractResult>([
      ['src/z.ts', ex([{ name: 'zz', kind: 'function' }], [])],
      ['src/y.ts', ex([{ name: 'yy', kind: 'function' }], [])],
    ]);
    const g = buildGraph(scanned, extracted, META);
    expect(g.files[0]!.rank).toBe(g.files[1]!.rank);
    expect(g.files.map((f) => f.id)).toEqual(['src/y.ts', 'src/z.ts']);
    expect(g.symbols.map((s) => s.id)).toEqual(['src/y.ts#yy', 'src/z.ts#zz']);
  });

  it('dedupes repeated symbol names so symbol ids stay unique (first kind wins)', () => {
    const scanned = [sf('src/a.ts')];
    const extracted = new Map<string, ExtractResult>([
      [
        'src/a.ts',
        ex(
          [
            { name: 'foo', kind: 'function' },
            { name: 'foo', kind: 'const' },
          ],
          [],
        ),
      ],
    ]);
    const g = buildGraph(scanned, extracted, META);
    expect(g.symbols).toHaveLength(1);
    expect(g.symbols[0]).toMatchObject({ id: 'src/a.ts#foo', kind: 'function' });
    expect(g.files[0]!.symbols).toEqual(['foo']);
  });

  it('throws (fail loud) when a scanned file has no extraction result', () => {
    const scanned = [sf('src/a.ts')];
    expect(() => buildGraph(scanned, new Map(), META)).toThrow(/src\/a\.ts/);
  });

  it('throws (fail loud) on duplicate scanned ids', () => {
    const scanned = [sf('src/a.ts'), sf('src/a.ts')];
    const extracted = new Map<string, ExtractResult>([['src/a.ts', ex([], [])]]);
    expect(() => buildGraph(scanned, extracted, META)).toThrow(/duplicate/);
  });
});

// D041: test/spec files and fixtures never become graph nodes (files/symbols
// /edges), but are still required to have an extraction result -- exclusion
// happens AFTER the scan/extraction-completeness checks, not before.
describe('buildGraph: test/fixture exclusion (D041)', () => {
  it('excludes *.test.ts and *.spec.ts from files, symbols, and edges', () => {
    const scanned = [sf('src/a.ts'), sf('src/a.test.ts'), sf('src/b.spec.ts')];
    const extracted = new Map<string, ExtractResult>([
      ['src/a.ts', ex([{ name: 'foo', kind: 'function' }], [])],
      ['src/a.test.ts', ex([{ name: 'suite', kind: 'function' }], ['src/a.ts'])],
      ['src/b.spec.ts', ex([{ name: 'suite2', kind: 'function' }], ['src/a.ts'])],
    ]);
    const g = buildGraph(scanned, extracted, META);
    expect(g.files.map((f) => f.id)).toEqual(['src/a.ts']);
    expect(g.symbols.map((s) => s.id)).toEqual(['src/a.ts#foo']);
    expect(g.edges).toEqual([]); // both edges originated from excluded test files
  });

  it('excludes __tests__/, tests/, test/, and __fixtures__/ path segments', () => {
    const scanned = [
      sf('src/a.ts'),
      sf('src/__tests__/a.ts'),
      sf('tests/b.ts'),
      sf('test/c.ts'),
      sf('src/__fixtures__/sample.ts'),
    ];
    const extracted = new Map<string, ExtractResult>([
      ['src/a.ts', ex([], [])],
      ['src/__tests__/a.ts', ex([], [])],
      ['tests/b.ts', ex([], [])],
      ['test/c.ts', ex([], [])],
      ['src/__fixtures__/sample.ts', ex([], [])],
    ]);
    const g = buildGraph(scanned, extracted, META);
    expect(g.files.map((f) => f.id)).toEqual(['src/a.ts']);
  });

  it('drops an edge FROM a production file TO an excluded test file (target not a node)', () => {
    const scanned = [sf('src/a.ts'), sf('src/a.test.ts')];
    const extracted = new Map<string, ExtractResult>([
      ['src/a.ts', ex([], ['src/a.test.ts'])], // unusual, but must not leak a test-file edge target
      ['src/a.test.ts', ex([], [])],
    ]);
    const g = buildGraph(scanned, extracted, META);
    expect(g.edges).toEqual([]);
  });

  it('still requires an extraction result for an excluded test file (fail loud unchanged)', () => {
    const scanned = [sf('src/a.test.ts')];
    expect(() => buildGraph(scanned, new Map(), META)).toThrow(/src\/a\.test\.ts/);
  });

  it('non-uniform PageRank survives exclusion: a real import chain among production files still ranks', () => {
    const { scanned: chainScanned, extracted: chainExtracted } = chainFixture();
    const scanned = [...chainScanned, sf('src/a.test.ts')];
    const extracted = new Map(chainExtracted);
    extracted.set('src/a.test.ts', ex([], ['src/a.ts', 'src/b.ts', 'src/c.ts']));
    const g = buildGraph(scanned, extracted, META);
    expect(g.files.map((f) => f.id)).toEqual(['src/c.ts', 'src/b.ts', 'src/a.ts']);
    const ranks = new Set(g.files.map((f) => f.rank));
    expect(ranks.size).toBeGreaterThan(1);
  });
});
