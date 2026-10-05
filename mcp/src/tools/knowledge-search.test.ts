import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { promises as fsp } from 'fs';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeSearch, parseDoc, parseInjectGate, parseInjectPrecision, legacyWikiFilter, type KnowledgeSearchResult } from './knowledge-search.js';
import { appendEdge } from './graph-store.js';

// Hermetic access-counts (R2.2): without this, every knowledgeSearch call here
// read the developer's LIVE ~/.second-brain/access-counts.json into rankings
// and wrote test slugs back into it.
delete process.env.SB_BRAIN_DIR; process.env.BRAIN_DIR = mkdtempSync(join(tmpdir(), 'ks-brain-'));
// Deterministic BM25-only mode: with embeddings active, RRF rank jitter from
// cosine differences between otherwise-identical fixture pages (their slug tokens
// differ) breaks exact-score assertions (the invalidated-edge tie). The global
// vitest.setup.ts snapshots+restores process.env around EVERY test, so no
// sibling's env delete can bleed in — this top-level set is captured by that
// snapshot at each test start.
process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';

// These tests need the REAL embedding model (no SECOND_BRAIN_DISABLE_EMBEDDINGS).
// CI runs offline (HF_HUB_OFFLINE / TRANSFORMERS_OFFLINE) where the model cannot
// be fetched — and a fetch attempt can HANG past the timeout — so skip the real-
// model path there. It runs locally where the model exists. Mirrors the gate in
// test/episodic-index.test.ts:92-95.
const EMBEDDINGS_OFFLINE =
  process.env.HF_HUB_OFFLINE === '1' || process.env.TRANSFORMERS_OFFLINE === '1';

async function wiki(): Promise<string> {
  const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-'));
  await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
  const w = (s: string, body: string, related = '[]') =>
    fsp.writeFile(join(dir, 'wiki', 'entities', `${s}.md`),
      `---\ntitle: ${s}\ntype: entities\ndescription: ${s}\nrelated: ${related}\n---\n\n# ${s}\n\n${body}\n`);
  await w('alpha', 'alpha mentions wireguard tunnel keyword');
  await w('beta', 'unrelated content about gardening');
  await w('gamma', 'unrelated content about cooking');
  return dir;
}

function slugs(r: { candidates: { path: string }[] }): string[] {
  return r.candidates.map(c => c.path.replace(/^.*[\\/]/, '').replace(/\.md$/, ''));
}

describe('knowledge_search back-compat (no graph dir)', () => {
  // The ranking boost is opt-in (off by default) since P7; these tests validate the opt-in path.
  beforeEach(() => { process.env.SB_GRAPH_RANKING_BOOST = '1'; });
  afterEach(() => { delete process.env.SB_GRAPH_RANKING_BOOST; });
  it('frontmatter related: boosts a weak-match neighbour above an equal non-neighbour (R2.1 contract)', async () => {
    const dir = await wiki();
    // R2.1 (MCP-SEARCH-1): boost is capped at <=1x a page's own base score, so a
    // ZERO-base page can no longer ride related: into the results (deliberate —
    // knowledge_neighbors is the graph-discovery tool). What the boost still
    // does: lift a weak-text-match neighbour above an identical non-neighbour.
    await fsp.writeFile(join(dir, 'wiki', 'entities', 'alpha.md'),
      `---\ntitle: alpha\ntype: entities\ndescription: alpha\nrelated: [[beta]]\n---\n\n# alpha\n\nwireguard tunnel keyword\n`);
    await fsp.writeFile(join(dir, 'wiki', 'entities', 'beta.md'),
      `---\ntitle: beta\ntype: entities\ndescription: notes touching wireguard once\n---\n\n# beta\n\nmostly gardening content with one wireguard mention\n`);
    await fsp.writeFile(join(dir, 'wiki', 'entities', 'delta.md'),
      `---\ntitle: delta\ntype: entities\ndescription: notes touching wireguard once\n---\n\n# delta\n\nmostly gardening content with one wireguard mention\n`);
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    expect(slugs(r)).toContain('alpha');
    expect(slugs(r)).toContain('beta'); // weak match + related boost → present
    const beta = r.candidates.find(c => c.path.endsWith('/beta.md'))!;
    const delta = r.candidates.find(c => c.path.endsWith('/delta.md'));
    if (delta) expect(beta.score).toBeGreaterThan(delta.score); // the boost is what separates them
  });
});

