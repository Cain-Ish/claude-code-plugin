import { describe, it, expect } from 'vitest';
import { parseFrontmatter } from './test-oracle.js';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { appendEdge } from './graph-store.js';
import { knowledgeReindex } from './knowledge-reindex.js';

describe('knowledgeReindex integrates projection', () => {
  it('projects edges onto pages during reindex', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ri-'));
    await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
    for (const s of ['a-page', 'b-page']) {
      await fsp.writeFile(join(dir, 'wiki', 'entities', `${s}.md`), `---\ntitle: ${s}\ntype: entities\nrelated: []\n---\n\n# ${s}\n`);
    }
    await appendEdge(join(dir, 'graph', 'edges.jsonl'),
      { op: 'assert', from: 'a-page', to: 'b-page', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await knowledgeReindex(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'a-page.md'), 'utf-8');
    expect(parseFrontmatter(md).related).toEqual(['b-page']);   // real parse, not a regex re-quote
    expect(md).toMatch(/\*\*Requires:\*\* \[\[b-page\]\]/);
  });
  it('reindex with no graph dir still works (no-op projection)', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ri0-'));
    await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
    await fsp.writeFile(join(dir, 'wiki', 'entities', 'solo.md'), `---\ntitle: solo\ntype: entities\n---\n\n# solo\n`);
    const r = await knowledgeReindex(dir);
    expect(r.pagesIndexed).toBe(1);
  });
});

async function page(kd: string, cat: string, slug: string, project?: string) {
  await fsp.mkdir(join(kd, 'wiki', cat), { recursive: true });
  const fm = ['---', `title: ${slug}`, `type: ${cat}`, ...(project ? [`project: ${project}`] : []), '---', `# ${slug}`];
  await fsp.writeFile(join(kd, 'wiki', cat, `${slug}.md`), fm.join('\n'));
}

