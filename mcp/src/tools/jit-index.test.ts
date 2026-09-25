import { describe, it, expect } from 'vitest';
import { buildJitIndex, type JitSourcePage } from './jit-index.js';

const repoFiles = ['scripts/lib.sh', 'mcp/src/tools/a.ts', 'tests/x.sh'];

function pages(): JitSourcePage[] {
  return [
    { slug: 'p1', type: 'issues', project: 'demo', aiBlock: {
      symptom: 'CRLF breaks scripts/lib.sh readers', fix: 'strip it with tr -d \\r after jq',
    } },
    { slug: 'p2', type: 'learnings', project: 'demo', aiBlock: {
      claim: 'mcp/src/tools/ CLIs must use brain-paths', action: 'import resolveBrainDir',
    } },
    { slug: 'p3', type: 'learnings', project: 'other', aiBlock: {
      claim: 'scripts/lib.sh is also relevant here', action: 'irrelevant — wrong project',
    } },
    { slug: 'p4', type: 'decisions', project: 'demo', status: 'superseded', aiBlock: {
      choice: 'use scripts/lib.sh for this (superseded, must not appear)',
    } },
    { slug: 'p5', type: 'decisions', project: 'demo', aiBlock: {
      choice: 'this decision names no repo path at all',
    } },
  ];
}