describe('knowledge_search multi-hop typed boost (graph present)', () => {
  beforeEach(() => { process.env.SB_GRAPH_RANKING_BOOST = '1'; });
  afterEach(() => { delete process.env.SB_GRAPH_RANKING_BOOST; });
  it('a hit on alpha boosts its weak-match 1-hop and 2-hop requires-neighbours (R2.1 contract)', async () => {
    const dir = await wiki();
    // R2.1: zero-base pages cannot ride the graph (boost capped at <=1x own
    // base); neighbours need SOME text relevance. 1-hop receives more than
    // 2-hop (0.3 decay per hop).
    await fsp.writeFile(join(dir, 'wiki', 'entities', 'beta.md'),
      `---\ntitle: beta\ntype: entities\ndescription: notes touching wireguard once\n---\n\n# beta\n\ngardening content with one wireguard mention\n`);
    await fsp.writeFile(join(dir, 'wiki', 'entities', 'gamma.md'),
      `---\ntitle: gamma\ntype: entities\ndescription: notes touching wireguard once\n---\n\n# gamma\n\ncooking content with one wireguard mention\n`);
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'alpha', to: 'beta', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await appendEdge(log, { op: 'assert', from: 'beta', to: 'gamma', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    expect(slugs(r)).toContain('beta');   // 1 hop
    expect(slugs(r)).toContain('gamma');  // 2 hops, via typed graph
    const beta = r.candidates.find(c => c.path.endsWith('/beta.md'))!;
    const gamma = r.candidates.find(c => c.path.endsWith('/gamma.md'))!;
    expect(beta.score).toBeGreaterThanOrEqual(gamma.score); // hop decay ordering
  });
  it('an invalidated edge does not propagate boost', async () => {
    const dir = await wiki();
    // Deep-review H1: under the R2.1 contract a zero-base page can never appear,
    // which made this test vacuous (it passed even with validAt filtering
    // deleted). Give the linked page the same weak match as a control page so
    // the INVALIDATED edge is again the only discriminator: valid edge → linked
    // beats control (see the sibling boost test); invalidated edge → they tie.
    // Slugs are unique to THIS test: access counts are slug-keyed in the
    // file-shared BRAIN_DIR, so reusing 'beta' would inherit access boosts from
    // earlier tests and break the tie (observed: 1.2x flake under full suite).
    await fsp.writeFile(join(dir, 'wiki', 'entities', 'ivbeta.md'),
      `---\ntitle: ivbeta\ntype: entities\ndescription: notes touching wireguard once\n---\n\n# ivbeta\n\ngardening content with one wireguard mention\n`);
    await fsp.writeFile(join(dir, 'wiki', 'entities', 'ivctrl.md'),
      `---\ntitle: ivctrl\ntype: entities\ndescription: notes touching wireguard once\n---\n\n# ivctrl\n\ngardening content with one wireguard mention\n`);
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'alpha', to: 'ivbeta', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await appendEdge(log, { op: 'invalidate', from: 'alpha', to: 'ivbeta', type: 'requires', valid_to: '2026-05-10', recorded_at: '2026-05-10T00:00:00Z' });
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    const linked = r.candidates.find(c => c.path.endsWith('/ivbeta.md'));
    const control = r.candidates.find(c => c.path.endsWith('/ivctrl.md'));
    // With the edge invalidated, the linked page must receive NO boost:
    // identical score to the unlinked control page.
    if (linked || control) {
      expect(linked?.score ?? 0).toBe(control?.score ?? 0);
    }
  });
});

describe('search consumes the ai-block (Phase 2)', () => {
  it('indexes the ai-block and returns it as the result description', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-ai2-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    // ZEBRAFISH appears ONLY in the block — not in title/description/prose
    const block = ['<!-- ai:begin -->', 'claim: ZEBRAFISH handshake', 'action: do x', '<!-- ai:end -->'].join('\n');
    await fsp.writeFile(join(dir, 'wiki', 'learnings', 'z.md'),
      `---\ntitle: Z\ntype: learnings\ndescription: unrelated prose description\n---\n${block}\n\n# Z\nplain prose body.`);
    const r = await knowledgeSearch({ query: 'ZEBRAFISH handshake', knowledgeDir: dir });
    const z = r.candidates.find(c => c.path.endsWith('/z.md'));
    expect(z).toBeTruthy();                                          // block term is indexed → findable
    expect(z!.description).toContain('claim: ZEBRAFISH handshake');  // block returned as the snippet
  });
  it('caps the block-snippet description at the context budget (SNIPPET_CHARS)', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-cap-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const big = 'wireguard '.repeat(60); // >200 chars in a single field
    const block = ['<!-- ai:begin -->', `claim: ${big}`, 'action: a', '<!-- ai:end -->'].join('\n');
    await fsp.writeFile(join(dir, 'wiki', 'learnings', 'big.md'), `---\ntitle: Big\ntype: learnings\n---\n${block}\n\n# Big\nwireguard.`);
    const r = await knowledgeSearch({ query: 'wireguard', knowledgeDir: dir });
    const b = r.candidates.find(c => c.path.endsWith('/big.md'));
    expect(b!.description.length).toBeLessThanOrEqual(200); // budget bound preserved (2afcfe3)
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
    expect(full!.score).toBeGreaterThan(bp!.score); // blockpad penalized (prose<100), full not
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
  async function scopedWiki(): Promise<string> {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-scope-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const w = (s: string, project: string, body: string) =>
      fsp.writeFile(join(dir, 'wiki', 'learnings', `${s}.md`),
        `---\ntitle: ${s}\ntype: learnings\n${project ? `project: ${project}\n` : ''}description: ${body}\n---\n\n# ${s}\n\n${body} ${'detail '.repeat(40)}\n`);
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
    expect(s).toContain('a1'); expect(s).toContain('a2'); expect(s).toContain('s1');
    expect(s).not.toContain('b1');
  });

  it('auto-broadens to other-project when in-scope is thin', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-broaden-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    await fsp.writeFile(join(dir, 'wiki', 'learnings', 'b1.md'),
      `---\ntitle: b1\ntype: learnings\nproject: beta\n---\n\n# b1\n\nwireguard tunnel ${'x '.repeat(40)}\n`);
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    expect(slugs(r)).toContain('b1');
  });

  it('neighbourhood: a graph-linked untagged page ranks in-scope', async () => {
    const dir = await scopedWiki();
    await fsp.writeFile(join(dir, 'wiki', 'learnings', 'g1.md'),
      `---\ntitle: g1\ntype: learnings\nproject: gamma\ndescription: wireguard tunnel keyword\n---\n\n# g1\n\nwireguard tunnel keyword ${'detail '.repeat(40)}\n`);
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a1', to: 'n1', type: 'relates', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    const s = slugs(r);
    expect(s).toContain('n1');
    expect(s).not.toContain('g1');   // other-project suppressed; n1 (neighbour) kept in-scope
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

  it('scoping telemetry: scoped_to + anchors present when scoping is active', async () => {
    const dir = await scopedWiki();
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    expect(r.scoped_to).toBe('alpha');
    expect(r.anchors).toBe(2);   // a1 + a2 carry project: alpha
  });

  it('scoping telemetry fail-loud branch: unknown slug → anchors 0 (scoping inert, visibly)', async () => {
    // Before this field existed, a wrong/unpopulated slug silently collapsed the tiers.
    const dir = await scopedWiki();
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'no-such-project', brainDir: dir });
    expect(r.scoped_to).toBe('no-such-project');
    expect(r.anchors).toBe(0);
  });

  // D058: anchors=0 must be INERT (server.ts's own tool description promises this), not a
  // silent demotion. Before the fix, every project-tagged page (b1) fell to tier 5 — below every
  // untagged global page (s1/n1) — purely because the active slug happened to have no pages.
  it('D058: anchors=0 does not demote project-tagged pages — ranking matches unscoped', async () => {
    const dir = await scopedWiki();
    const scoped = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'no-such-project', brainDir: dir });
    const unscoped = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    expect(slugs(scoped)).toContain('b1');   // beta page must not be demoted/dropped
    expect(scoped.candidates.every(c => c.tier === undefined)).toBe(true);   // tiering is off, not just unreported
    expect(slugs(scoped)).toEqual(slugs(unscoped));
  });

  it('scoping telemetry absent when scoping is off (no projectSlug / scope:all)', async () => {
    const dir = await scopedWiki();
    const unscoped = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    expect(unscoped.scoped_to).toBeUndefined();
    expect(unscoped.anchors).toBeUndefined();
    const all = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir, scope: 'all' });
    expect(all.scoped_to).toBeUndefined();
  });

  it('C1: local-docs are tier-1 and a same-basename other-project wiki page never leaks into scope', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-localdoc-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const w = (s: string, project: string, body: string) =>
      fsp.writeFile(join(dir, 'wiki', 'learnings', `${s}.md`),
        `---\ntitle: ${s}\ntype: learnings\n${project ? `project: ${project}\n` : ''}description: ${body}\n---\n\n# ${s}\n\n${body} ${'detail '.repeat(40)}\n`);
    // three strong in-scope wiki anchors so tier-4 is dropped (>= SB_SCOPE_MIN_HITS)
    await w('a1', 'alpha', 'wireguard tunnel keyword');
    await w('a2', 'alpha', 'wireguard tunnel keyword');
    await w('a3', 'alpha', 'wireguard tunnel keyword');
    // a BETA wiki page whose basename ('notes') collides with the alpha local-doc below
    await w('notes', 'beta', 'wireguard tunnel keyword');
    const betaNotes = join(dir, 'wiki', 'learnings', 'notes.md');
    // alpha local-doc registry; its entry basename collides with the beta wiki page
    const localNotes = join(dir, 'proj-alpha', 'notes.md');
    await fsp.mkdir(join(dir, 'projects', 'alpha'), { recursive: true });
    await fsp.writeFile(join(dir, 'projects', 'alpha', 'doc-sources.json'), JSON.stringify({
      generated_at: '2026-06-03T00:00:00Z', project: 'alpha',
      entries: [{ id: 'notes', path: localNotes, rel: 'notes.md', gist: 'wireguard tunnel keyword local',
        headings: ['wireguard tunnel keyword'], hash: 'h', mtime: '2026-06-03T00:00:00Z', size: 400 }],
    }));
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    const paths = r.candidates.map(c => c.path);
    expect(paths).toContain(localNotes);     // alpha's own local-doc is served (tier 1)
    expect(paths).not.toContain(betaNotes);  // the beta wiki page must NOT leak into alpha scope
  });

  it('SP-1 family: a sibling project page is in-scope, an unrelated project is dropped', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-family-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const w = (s: string, project: string, body: string) =>
      fsp.writeFile(join(dir, 'wiki', 'learnings', `${s}.md`),
        `---\ntitle: ${s}\ntype: learnings\n${project ? `project: ${project}\n` : ''}description: ${body}\n---\n\n# ${s}\n\n${body} ${'detail '.repeat(40)}\n`);
    await w('own',     'acme__api', 'shared shibboleth token');
    await w('sibling', 'acme__web', 'shared shibboleth token');
    await w('global',  '',          'shared shibboleth token');
    await w('foreign', 'unrelated', 'shared shibboleth token');
    await fsp.writeFile(join(dir, 'projects.jsonl'),
      '{"slug":"acme"}\n{"slug":"acme__api","parent":"acme"}\n{"slug":"acme__web","parent":"acme"}\n{"slug":"unrelated"}\n');
    const r = await knowledgeSearch({ query: 'shibboleth token', projectSlug: 'acme__api', knowledgeDir: dir, brainDir: dir });
    const paths = r.candidates.map(c => c.path);
    expect(paths.some(p => /sibling/.test(p))).toBe(true);   // family member in-scope
    expect(paths.some(p => /foreign/.test(p))).toBe(false);  // unrelated project dropped
    expect(slugs(r).some(s => /global/.test(s))).toBe(true);   // global pages stay in-scope (tier 4)
  });
});

