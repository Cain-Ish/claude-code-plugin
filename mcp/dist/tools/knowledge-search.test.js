import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeSearch, parseDoc } from './knowledge-search.js';
import { appendEdge } from './graph-store.js';
async function wiki() {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-'));
    await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
    const w = (s, body, related = '[]') => fsp.writeFile(join(dir, 'wiki', 'entities', `${s}.md`), `---\ntitle: ${s}\ntype: entities\ndescription: ${s}\nrelated: ${related}\n---\n\n# ${s}\n\n${body}\n`);
    await w('alpha', 'alpha mentions wireguard tunnel keyword');
    await w('beta', 'unrelated content about gardening');
    await w('gamma', 'unrelated content about cooking');
    return dir;
}
function slugs(r) {
    return r.candidates.map(c => c.path.replace(/.*\//, '').replace(/\.md$/, ''));
}
describe('knowledge_search back-compat (no graph dir)', () => {
    it('frontmatter related: still drives a one-hop boost (legacy behaviour preserved)', async () => {
        const dir = await wiki();
        // legacy: alpha relates to beta via frontmatter only, no graph log present
        await fsp.writeFile(join(dir, 'wiki', 'entities', 'alpha.md'), `---\ntitle: alpha\ntype: entities\ndescription: alpha\nrelated: [[beta]]\n---\n\n# alpha\n\nwireguard tunnel keyword\n`);
        const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
        expect(slugs(r)).toContain('alpha');
        expect(slugs(r)).toContain('beta'); // boosted via frontmatter related, no graph log
    });
});
describe('knowledge_search multi-hop typed boost (graph present)', () => {
    it('a hit on alpha boosts its 1-hop and 2-hop requires-neighbours', async () => {
        const dir = await wiki();
        const log = join(dir, 'graph', 'edges.jsonl');
        await appendEdge(log, { op: 'assert', from: 'alpha', to: 'beta', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
        await appendEdge(log, { op: 'assert', from: 'beta', to: 'gamma', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
        const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
        expect(slugs(r)).toContain('beta'); // 1 hop
        expect(slugs(r)).toContain('gamma'); // 2 hops, via typed graph
    });
    it('an invalidated edge does not propagate boost', async () => {
        const dir = await wiki();
        const log = join(dir, 'graph', 'edges.jsonl');
        await appendEdge(log, { op: 'assert', from: 'alpha', to: 'beta', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
        await appendEdge(log, { op: 'invalidate', from: 'alpha', to: 'beta', type: 'requires', valid_to: '2026-05-10', recorded_at: '2026-05-10T00:00:00Z' });
        const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
        // beta has no query-term hits of its own; with the edge invalidated it should
        // not be pulled in by graph boost.
        expect(slugs(r)).not.toContain('beta');
    });
});
describe('search consumes the ai-block (Phase 2)', () => {
    it('indexes the ai-block and returns it as the result description', async () => {
        const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-ai2-'));
        await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
        // ZEBRAFISH appears ONLY in the block — not in title/description/prose
        const block = ['<!-- ai:begin -->', 'claim: ZEBRAFISH handshake', 'action: do x', '<!-- ai:end -->'].join('\n');
        await fsp.writeFile(join(dir, 'wiki', 'learnings', 'z.md'), `---\ntitle: Z\ntype: learnings\ndescription: unrelated prose description\n---\n${block}\n\n# Z\nplain prose body.`);
        const r = await knowledgeSearch({ query: 'ZEBRAFISH handshake', knowledgeDir: dir });
        const z = r.candidates.find(c => c.path.endsWith('/z.md'));
        expect(z).toBeTruthy(); // block term is indexed → findable
        expect(z.description).toContain('claim: ZEBRAFISH handshake'); // block returned as the snippet
    });
    it('caps the block-snippet description at the context budget (SNIPPET_CHARS)', async () => {
        const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-cap-'));
        await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
        const big = 'wireguard '.repeat(60); // >200 chars in a single field
        const block = ['<!-- ai:begin -->', `claim: ${big}`, 'action: a', '<!-- ai:end -->'].join('\n');
        await fsp.writeFile(join(dir, 'wiki', 'learnings', 'big.md'), `---\ntitle: Big\ntype: learnings\n---\n${block}\n\n# Big\nwireguard.`);
        const r = await knowledgeSearch({ query: 'wireguard', knowledgeDir: dir });
        const b = r.candidates.find(c => c.path.endsWith('/big.md'));
        expect(b.description.length).toBeLessThanOrEqual(200); // budget bound preserved (2afcfe3)
    });
});
describe('stub penalty excludes the ai-block (prose-only length)', () => {
    it('a short page padded only by a query-heavy ai-block is still penalized vs a real-prose page', async () => {
        const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-stub-'));
        await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
        const block = ['<!-- ai:begin -->', 'claim: ' + 'wireguard handshake '.repeat(15), 'action: x', '<!-- ai:end -->'].join('\n');
        await fsp.writeFile(join(dir, 'wiki', 'learnings', 'blockpad.md'), `---\ntitle: bp\ntype: learnings\n---\n${block}\n\nshort.`);
        await fsp.writeFile(join(dir, 'wiki', 'learnings', 'full.md'), `---\ntitle: full\ntype: learnings\n---\n# full\n` + 'wireguard handshake real prose detail. '.repeat(10));
        const r = await knowledgeSearch({ query: 'wireguard handshake', knowledgeDir: dir });
        const bp = r.candidates.find(c => c.path.endsWith('/blockpad.md'));
        const full = r.candidates.find(c => c.path.endsWith('/full.md'));
        expect(bp && full).toBeTruthy();
        expect(full.score).toBeGreaterThan(bp.score); // blockpad penalized (prose<100), full not
    });
});
describe('parseDoc ai-block', () => {
    it('exposes the parsed ai-block as doc.aiBlock', () => {
        const md = ['---', 'title: A', 'type: learnings', '---',
            '<!-- ai:begin -->', 'claim: c', 'action: a', '<!-- ai:end -->', '', '# A', 'body'].join('\n');
        const doc = parseDoc(md, '/w/learnings/a.md');
        expect(doc.aiBlock?.claim).toBe('c');
    });
    it('does NOT scrape a [[link]] inside the ai-block into related:', () => {
        const md = ['---', 'title: B', 'type: learnings', '---',
            '<!-- ai:begin -->', 'supersedes: [[ghost]]', 'claim: c', 'action: a', '<!-- ai:end -->', '', '# B', 'see [[real-page]]'].join('\n');
        const doc = parseDoc(md, '/w/learnings/b.md');
        expect(doc.related).toContain('real-page');
        expect(doc.related).not.toContain('ghost');
    });
});
describe('parseDoc project facet', () => {
    it('extracts the project: facet from frontmatter', () => {
        const md = ['---', 'title: Kiri Core', 'type: decisions', 'project: kiri', '---', '# Kiri Core'].join('\n');
        const doc = parseDoc(md, '/w/decisions/kiri-core-design.md');
        expect(doc.project).toBe('kiri');
    });
    it('defaults project to empty string when absent', () => {
        const md = ['---', 'title: X', 'type: concepts', '---', '# X'].join('\n');
        expect(parseDoc(md, '/w/concepts/x.md').project).toBe('');
    });
});
describe('SP-1 project-scoped serving', () => {
    async function scopedWiki() {
        const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-scope-'));
        await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
        const w = (s, project, body) => fsp.writeFile(join(dir, 'wiki', 'learnings', `${s}.md`), `---\ntitle: ${s}\ntype: learnings\n${project ? `project: ${project}\n` : ''}description: ${body}\n---\n\n# ${s}\n\n${body} ${'detail '.repeat(40)}\n`);
        await w('a1', 'alpha', 'wireguard tunnel keyword');
        await w('a2', 'alpha', 'wireguard tunnel keyword');
        await w('b1', 'beta', 'wireguard tunnel keyword');
        await w('s1', '', 'wireguard tunnel keyword');
        await w('n1', '', 'wireguard tunnel keyword');
        return dir;
    }
    it('in project alpha, returns alpha + shared first and excludes beta (in-scope strong)', async () => {
        const dir = await scopedWiki();
        const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
        const s = slugs(r);
        expect(s).toContain('a1');
        expect(s).toContain('a2');
        expect(s).toContain('s1');
        expect(s).not.toContain('b1');
    });
    it('auto-broadens to other-project when in-scope is thin', async () => {
        const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-broaden-'));
        await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
        await fsp.writeFile(join(dir, 'wiki', 'learnings', 'b1.md'), `---\ntitle: b1\ntype: learnings\nproject: beta\n---\n\n# b1\n\nwireguard tunnel ${'x '.repeat(40)}\n`);
        const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
        expect(slugs(r)).toContain('b1');
    });
    it('neighbourhood: a graph-linked untagged page ranks in-scope', async () => {
        const dir = await scopedWiki();
        await fsp.writeFile(join(dir, 'wiki', 'learnings', 'g1.md'), `---\ntitle: g1\ntype: learnings\nproject: gamma\ndescription: wireguard tunnel keyword\n---\n\n# g1\n\nwireguard tunnel keyword ${'detail '.repeat(40)}\n`);
        const log = join(dir, 'graph', 'edges.jsonl');
        await appendEdge(log, { op: 'assert', from: 'a1', to: 'n1', type: 'relates', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
        const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
        const s = slugs(r);
        expect(s).toContain('n1');
        expect(s).not.toContain('g1'); // other-project suppressed; n1 (neighbour) kept in-scope
    });
    it('scope:"all" and SB_PROJECT_SCOPE=off restore global ranking (beta included)', async () => {
        const dir = await scopedWiki();
        const all = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir, scope: 'all' });
        expect(slugs(all)).toContain('b1');
        process.env.SB_PROJECT_SCOPE = 'off';
        const off = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
        delete process.env.SB_PROJECT_SCOPE;
        expect(slugs(off)).toContain('b1');
    });
    it('back-compat: no projectSlug → unchanged global behaviour (beta present)', async () => {
        const dir = await scopedWiki();
        const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
        expect(slugs(r)).toContain('b1');
    });
});
//# sourceMappingURL=knowledge-search.test.js.map