describe('buildJitIndex — pure builder (repo-brain Slice 2, docs/plans/2026-09-24-repo-brain.md §8)', () => {
  it('issues → lesson (symptom → fix), path token resolved to an exact-file glob', () => {
    const idx = buildJitIndex({ slug: 'demo', pages: pages(), conventions: [], repoFiles });
    const p1 = idx.items.find(i => i.id === 'p1');
    expect(p1).toBeDefined();
    expect(p1!.kind).toBe('lesson');
    expect(p1!.globs).toEqual(['scripts/lib.sh']);
    expect(p1!.line).toContain('CRLF breaks scripts/lib.sh readers');
    expect(p1!.line).toContain('→');
    // backslash never survives sanitization
    expect(p1!.line).not.toContain('\\');
  });

  it('learnings → lesson (claim → action), a directory token resolves to a dir/* glob', () => {
    const idx = buildJitIndex({ slug: 'demo', pages: pages(), conventions: [], repoFiles });
    const p2 = idx.items.find(i => i.id === 'p2');
    expect(p2).toBeDefined();
    expect(p2!.globs).toEqual(['mcp/src/tools/*']);
  });

  it('a page from a different project is absent entirely', () => {
    const idx = buildJitIndex({ slug: 'demo', pages: pages(), conventions: [], repoFiles });
    expect(idx.items.find(i => i.id === 'p3')).toBeUndefined();
  });

  it('a superseded decision is absent even though its text names a real repo path', () => {
    const idx = buildJitIndex({ slug: 'demo', pages: pages(), conventions: [], repoFiles });
    expect(idx.items.find(i => i.id === 'p4')).toBeUndefined();
  });

  it('an item whose text names no repo path is dropped (zero globs)', () => {
    const idx = buildJitIndex({ slug: 'demo', pages: pages(), conventions: [], repoFiles });
    expect(idx.items.find(i => i.id === 'p5')).toBeUndefined();
  });

  it('a page naming only a path absent from the repo is dropped', () => {
    const p: JitSourcePage[] = [{ slug: 'nope', type: 'issues', project: 'demo', aiBlock: { symptom: 'see docs/nope.md for details', fix: '' } }];
    const idx = buildJitIndex({ slug: 'demo', pages: p, conventions: [], repoFiles });
    expect(idx.items).toHaveLength(0);
  });

  it('conventions bullets become conv:<n> items, 1-based, in input order', () => {
    const idx = buildJitIndex({
      slug: 'demo', pages: [], repoFiles,
      conventions: ['Tests under tests/ declare # pins:', 'irrelevant bullet naming no repo path'],
    });
    const conv1 = idx.items.find(i => i.id === 'conv:1');
    expect(conv1).toBeDefined();
    expect(conv1!.kind).toBe('convention');
    expect(conv1!.globs).toEqual(['tests/*']);
    expect(idx.items.find(i => i.id === 'conv:2')).toBeUndefined(); // no repo path → dropped
  });

  it('ordering: lesson > convention > decision > intent, then id', () => {
    const p: JitSourcePage[] = [
      { slug: 'zz-issue', type: 'issues', project: 'demo', aiBlock: { symptom: 'scripts/lib.sh z', fix: '' } },
      { slug: 'aa-issue', type: 'issues', project: 'demo', aiBlock: { symptom: 'scripts/lib.sh a', fix: '' } },
      { slug: 'concept', type: 'concepts', project: 'demo', aiBlock: { problem: 'why scripts/lib.sh exists' } },
      { slug: 'decision', type: 'decisions', project: 'demo', aiBlock: { choice: 'chose scripts/lib.sh' } },
    ];
    const idx = buildJitIndex({ slug: 'demo', pages: p, conventions: ['a rule about scripts/lib.sh'], repoFiles });
    expect(idx.items.map(i => i.kind)).toEqual(['lesson', 'lesson', 'convention', 'decision', 'intent']);
    expect(idx.items.slice(0, 2).map(i => i.id)).toEqual(['aa-issue', 'zz-issue']); // lessons sorted by id
  });

  it('a Unicode Tags-block char (U+E0041) is stripped from the emitted line', () => {
    const p: JitSourcePage[] = [{
      slug: 'tagged', type: 'issues', project: 'demo',
      aiBlock: { symptom: 'scripts/lib.sh has a hidden \u{E0041} tag char', fix: '' },
    }];
    const idx = buildJitIndex({ slug: 'demo', pages: p, conventions: [], repoFiles });
    const item = idx.items.find(i => i.id === 'tagged');
    expect(item).toBeDefined();
    expect(item!.line).not.toContain('\u{E0041}');
  });

  it('a 1000-char field truncates the emitted line to 160 chars', () => {
    const long = 'x'.repeat(60) + ' scripts/lib.sh ' + 'y'.repeat(1000);
    const p: JitSourcePage[] = [{ slug: 'long', type: 'issues', project: 'demo', aiBlock: { symptom: long, fix: '' } }];
    const idx = buildJitIndex({ slug: 'demo', pages: p, conventions: [], repoFiles });
    const item = idx.items.find(i => i.id === 'long');
    expect(item).toBeDefined();
    expect(item!.line.length).toBeLessThanOrEqual(160);
    // the path token was found (glob resolved) even though the display line got cut
    expect(item!.globs).toEqual(['scripts/lib.sh']);
  });

  it('no tab or backslash survives in any emitted line', () => {
    const p: JitSourcePage[] = [{
      slug: 'ctrl', type: 'issues', project: 'demo',
      aiBlock: { symptom: 'scripts/lib.sh\tneeds\\a fix', fix: '' },
    }];
    const idx = buildJitIndex({ slug: 'demo', pages: p, conventions: [], repoFiles });
    const item = idx.items.find(i => i.id === 'ctrl');
    expect(item).toBeDefined();
    expect(item!.line).not.toContain('\t');
    expect(item!.line).not.toContain('\\');
  });

  it('caps at 8 globs per item and 200 items total', () => {
    const manyPathsSymptom = repoFiles.concat(['tests/x.sh']).map(f => f).join(' ') + ' scripts/lib.sh mcp/src/tools/a.ts tests/x.sh scripts/lib.sh mcp/src/tools/a.ts tests/x.sh scripts/lib.sh mcp/src/tools/a.ts';
    const p: JitSourcePage[] = [{ slug: 'many', type: 'issues', project: 'demo', aiBlock: { symptom: manyPathsSymptom, fix: '' } }];
    const idx = buildJitIndex({ slug: 'demo', pages: p, conventions: [], repoFiles });
    const item = idx.items.find(i => i.id === 'many');
    expect(item!.globs.length).toBeLessThanOrEqual(8);

    const lots: JitSourcePage[] = Array.from({ length: 250 }, (_, i) => ({
      slug: `bulk-${String(i).padStart(3, '0')}`, type: 'issues', project: 'demo',
      aiBlock: { symptom: `scripts/lib.sh case ${i}`, fix: '' },
    }));
    const idxBulk = buildJitIndex({ slug: 'demo', pages: lots, conventions: [], repoFiles });
    expect(idxBulk.items.length).toBeLessThanOrEqual(200);
  });

  it('determinism: two calls on the same input are byte-identical (no timestamps in the core)', () => {
    const a = buildJitIndex({ slug: 'demo', pages: pages(), conventions: ['a rule about scripts/lib.sh'], repoFiles });
    const b = buildJitIndex({ slug: 'demo', pages: pages(), conventions: ['a rule about scripts/lib.sh'], repoFiles });
    expect(JSON.stringify(a)).toBe(JSON.stringify(b));
  });

  it('an unknown page type contributes nothing', () => {
    const p: JitSourcePage[] = [{ slug: 'ent', type: 'entities', project: 'demo', aiBlock: { identity: 'scripts/lib.sh is a thing' } }];
    const idx = buildJitIndex({ slug: 'demo', pages: p, conventions: [], repoFiles });
    expect(idx.items).toHaveLength(0);
  });
});