describe('reindex project MOCs', () => {
  it('writes wiki/projects/<slug>.md for a project with >= 3 members and skips a 2-member one', async () => {
    const kd = await fsp.mkdtemp(join(tmpdir(), 'moc-'));
    await page(kd, 'decisions', 'kiri-redesign', 'kiri');
    await page(kd, 'decisions', 'kiri-core-design', 'kiri');
    await page(kd, 'security', 'kiri-privilege-split', 'kiri');
    await page(kd, 'decisions', 'bridge-a', 'cainish-bridge');
    await page(kd, 'decisions', 'bridge-b', 'cainish-bridge');
    await knowledgeReindex(kd);
    const moc = join(kd, 'wiki', 'projects', 'kiri.md');
    const body = await fsp.readFile(moc, 'utf-8').catch(() => '');
    expect(body).toContain('[[kiri-privilege-split]]');
    expect(body).toContain('type: projects');
    expect(body).toContain('graph: exclude');
    await expect(fsp.access(join(kd, 'wiki', 'projects', 'cainish-bridge.md'))).rejects.toThrow(); // 2 < 3
  });

  it('de-hubbed two-tier index: graph:exclude, MOC link, per-type counts, no flat page hub-links', async () => {
    const kd = await fsp.mkdtemp(join(tmpdir(), 'idx-'));
    await page(kd, 'decisions', 'kiri-redesign', 'kiri');
    await page(kd, 'decisions', 'kiri-core-design', 'kiri');
    await page(kd, 'security', 'kiri-privilege-split', 'kiri');
    await page(kd, 'concepts', 'standalone');
    await knowledgeReindex(kd);
    const idx = await fsp.readFile(join(kd, 'wiki', 'index.md'), 'utf-8');
    expect(idx).toMatch(/^---[\s\S]*graph:\s*exclude[\s\S]*?---/m);   // frontmatter marks it excluded
    expect(idx).toContain('[[projects/kiri]]');                       // links the project MOC (intentional hub)
    expect(idx).toMatch(/Decisions[^\n]*\b2\b/);                      // per-type COUNT, not 2 page links
    expect(idx).not.toContain('[[kiri-core-design]]');               // individual pages NOT hub-linked from index
  });

  it('is idempotent: a second reindex changes nothing but the generated timestamp', async () => {
    const kd = await fsp.mkdtemp(join(tmpdir(), 'idem-'));
    await page(kd, 'decisions', 'kiri-redesign', 'kiri');
    await page(kd, 'decisions', 'kiri-core-design', 'kiri');
    await page(kd, 'security', 'kiri-privilege-split', 'kiri');
    const strip = (s: string) => s.replace(/<!-- generated:.*?-->/g, '');
    await knowledgeReindex(kd);
    const idx1 = strip(await fsp.readFile(join(kd, 'wiki', 'index.md'), 'utf-8'));
    const moc1 = await fsp.readFile(join(kd, 'wiki', 'projects', 'kiri.md'), 'utf-8');
    await knowledgeReindex(kd);
    const idx2 = strip(await fsp.readFile(join(kd, 'wiki', 'index.md'), 'utf-8'));
    const moc2 = await fsp.readFile(join(kd, 'wiki', 'projects', 'kiri.md'), 'utf-8');
    expect(idx2).toBe(idx1);
    expect(moc2).toBe(moc1); // MOC has no timestamp → byte-identical
  });

  // --- review fixes (release gate) ---

  it('prunes a stale MOC when a project drops below the threshold (#4)', async () => {
    const kd = await fsp.mkdtemp(join(tmpdir(), 'prune-'));
    await page(kd, 'decisions', 'kiri-redesign', 'kiri');
    await page(kd, 'decisions', 'kiri-core-design', 'kiri');
    await page(kd, 'security', 'kiri-privilege-split', 'kiri');
    await knowledgeReindex(kd);
    expect(await fsp.access(join(kd, 'wiki', 'projects', 'kiri.md')).then(() => true)).toBe(true);
    await fsp.unlink(join(kd, 'wiki', 'security', 'kiri-privilege-split.md')); // now 2 < 3
    await knowledgeReindex(kd);
    await expect(fsp.access(join(kd, 'wiki', 'projects', 'kiri.md'))).rejects.toThrow(); // pruned
  });

  it('clamps SB_MOC_MIN_MEMBERS: a garbage value does not MOC every single-member project (#5)', async () => {
    const kd = await fsp.mkdtemp(join(tmpdir(), 'clamp-'));
    await page(kd, 'concepts', 'solo', 'solo-project');
    const prev = process.env.SB_MOC_MIN_MEMBERS;
    process.env.SB_MOC_MIN_MEMBERS = 'three'; // NaN → must fall back to 3, not gate-everything
    try {
      await knowledgeReindex(kd);
      await expect(fsp.access(join(kd, 'wiki', 'projects', 'solo-project.md'))).rejects.toThrow();
    } finally { if (prev === undefined) delete process.env.SB_MOC_MIN_MEMBERS; else process.env.SB_MOC_MIN_MEMBERS = prev; }
  });

  it('reindex/graph-projection preserves the ai-block byte-for-byte', async () => {
    const kd = await fsp.mkdtemp(join(tmpdir(), 'ri-keep-'));
    await fsp.mkdir(join(kd, 'wiki', 'decisions'), { recursive: true });
    const block = ['<!-- ai:begin -->', 'choice: use X', 'status: active', '<!-- ai:end -->'].join('\n');
    await fsp.writeFile(join(kd, 'wiki', 'decisions', 'd.md'), `---\ntitle: D\ntype: decisions\nrelated: []\n---\n${block}\n\n# D\nbody [[other]]`);
    await fsp.writeFile(join(kd, 'wiki', 'decisions', 'other.md'), `---\ntitle: O\ntype: decisions\n---\n# O\n`);
    await appendEdge(join(kd, 'graph', 'edges.jsonl'),
      { op: 'assert', from: 'd', to: 'other', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await knowledgeReindex(kd); // projects related: + ## Dependencies onto d.md
    const after = await fsp.readFile(join(kd, 'wiki', 'decisions', 'd.md'), 'utf-8');
    expect(after).toContain(block);                 // the ai-block survives projection intact
    expect(parseFrontmatter(after).related).toEqual(['other']); // projection happened, via real parse
  });

  it('project-MOC member description ignores the ai-block (firstSentence strips it)', async () => {
    const kd = await fsp.mkdtemp(join(tmpdir(), 'ri-ai-'));
    await fsp.mkdir(join(kd, 'wiki', 'concepts'), { recursive: true });
    const body = ['<!-- ai:begin -->', 'problem: BLOCKWORD should not surface', 'solution: x', '<!-- ai:end -->', '', 'Real prose sentence here.'].join('\n');
    await fsp.writeFile(join(kd, 'wiki', 'concepts', 'p.md'), `---\ntitle: P\ntype: concepts\nproject: demo\n---\n${body}`);
    await fsp.writeFile(join(kd, 'wiki', 'concepts', 'q.md'), `---\ntitle: Q\ntype: concepts\nproject: demo\n---\n# Q\nprose`);
    await fsp.writeFile(join(kd, 'wiki', 'concepts', 'r.md'), `---\ntitle: R\ntype: concepts\nproject: demo\n---\n# R\nprose`);
    await knowledgeReindex(kd);
    const moc = await fsp.readFile(join(kd, 'wiki', 'projects', 'demo.md'), 'utf-8');
    expect(moc).toContain('[[p]]');
    expect(moc).not.toContain('BLOCKWORD'); // member description must come from prose, not the block
  });

  it('does not mangle a MOC whose project key is an edge endpoint (#2 idempotency)', async () => {
    const kd = await fsp.mkdtemp(join(tmpdir(), 'mangle-'));
    await page(kd, 'decisions', 'arch-a', 'arch');
    await page(kd, 'decisions', 'arch-b', 'arch');
    await page(kd, 'decisions', 'arch-c', 'arch');
    // an edge whose endpoint is the project KEY "arch" (== the MOC slug) — so on the 2nd
    // reindex projectGraphToPages would try to inject related:/## Dependencies into the MOC
    // unless it skips the projects/ dir.
    await appendEdge(join(kd, 'graph', 'edges.jsonl'),
      { op: 'assert', from: 'arch-a', to: 'arch', type: 'part_of', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await knowledgeReindex(kd);
    const moc1 = await fsp.readFile(join(kd, 'wiki', 'projects', 'arch.md'), 'utf-8');
    await knowledgeReindex(kd);
    const moc2 = await fsp.readFile(join(kd, 'wiki', 'projects', 'arch.md'), 'utf-8');
    expect(moc2).toBe(moc1);                       // byte-identical across reindexes (not mangled)
    expect(moc1).not.toContain('## Dependencies'); // member descriptions free of the projected block
    expect(moc1).not.toMatch(/^related:/m);        // MOC frontmatter not edge-injected
  });
});
