import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { promises as fsp } from 'fs';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeSearch, parseDoc } from './knowledge-search.js';
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