describe.skipIf(EMBEDDINGS_OFFLINE)('knowledge_search RRF vector fusion (real model)', () => {
  // GREEN!=WORKING gap closed: every other test in this file runs in
  // SECOND_BRAIN_DISABLE_EMBEDDINGS=1 (BM25-only), so the RRF fusion path
  // (knowledge-search.ts:252-285) is NEVER exercised — a regression that broke
  // cosine fusion would leave the whole suite green. This test runs WITHOUT the
  // disable flag over a fixture where BM25 and the vector engine DISAGREE, and
  // asserts the semantic winner that ONLY RRF can produce.
  //
  // Fixture (query 'quiet a noisy dog after dark'):
  //  - target : strong SEMANTIC match (synonyms: puppy/hound/whining/late), but
  //             carries almost none of the query's literal tokens → weak BM25.
  //  - decoy  : a long off-topic warehouse doc that mentions the literal query
  //             tokens once → strong BM25 (#1), but low cosine (off-topic).
  //  - sem1   : a semantic sibling (kitten/dusk) that sits BETWEEN target and
  //             decoy on cosine, demoting decoy's cosine rank to #2 so target's
  //             cosine-rank lead exceeds its BM25-rank deficit under RRF.
  // Empirically (probed against the real MiniLM model): BM25-only ranks decoy
  // FIRST and floors/loses target; RRF fusion lifts target to #0 above decoy.
  beforeEach(() => { delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS; });
  afterEach(() => { process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1'; });

  async function rrfWiki(): Promise<string> {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-rrf-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const w = (s: string, title: string, desc: string, body: string) =>
      fsp.writeFile(join(dir, 'wiki', 'learnings', `${s}.md`),
        `---\ntitle: ${title}\ntype: learnings\ndescription: ${desc}\n---\n\n# ${title}\n\n${body}\n`);
    await w('target', 'Settling a restless puppy in the evening', 'calming a yappy hound late at bedtime',
      'soothing methods to comfort a whining pup so the household can rest peacefully once it grows late and everyone wants to sleep');
    await w('sem1', 'Comforting an anxious kitten at dusk', 'reassuring a fretful feline once the sun sets',
      'gentle routines help a mewing cat relax and settle so the family can sleep through the small hours of the morning');
    await w('decoy', 'Warehouse stocktake form', 'quarterly pallet audit record',
      'the quarterly stocktake tallied every pallet and forklift on the loading dock a stray quiet noisy dog after dark wandered past the dark gate while staff logged crate counts shipping manifests and forklift fuel for the audit');
    await w('distractor', 'Tomato gardening guide', 'watering tomato plants',
      'tomato seedlings need consistent watering and full sun through the summer growing season for a healthy harvest of fruit and vegetables');
    return dir;
  }

  it('a semantic-only match outranks a lexical-only decoy, and the result is NOT degraded (RRF actually ran)', async () => {
    const dir = await rrfWiki();
    const query = 'quiet a noisy dog after dark';

    // Control: in BM25-only mode the engines genuinely DISAGREE — the lexical
    // decoy ranks first; the synonym-only target loses (floored or below decoy).
    process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
    const bm = await knowledgeSearch({ query, knowledgeDir: dir });
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
    expect(bm.degraded).toBe('bm25-only');
    const bmSlugs = slugs(bm);
    expect(bmSlugs[0]).toBe('decoy');                          // BM25 favours the literal-token decoy
    const bmTarget = bmSlugs.indexOf('target');
    expect(bmTarget === -1 || bmTarget > 0).toBe(true);        // target does NOT win on BM25

    // Hybrid: RRF fusion of BM25 + cosine flips the winner to the semantic target.
    const hy = await knowledgeSearch({ query, knowledgeDir: dir });
    expect(hy.degraded).toBeUndefined();                       // RRF path ran (not the BM25 fallback)
    const s = slugs(hy);
    const ti = s.indexOf('target');
    const di = s.indexOf('decoy');
    expect(ti).toBeGreaterThanOrEqual(0);                      // semantic target is returned
    expect(di === -1 || ti < di).toBe(true);                  // and outranks the lexical decoy
    expect(s[0]).toBe('target');                               // it is in fact the top hit
  }, 120_000);
});

// Tokenize-once oracle (0.33.38): scoreBM25/computeDF were refactored from
// per-query-token re-tokenization to per-doc token-count maps. The refactor is
// PURE — this fixture pins the exact pre-refactor ranking AND scores (captured
// from the tokenization-per-call implementation), so any drift in the math is
// a hard failure, not a plausible-looking reorder. BM25-only + no created/
// updated dates (no recency boost) + long bodies (no stub penalty) keeps the
// scores fully deterministic.
describe('BM25 ranking regression (tokenize-once refactor oracle)', () => {
  it('fixture ranking and scores match the known-good pre-refactor output', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-bm25-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const FILLER = 'Long enough body text to dodge the stub penalty entirely. '.repeat(4);
    const page = (slug: string, fm: string, body: string) =>
      fsp.writeFile(join(dir, 'wiki', 'learnings', `${slug}.md`), `---\n${fm}\n---\n\n${body}\n`);
    await page('title-hit', 'title: wireguard tunnel setup\ntype: learnings\ndescription: vpn notes\ntags: []\nrelated: []',
      `# t\n\n${FILLER}network config.`);
    await page('tag-hit', 'title: unrelated one\ntype: learnings\ndescription: something else\ntags: [wireguard]\nrelated: []',
      `# t\n\n${FILLER}gardening notes.`);
    await page('body-hit', 'title: unrelated two\ntype: learnings\ndescription: still other\ntags: []\nrelated: []',
      `# t\n\n${FILLER}wireguard appears once in the body only.`);
    await page('body-hit-repeated', 'title: unrelated three\ntype: learnings\ndescription: other\ntags: []\nrelated: []',
      `# t\n\nwireguard wireguard wireguard tunnel tunnel. ${FILLER}`);
    await page('miss', 'title: nothing here\ntype: learnings\ndescription: none\ntags: []\nrelated: []',
      `# t\n\n${FILLER}cooking.`);

    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    expect(r.degraded).toBe('bm25-only');
    // Known-good order + exact raw scores from the pre-refactor implementation
    // (verified against a verbatim copy of the old scoreBM25/computeDF on this
    // fixture: title-hit 5.64, body-hit-repeated 1.64, tag-hit 0.96, body-hit
    // 0.28 → below the 0.15 relevance floor, miss 0 → dropped).
    expect(slugs(r)).toEqual(['title-hit', 'body-hit-repeated', 'tag-hit']);
    expect(r.candidates.map(c => c.score)).toEqual([5.64, 1.64, 0.96]);
  });
});

// --- folded from mcp/test/knowledge-search.test.ts (now co-located with its source module) ---

describe('knowledge_search v1', () => {
  let knowledgeDir: string;
  beforeEach(() => {
    knowledgeDir = mkdtempSync(join(tmpdir(), 'ks-'));
    mkdirSync(join(knowledgeDir, 'wiki', 'concepts'), { recursive: true });
    mkdirSync(join(knowledgeDir, 'wiki', 'learnings'), { recursive: true });
    writeFileSync(
      join(knowledgeDir, 'wiki', 'learnings', '2026-04-29-counting-pipeline.md'),
      `# Counting pipeline fallback gotcha\n\nDate: 2026-04-29\n\nUsing grep -c with || echo 0 corrupts...\n`,
      'utf-8'
    );
    writeFileSync(
      join(knowledgeDir, 'wiki', 'concepts', 'shell-patterns.md'),
      `# Shell patterns\n\nGeneral shell-script idioms.\n`,
      'utf-8'
    );
  });
  afterEach(() => { rmSync(knowledgeDir, { recursive: true, force: true }); });

  it('returns top candidates ranked by token overlap', async () => {
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir });
    expect(res.candidates.length).toBeGreaterThan(0);
    expect(res.candidates[0].path).toMatch(/counting-pipeline\.md$/);
  });

  it('respects scope filter', async () => {
    const res = await knowledgeSearch({ query: 'shell', scope: 'concepts', knowledgeDir });
    const norm = (p: string) => p.replace(/\\/g, '/');
    expect(res.candidates.every(c => norm(c.path).includes('/concepts/'))).toBe(true);
  });

  // D057: `scope` was joined straight into wikiRoot with no validation, so '../../outside'
  // walked out of the wiki and returned arbitrary files (path traversal / arbitrary-file read).
  it('rejects a traversal scope instead of walking outside the wiki', async () => {
    const outsideDir = await fsp.mkdtemp(join(tmpdir(), 'ks-outside-'));
    await fsp.writeFile(join(outsideDir, 'secret.md'), '---\ndescription: "XYZZYMARKER private note outside the wiki"\n---\n\nXYZZYMARKER\n');
    await expect(knowledgeSearch({ query: 'XYZZYMARKER', scope: '../../outside', knowledgeDir })).rejects.toThrow(/invalid scope/);
    await expect(knowledgeSearch({ query: 'XYZZYMARKER', scope: '../..', knowledgeDir })).rejects.toThrow(/invalid scope/);
  });

  it('returns empty candidates on no match', async () => {
    const res = await knowledgeSearch({ query: 'unrelatedstring1234', knowledgeDir });
    expect(res.candidates).toEqual([]);
  });

  it('labels each candidate with an estimated token count', async () => {
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir });
    expect(res.candidates.length).toBeGreaterThan(0);
    for (const c of res.candidates) {
      expect(typeof c.tokens).toBe('number');
      expect(c.tokens).toBeGreaterThan(0);
    }
  });

  // D029: saveAccessCounts used to be fire-and-forget. sb-entry.ts (the one-shot CLI) calls
  // process.exit() as soon as knowledgeSearch() resolves, which killed the write mid-flight — a
  // 0-byte access-counts.json.tmp.<pid> was left behind and access-counts.json was never
  // actually updated. Delaying the underlying rename here reproduces that race deterministically:
  // a fire-and-forget write loses it (checked immediately after resolution, the file is stale),
  // an awaited write cannot.
  it('the access-count write is durable before knowledgeSearch resolves (no CLI process.exit race)', async () => {
    const brainDir = mkdtempSync(join(tmpdir(), 'ks-acc-brain-'));
    process.env.SB_BRAIN_DIR = brainDir;
    const realRename = fsp.rename.bind(fsp);
    const spy = vi.spyOn(fsp, 'rename').mockImplementation(async (...args: unknown[]) => {
      await new Promise(r => setTimeout(r, 30));
      return (realRename as (...a: unknown[]) => Promise<void>)(...args);
    });
    try {
      const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir });
      expect(res.candidates.length).toBeGreaterThan(0);
      const raw = await fsp.readFile(join(brainDir, 'access-counts.json'), 'utf-8');
      const counts = JSON.parse(raw);
      const slug = res.candidates[0].path.replace(/^.*[\\/]/, '').replace(/\.md$/, '');
      expect(counts[slug]?.count).toBeGreaterThanOrEqual(1);
    } finally {
      spy.mockRestore();
      delete process.env.SB_BRAIN_DIR;
    }
  });

  // G3 (2026-10): accessCountsFile() read only the env/home resolver, so a caller that passed
  // its own brainDir (sb.ts, tests) still wrote fixture slugs into the env-resolved tree, which on
  // a developer box is the real ~/.second-brain. The caller's override must win.
  it('writes access counts to the brainDir the caller passes, not the env-resolved one', async () => {
    const envDir = mkdtempSync(join(tmpdir(), 'ks-acc-env-'));
    const argDir = mkdtempSync(join(tmpdir(), 'ks-acc-arg-'));
    process.env.SB_BRAIN_DIR = envDir;
    try {
      const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir, brainDir: argDir });
      expect(res.candidates.length).toBeGreaterThan(0);
      const counts = JSON.parse(await fsp.readFile(join(argDir, 'access-counts.json'), 'utf-8'));
      expect(Object.keys(counts).length).toBeGreaterThan(0);
      await expect(fsp.access(join(envDir, 'access-counts.json'))).rejects.toThrow();
    } finally {
      delete process.env.SB_BRAIN_DIR;
    }
  });

  it('returns the curated description as the gist, not a raw frontmatter chop', async () => {
    writeFileSync(
      join(knowledgeDir, 'wiki', 'concepts', 'gist-page.md'),
      `---\ntitle: "Gist page"\ndescription: "One-line curated gist about widgets"\n---\n\n# Gist page\n\nBody about widgets and gizmos.\n`,
      'utf-8'
    );
    const res = await knowledgeSearch({ query: 'widgets gizmos gist', knowledgeDir });
    const hit = res.candidates.find(c => c.path.endsWith('gist-page.md'));
    expect(hit).toBeDefined();
    expect(hit!.description).toBe('One-line curated gist about widgets');
    expect(hit as any).not.toHaveProperty('first_lines');
  });

  // D060: a description-less page fell back to `rawContent.slice(...)` — the WHOLE file,
  // frontmatter first — so the snippet injected into every prompt was a YAML chop like
  // `--- title: "..." type: themes ---` instead of prose. Must use doc.body (stripped).
  it('description-less page snippet falls back to body text, not a raw frontmatter chop', async () => {
    mkdirSync(join(knowledgeDir, 'wiki', 'themes'), { recursive: true });
    writeFileSync(
      join(knowledgeDir, 'wiki', 'themes', 'zzq.md'),
      `---\ntitle: "Theme: zzq"\ntype: themes\n---\n\n# zzq\n\nzzq prose about widgets and gizmos.\n`,
      'utf-8'
    );
    const res = await knowledgeSearch({ query: 'zzq widgets gizmos', knowledgeDir });
    const hit = res.candidates.find(c => c.path.endsWith('zzq.md'));
    expect(hit).toBeDefined();
    expect(hit!.description).not.toMatch(/^---/);
    expect(hit!.description).not.toMatch(/type:\s*themes/);
    expect(hit!.description).toContain('zzq prose about widgets');
  });

  it('surfaces an active-project local doc as a local-doc candidate', async () => {
    const brainDir = mkdtempSync(join(tmpdir(), 'ks-brain-'));
    mkdirSync(join(brainDir, 'projects', 'proj'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'proj', 'doc-sources.json'), JSON.stringify({
      generated_at: 'x', project: 'proj',
      entries: [{ id: 'abc123', path: '/abs/docs/deploy-runbook.md', rel: 'docs/deploy-runbook.md',
        gist: 'Deploy runbook for the cluster', headings: ['## Steps', '## Rollback'],
        hash: 'h', mtime: '2026-05-24T00:00:00Z', size: 1200 }],
    }));
    const res = await knowledgeSearch({ query: 'deploy runbook cluster', knowledgeDir, brainDir, projectSlug: 'proj' });
    const hit = res.candidates.find(c => c.path === '/abs/docs/deploy-runbook.md');
    expect(hit).toBeDefined();
    expect(hit!.source).toBe('local-doc');
    expect(hit!.description).toBe('Deploy runbook for the cluster');
    expect(hit!.tokens).toBe(Math.ceil(1200 / 4));
    rmSync(brainDir, { recursive: true, force: true });
  });

  it('does not leak another project\'s docs and wiki results carry source:wiki', async () => {
    const brainDir = mkdtempSync(join(tmpdir(), 'ks-brain2-'));
    mkdirSync(join(brainDir, 'projects', 'other'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'other', 'doc-sources.json'), JSON.stringify({
      generated_at: 'x', project: 'other',
      entries: [{ id: 'x', path: '/abs/secret.md', rel: 'secret.md', gist: 'counting pipeline grep secret',
        headings: [], hash: 'h', mtime: '2026-05-24T00:00:00Z', size: 100 }],
    }));
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir, brainDir, projectSlug: 'proj' });
    expect(res.candidates.some(c => c.path === '/abs/secret.md')).toBe(false);
    expect(res.candidates.every(c => c.source === 'wiki')).toBe(true);
    rmSync(brainDir, { recursive: true, force: true });
  });

  it('is unchanged (wiki-only) when no brainDir/projectSlug given', async () => {
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir });
    expect(res.candidates.length).toBeGreaterThan(0);
    expect(res.candidates.every(c => c.source === 'wiki')).toBe(true);
  });
});

