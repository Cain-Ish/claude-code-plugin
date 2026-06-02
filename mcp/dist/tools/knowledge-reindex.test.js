import { describe, it, expect } from 'vitest';
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
        await appendEdge(join(dir, 'graph', 'edges.jsonl'), { op: 'assert', from: 'a-page', to: 'b-page', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
        await knowledgeReindex(dir);
        const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'a-page.md'), 'utf-8');
        expect(md).toMatch(/related: \[\[b-page\]\]/);
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
async function page(kd, cat, slug, project) {
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
        expect(idx).toMatch(/^---[\s\S]*graph:\s*exclude[\s\S]*?---/m); // frontmatter marks it excluded
        expect(idx).toContain('[[projects/kiri]]'); // links the project MOC (intentional hub)
        expect(idx).toMatch(/Decisions[^\n]*\b2\b/); // per-type COUNT, not 2 page links
        expect(idx).not.toContain('[[kiri-core-design]]'); // individual pages NOT hub-linked from index
    });
    it('is idempotent: a second reindex changes nothing but the generated timestamp', async () => {
        const kd = await fsp.mkdtemp(join(tmpdir(), 'idem-'));
        await page(kd, 'decisions', 'kiri-redesign', 'kiri');
        await page(kd, 'decisions', 'kiri-core-design', 'kiri');
        await page(kd, 'security', 'kiri-privilege-split', 'kiri');
        const strip = (s) => s.replace(/<!-- generated:.*?-->/g, '');
        await knowledgeReindex(kd);
        const idx1 = strip(await fsp.readFile(join(kd, 'wiki', 'index.md'), 'utf-8'));
        const moc1 = await fsp.readFile(join(kd, 'wiki', 'projects', 'kiri.md'), 'utf-8');
        await knowledgeReindex(kd);
        const idx2 = strip(await fsp.readFile(join(kd, 'wiki', 'index.md'), 'utf-8'));
        const moc2 = await fsp.readFile(join(kd, 'wiki', 'projects', 'kiri.md'), 'utf-8');
        expect(idx2).toBe(idx1);
        expect(moc2).toBe(moc1); // MOC has no timestamp → byte-identical
    });
});
//# sourceMappingURL=knowledge-reindex.test.js.map