// --- SP-1 cross-project reservation (2026-08-20) ------------------------------
// Project scoping drops other-project (tier-5) pages once enough in-scope hits exist. That made
// cross-project transfer impossible: measured live, a query whose correct answer lived in another
// repo returned that page at rank 1 unscoped and NOTHING relevant when scoped — the page was
// dropped before ranking. A *second* brain that cannot carry a lesson between repos is a
// per-repo README.
//
// The reservation is deliberately narrow: a tier-5 page is kept only when it outscores EVERY
// in-scope candidate. Both directions are asserted here, because the boundary IS the contract —
// the pre-existing suppression tests ('C1 local-docs…', 'SP-1 family…') use fixtures whose
// other-project page scores EQUAL to the in-scope pages, and they must keep passing unchanged.
describe('SP-1 cross-project reservation', () => {
  const mk = (dir: string) => (slug: string, project: string, body: string) =>
    fsp.writeFile(join(dir, 'wiki', 'learnings', `${slug}.md`),
      `---\ntitle: ${slug}\ntype: learnings\nproject: ${project}\ndescription: ${slug} page\n---\n\n# ${slug}\n\n${body}\n`);

  it('keeps an other-project page that OUTSCORES every in-scope page, and ranks it first', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-cross-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const w = mk(dir);
    // three in-scope hits (>= SB_SCOPE_MIN_HITS) so tier-5 would normally be dropped outright
    await w('a1', 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    await w('a2', 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    await w('a3', 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    // the beta page is genuinely the better answer — the term dominates a short document
    await w('b-strong', 'beta', 'wireguard wireguard wireguard wireguard wireguard tunnel setup');

    const r = await knowledgeSearch({ query: 'wireguard', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    const slugs = r.candidates.map(c => c.path.replace(/^.*[\/]/, '').replace(/\.md$/, ''));
    expect(slugs).toContain('b-strong');
    // First, not appended: consumers read the top 1-2 candidates, so a tail slot is no slot.
    expect(slugs[0]).toBe('b-strong');
  });

  // D059: the reservation used to run ONLY in the "enough in-scope hits" (>=3) branch. With a
  // THIN in-scope set (<3, the broaden branch), `pool = scored` stayed tier-major sorted, so a
  // strictly-stronger other-project page was buried after every weak in-scope page — the exact
  // "slot at the tail is no slot" failure the reservation exists to prevent, and the projects
  // most likely to hit it (1-2 weak hits) are the small/new ones that most need cross-project
  // transfer.
  it('reserves an outscoring other-project page FIRST even when in-scope is thin (<3 hits)', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-crossthin-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const w = mk(dir);
    // only two in-scope hits — below SB_SCOPE_MIN_HITS(3), so the broaden branch is exercised
    await w('a1', 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    await w('a2', 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    await w('b-strong', 'beta', 'wireguard wireguard wireguard wireguard wireguard tunnel setup');

    const r = await knowledgeSearch({ query: 'wireguard', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    const slugs = r.candidates.map(c => c.path.replace(/^.*[\/]/, '').replace(/\.md$/, ''));
    expect(slugs).toContain('b-strong');
    expect(slugs[0]).toBe('b-strong');   // placed FIRST, not buried after the weak in-scope pages
  });

  it('still drops an other-project page that merely TIES the in-scope pages', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-crosstie-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const w = mk(dir);
    const body = `wireguard tunnel keyword ${'detail '.repeat(40)}`;
    await w('a1', 'alpha', body);
    await w('a2', 'alpha', body);
    await w('a3', 'alpha', body);
    await w('b-tie', 'beta', body);   // byte-identical body ⇒ identical BM25 ⇒ not "better"

    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    const slugs = r.candidates.map(c => c.path.replace(/^.*[\/]/, '').replace(/\.md$/, ''));
    expect(slugs).not.toContain('b-tie');
  });

  it('SB_SCOPE_CROSS_SLOTS=0 restores the pre-2026-08-20 hard drop', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-crossoff-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const w = mk(dir);
    await w('a1', 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    await w('a2', 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    await w('a3', 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    await w('b-strong', 'beta', 'wireguard wireguard wireguard wireguard wireguard tunnel setup');

    process.env.SB_SCOPE_CROSS_SLOTS = '0';
    try {
      const r = await knowledgeSearch({ query: 'wireguard', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
      const slugs = r.candidates.map(c => c.path.replace(/^.*[\/]/, '').replace(/\.md$/, ''));
      expect(slugs).not.toContain('b-strong');
    } finally {
      delete process.env.SB_SCOPE_CROSS_SLOTS;
    }
  });
});

// --- Review follow-ups (2026-08-20): gaps the test-quality pass named explicitly ------------
describe('cross-project reservation: interactions and knobs', () => {
  const mk = (dir: string) => (slug: string, project: string, body: string) =>
    fsp.writeFile(join(dir, 'wiki', 'learnings', `${slug}.md`),
      `---\ntitle: ${slug}\ntype: learnings\nproject: ${project}\ndescription: ${slug} page\n---\n\n# ${slug}\n\n${body}\n`);
  const seed = async (prefix: string) => {
    const dir = await fsp.mkdtemp(join(tmpdir(), prefix));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    return dir;
  };

  it('score_norm: a reserved out-of-scope page becomes the 1.0 anchor, pushing in-scope below 1', async () => {
    // The field doc says the anchor can now sit OUTSIDE the requested scope. Documented behaviour
    // with no test is a promise, not a contract — this is the lock.
    const dir = await seed('ks-crossnorm-');
    const w = mk(dir);
    for (const s of ['a1', 'a2', 'a3']) await w(s, 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    await w('b-strong', 'beta', 'wireguard wireguard wireguard wireguard wireguard tunnel setup');

    const r = await knowledgeSearch({ query: 'wireguard', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    const norm = (slug: string) => r.candidates.find(c => c.path.includes(`${slug}.md`))?.score_norm;
    expect(norm('b-strong'), 'the reserved out-of-scope page anchors the scale').toBe(1);
    for (const s of ['a1', 'a2', 'a3']) {
      const n = norm(s);
      if (n !== undefined) expect(n, `${s} must normalize below the out-of-scope anchor`).toBeLessThan(1);
    }
  });

  it('SB_SCOPE_CROSS_SLOTS=2 reserves two, not a hardcoded one', async () => {
    // Guards a bug that would always reserve exactly 1 regardless of the knob.
    const dir = await seed('ks-crossslots2-');
    const w = mk(dir);
    for (const s of ['a1', 'a2', 'a3']) await w(s, 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    await w('b-one', 'beta', 'wireguard wireguard wireguard wireguard wireguard tunnel setup');
    await w('b-two', 'gamma', 'wireguard wireguard wireguard wireguard tunnel setup notes');

    process.env.SB_SCOPE_CROSS_SLOTS = '2';
    try {
      const r = await knowledgeSearch({ query: 'wireguard', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
      const slugs = r.candidates.map(c => c.path.replace(/^.*[\/]/, '').replace(/\.md$/, ''));
      expect(slugs).toContain('b-one');
      expect(slugs).toContain('b-two');
    } finally {
      delete process.env.SB_SCOPE_CROSS_SLOTS;
    }
  });

  it('a reserved page still has to satisfy the grounding gate (feature composition)', async () => {
    // knowledge-search.ts claims "precision is still enforced downstream — the injection CLIs
    // apply the grounding gate to every candidate, reserved or not". Asserted here at the field
    // level: a reserved page whose head fields do NOT mention the query grounds 0, so the CLI
    // gate (grounded >= min(2, query_terms)) rejects it even though scoping reserved it.
    const dir = await seed('ks-crossground-');
    const w = mk(dir);
    for (const s of ['a1', 'a2', 'a3']) await w(s, 'alpha', `wireguard mentioned once ${'filler '.repeat(60)}`);
    // Title/description carry no query term; the term is body-only.
    await w('unrelated-beta', 'beta', 'wireguard wireguard wireguard wireguard wireguard tunnel');

    const r = await knowledgeSearch({ query: 'wireguard', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    const reserved = r.candidates.find(c => c.path.includes('unrelated-beta.md'));
    expect(reserved, 'scoping should have reserved it on score').toBeDefined();
    expect(reserved!.grounded, 'but it is not ABOUT the query, so grounding must reject it').toBe(0);
  });
});

// G3 suite guard (R1 review): the access-counts path used to be resolved inside the load's
// try/catch and the save's .catch(() => {}), so the guard's throw was swallowed and the search
// "succeeded" against the real brain dir. It is resolved once, up front, so the throw propagates.
describe('suite guard reaches knowledgeSearch callers', () => {
  it('a brain dir resolving to <real home>/.second-brain rejects the search', async () => {
    const dir = await wiki();
    const fakeHome = mkdtempSync(join(tmpdir(), 'ks-fake-home-'));
    process.env.SB_SUITE_REAL_HOME_PATH = fakeHome;
    await expect(knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, brainDir: join(fakeHome, '.second-brain') }))
      .rejects.toThrow(/suite guard/);
    delete process.env.BRAIN_DIR;
    process.env.SB_BRAIN_DIR = join(fakeHome, '.second-brain');
    await expect(knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir })).rejects.toThrow(/suite guard/);
  });

  it('a sandboxed brain dir under the same fake home still searches', async () => {
    const dir = await wiki();
    const fakeHome = mkdtempSync(join(tmpdir(), 'ks-fake-home-'));
    process.env.SB_SUITE_REAL_HOME_PATH = fakeHome;
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, brainDir: join(fakeHome, 'sandbox-brain') });
    expect(slugs(r)).toContain('alpha');
  });
});

// SB_INJECT_GATE (R1 review): only the literal "1" turned the gate on, so "true"/"on"/"yes"
// silently fell back to the legacy filter. parseInjectGate is what knowledge-search-cli reads.
describe('parseInjectGate (knowledge-search-cli SB_INJECT_GATE)', () => {
  it.each(['1', 'on', 'true', 'yes', 'ON', 'True', 'YES', ' on '])('%j turns the gate on, silently', (raw) => {
    const warn = vi.fn();
    expect(parseInjectGate(raw, warn)).toBe(true);
    expect(warn).not.toHaveBeenCalled();
  });

  it.each([undefined, '', '0', 'off', 'false', 'no', 'OFF', 'No'])('%j is the legacy filter, silently', (raw) => {
    const warn = vi.fn();
    expect(parseInjectGate(raw, warn)).toBe(false);
    expect(warn).not.toHaveBeenCalled();
  });

  it.each(['2', 'enabled', 'y', 'tru'])('%j is not recognised: legacy filter plus exactly one warning', (raw) => {
    const warn = vi.fn();
    expect(parseInjectGate(raw, warn)).toBe(false);
    expect(warn).toHaveBeenCalledTimes(1);
    expect(warn.mock.calls[0][0]).toMatch(/SB_INJECT_GATE/);
  });

  it('knowledge-search-cli reads the knob through it, warning on stderr (source lock)', async () => {
    const src = await fsp.readFile(join(__dirname, 'knowledge-search-cli.ts'), 'utf8');
    expect(src).toMatch(/parseInjectGate\(process\.env\.SB_INJECT_GATE,/);
    expect(src).toMatch(/process\.stderr\.write/);
    expect(src).not.toMatch(/SB_INJECT_GATE\s*===/);
  });
});

// SB_INJECT_PRECISION (R1 rollback switch): the same words as SB_INJECT_GATE (trimmed, any case).
// off/0/false/no restore the 0.54.1 gate; on/1/true/yes, empty and unset keep the R1 gate. Anything
// else keeps the R1 gate and warns exactly once, so a typo can neither silently roll the gate back
// nor silently fail to.
describe('parseInjectPrecision (SB_INJECT_PRECISION kill switch)', () => {
  it.each([undefined, '', 'on', 'ON', 'On', ' on ', '  ', '1', 'true', 'TRUE', 'yes', ' Yes '])('%j keeps the R1 gate, silently', (raw) => {
    const warn = vi.fn();
    expect(parseInjectPrecision(raw, warn)).toBe(true);
    expect(warn).not.toHaveBeenCalled();
  });

  it.each(['off', 'OFF', 'Off', ' off ', '0', 'false', 'FALSE', 'no', ' No '])('%j restores the 0.54.1 gate, silently', (raw) => {
    const warn = vi.fn();
    expect(parseInjectPrecision(raw, warn)).toBe(false);
    expect(warn).not.toHaveBeenCalled();
  });

  it.each(['legacy', 'of', 'offf', '2', 'n', 'disabled', 'o ff'])('%j is not recognised: R1 gate plus exactly one warning', (raw) => {
    const warn = vi.fn();
    expect(parseInjectPrecision(raw, warn)).toBe(true);
    expect(warn).toHaveBeenCalledTimes(1);
    expect(warn.mock.calls[0][0]).toMatch(/SB_INJECT_PRECISION/);
    expect(warn.mock.calls[0][0]).toContain(JSON.stringify(raw));
  });

  it('accepts exactly the words parseInjectGate accepts (one vocabulary for both switches)', () => {
    for (const raw of ['1', 'on', 'true', 'yes', '0', 'off', 'false', 'no', '', 'bogus']) {
      const gateWarn = vi.fn(), precWarn = vi.fn();
      parseInjectGate(raw, gateWarn);
      parseInjectPrecision(raw, precWarn);
      expect(precWarn.mock.calls.length, raw).toBe(gateWarn.mock.calls.length);
      // Same word, same polarity: a word that turns SB_INJECT_GATE on keeps the precision gate on.
      if (gateWarn.mock.calls.length === 0 && raw !== '') {
        expect(parseInjectPrecision(raw, () => {}), raw).toBe(parseInjectGate(raw, () => {}));
      }
    }
  });

  it('the engine reads the switch once, at module load, and no CLI reads it on its own (source lock)', async () => {
    const engine = await fsp.readFile(join(__dirname, 'knowledge-search.ts'), 'utf8');
    expect(engine.match(/process\.env\.SB_INJECT_PRECISION/g) ?? []).toHaveLength(1);
    expect(engine).toMatch(/^const INJECT_PRECISION = parseInjectPrecision\(process\.env\.SB_INJECT_PRECISION,/m);
    for (const cli of ['context-serve-cli.ts', 'knowledge-search-cli.ts']) {
      const src = await fsp.readFile(join(__dirname, cli), 'utf8');
      expect(src, cli).not.toMatch(/process\.env\.SB_INJECT_PRECISION/);
    }
  });

  it('knowledge-search-cli\'s default (recall) branch is the shared 0.54 filter (source lock)', async () => {
    const src = await fsp.readFile(join(__dirname, 'knowledge-search-cli.ts'), 'utf8');
    expect(src).toMatch(/legacyWikiFilter\(\s*result\.candidates/);
    expect(src).not.toMatch(/query_terms\s*\?\?/);
  });
});

// The hooks run context-serve-cli and knowledge-search-cli with stderr discarded, so the switch's
// stderr warning alone left an operator's mistyped rollback silently doing nothing. The parse
// outcome is exported (injectPrecisionStatus) and reportInjectPrecision turns it into durable rows:
// an unrecognised value -> error-log.jsonl (appendErrorLog, exit_code 1); `off` -> one TRACE row in
// audit-log.jsonl in sb_log_error's rerouted gate-row shape; the default R1 mode -> no I/O at all.
type Engine = typeof import('./knowledge-search.js');
/** A fresh engine loaded under SB_INJECT_PRECISION=value (undefined = unset), stderr captured. */
async function engineWith(value: string | undefined): Promise<{ ks: Engine; stderr: string[] }> {
  const stderr: string[] = [];
  const spy = vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => { stderr.push(String(chunk)); return true; });
  try {
    if (value === undefined) delete process.env.SB_INJECT_PRECISION;
    else process.env.SB_INJECT_PRECISION = value;
    vi.resetModules();
    return { ks: await import('./knowledge-search.js') as Engine, stderr };
  } finally {
    spy.mockRestore();
  }
}
const TRACE_ROW = (script: string) => new RegExp(
  `^\\{"timestamp":"\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z","script":"${script}","message":"gate=inject-precision mode=off","exit_code":0\\}\\n$`);

describe('injectPrecisionStatus (the switch\'s parse outcome, for the CLIs and the MCP server)', () => {
  it.each([[undefined], [''], ['on'], ['YES'], ['1'], [' true ']])('SB_INJECT_PRECISION=%j: mode r1, no warning', async (value) => {
    const { ks } = await engineWith(value);
    expect(ks.injectPrecisionStatus()).toEqual({ mode: 'r1' });
  });

  it.each([['off'], ['0'], ['false'], [' No ']])('SB_INJECT_PRECISION=%j: mode off, no warning', async (value) => {
    const { ks } = await engineWith(value);
    expect(ks.injectPrecisionStatus()).toEqual({ mode: 'off' });
  });

  it('an unrecognised value: mode r1 plus the warning, and the stderr line is still written once', async () => {
    const { ks, stderr } = await engineWith('bogus');
    const st = ks.injectPrecisionStatus();
    expect(st.mode).toBe('r1');
    expect(st.warning).toMatch(/^SB_INJECT_PRECISION="bogus" is not recognised/);
    expect(stderr.filter(w => w.includes('SB_INJECT_PRECISION="bogus"'))).toHaveLength(1);
  });

  it('the default argument is the module\'s own status (off -> a TRACE row)', async () => {
    const { ks } = await engineWith('off');
    const dir = mkdtempSync(join(tmpdir(), 'ks-prec-'));
    await ks.reportInjectPrecision(dir, 'context-serve-cli');
    expect(await fsp.readFile(join(dir, 'audit-log.jsonl'), 'utf8')).toMatch(TRACE_ROW('context-serve-cli'));
  });
});

describe('reportInjectPrecision (durable rows on the hook path)', () => {
  let stderr: string[] = [];
  beforeEach(() => {
    stderr = [];
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => { stderr.push(String(chunk)); return true; });
  });
  afterEach(() => { vi.restoreAllMocks(); });

  it('R1 with a recognised value does no I/O at all (not even creating the brain dir)', async () => {
    const { reportInjectPrecision } = await import('./knowledge-search.js');
    const dir = join(mkdtempSync(join(tmpdir(), 'ks-prec-')), 'never-created');
    await reportInjectPrecision(dir, 'context-serve-cli', { mode: 'r1' });
    expect(existsSync(dir)).toBe(false);
    expect(stderr).toEqual([]);
  });

  it('off: exactly one TRACE row in audit-log.jsonl, in sb_log_error\'s gate-row shape, and no error row', async () => {
    const { reportInjectPrecision } = await import('./knowledge-search.js');
    const dir = mkdtempSync(join(tmpdir(), 'ks-prec-'));
    await reportInjectPrecision(dir, 'knowledge-search-cli', { mode: 'off' });
    expect(await fsp.readFile(join(dir, 'audit-log.jsonl'), 'utf8')).toMatch(TRACE_ROW('knowledge-search-cli'));
    expect(existsSync(join(dir, 'error-log.jsonl'))).toBe(false);
    expect(stderr, 'a successful TRACE is silent').toEqual([]);
  });

  it('per invocation: each call appends its own row (a CLI process is one invocation)', async () => {
    const { reportInjectPrecision } = await import('./knowledge-search.js');
    const dir = mkdtempSync(join(tmpdir(), 'ks-prec-'));
    await reportInjectPrecision(dir, 'context-serve-cli', { mode: 'off' });
    await reportInjectPrecision(dir, 'context-serve-cli', { mode: 'off' });
    const lines = (await fsp.readFile(join(dir, 'audit-log.jsonl'), 'utf8')).split('\n').filter(Boolean);
    expect(lines).toHaveLength(2);
    for (const l of lines) expect(l + '\n').toMatch(TRACE_ROW('context-serve-cli'));
  });

  it('an unrecognised value: one error-log.jsonl row naming the CLI (exit_code 1), echoed to stderr, no TRACE', async () => {
    const { reportInjectPrecision } = await import('./knowledge-search.js');
    const dir = mkdtempSync(join(tmpdir(), 'ks-prec-'));
    const warning = 'SB_INJECT_PRECISION="bogus" is not recognised (test)';
    await reportInjectPrecision(dir, 'context-serve-cli', { mode: 'r1', warning });
    const rows = (await fsp.readFile(join(dir, 'error-log.jsonl'), 'utf8')).split('\n').filter(Boolean);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatch(/^\{"timestamp":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z","script":"context-serve-cli",/);
    expect(JSON.parse(rows[0])).toMatchObject({ script: 'context-serve-cli', message: warning, exit_code: 1 });
    expect(existsSync(join(dir, 'audit-log.jsonl'))).toBe(false);
    expect(stderr.join('')).toContain('[context-serve-cli] SB_INJECT_PRECISION="bogus"');
  });

  it('a write failure never throws into the CLI: it is echoed to stderr', async () => {
    const { reportInjectPrecision } = await import('./knowledge-search.js');
    const notADir = join(mkdtempSync(join(tmpdir(), 'ks-prec-')), 'a-file');
    writeFileSync(notADir, 'x');
    await expect(reportInjectPrecision(notADir, 'context-serve-cli', { mode: 'off' })).resolves.toBeUndefined();
    expect(stderr.join('')).toMatch(/\[context-serve-cli\] gate=inject-precision mode=off \(audit-log\.jsonl write failed: /);
  });

  it.each([
    ['context-serve-cli.ts', /await reportInjectPrecision\(brainDir, 'context-serve-cli'\);/],
    ['knowledge-search-cli.ts', /await reportInjectPrecision\(brainDir, 'knowledge-search-cli'\);/],
    [join('..', 'server.ts'), /await reportInjectPrecision\(BRAIN_DIR, 'mcp-server'\);/],
  ])('%s reports the switch (source lock)', async (file, re) => {
    const src = await fsp.readFile(join(__dirname, file), 'utf8');
    expect(src.match(new RegExp(re.source, 'g')) ?? [], file).toHaveLength(1);
  });
});

// legacyWikiFilter, against HANDCRAFTED candidates (not engine output): the 0.54.1 filter is
// score >= minScore, relevance >= minRelevance, grounded >= min(minGrounded, candidates[0].query_terms
// ?? minGrounded). Every expectation below is a literal worked out by hand from that rule.
describe('legacyWikiFilter (the 0.54.1 filter, independent literals)', () => {
  type Cand = KnowledgeSearchResult['candidates'][number];
  const cand = (slug: string, grounded: number, extra: Partial<Cand> = {}): Cand => ({
    path: `/w/${slug}.md`, score: 1, score_norm: 1, relevance: 10, grounded,
    description: '', tokens: 10, source: 'wiki', ...extra,
  });
  const slugs = (cs: Cand[]) => cs.map(c => c.path.replace(/^.*\//, '').replace(/\.md$/, ''));
  const o = { minScore: 0, minRelevance: 0, minGrounded: 2 };

  it('empty candidates: nothing to filter, no throw (the need falls back to minGrounded)', () => {
    expect(legacyWikiFilter([], o)).toEqual([]);
  });

  it('undefined query_terms on candidates[0]: the need is minGrounded itself (2)', () => {
    // b's query_terms (1) is never consulted: only candidates[0]'s is, and it is missing.
    const list = [cand('a', 1), cand('b', 1, { query_terms: 1 }), cand('c', 2, { query_terms: 1 })];
    expect(slugs(legacyWikiFilter(list, o))).toEqual(['c']);
  });

  it('minGrounded 0: the need is 0, so grounded 0 passes, but the score and relevance floors still apply', () => {
    const list = [
      cand('a', 0, { query_terms: 3 }),
      cand('b', 0, { query_terms: 3, score: 0.1 }),
      cand('c', 0, { query_terms: 3, relevance: 1 }),
    ];
    expect(slugs(legacyWikiFilter(list, { minScore: 0.5, minRelevance: 5, minGrounded: 0 }))).toEqual(['a']);
  });

  it('the clamp reads candidates[0].query_terms RAW: not each candidate\'s own, not discriminative_terms', () => {
    // head query_terms 1 -> need min(2, 1) = 1: both pass, although b's own query_terms (5) would ask for 2.
    expect(slugs(legacyWikiFilter([cand('a', 1, { query_terms: 1 }), cand('b', 1, { query_terms: 5 })], o))).toEqual(['a', 'b']);
    // Same two pages, head swapped: need min(2, 5) = 2, neither passes.
    expect(slugs(legacyWikiFilter([cand('b', 1, { query_terms: 5 }), cand('a', 1, { query_terms: 1 })], o))).toEqual([]);
    // discriminative_terms 1 is ignored: the need stays min(2, query_terms 5) = 2.
    expect(slugs(legacyWikiFilter([cand('d', 1, { query_terms: 5, discriminative_terms: 1 })], o))).toEqual([]);
  });

  it('pre-filtering the list changes the clamp (why the docstring says: pass the engine\'s own list)', () => {
    // Gated whole, the head (query_terms 1) sets need 1 and b (grounded 1) passes. Drop the head
    // first (a caller's score floor, say) and b becomes the head: need min(2, 5) = 2, b is lost.
    const full = [cand('a', 1, { query_terms: 1, score: 0.01 }), cand('b', 1, { query_terms: 5 })];
    expect(slugs(legacyWikiFilter(full, o))).toEqual(['a', 'b']);
    expect(slugs(legacyWikiFilter(full.filter(c => c.score >= 0.5), o))).toEqual([]);
  });
});
