// Deterministic retrieval guards (no LLM, no model). These are invariant/characterization
// guards over the live search surfaces: a regression that breaks recall, overwrite semantics, or
// the episodic search→read round-trip flips one of these RED. Embeddings are disabled so every
// assertion is BM25 / text-mode deterministic. Covers episodic recall (search→read round-trip)
// and protects the episodic sanitization guarantee.
import { describe, it, expect, beforeAll } from 'vitest';
import { promises as fs, mkdtempSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeSearch, injectionGroundingNeed, injectableWiki } from './knowledge-search.js';
import { buildEpisodicIndex, episodicSearch, episodicRead } from './episodic-search.js';

beforeAll(() => {
  process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
  process.env.BRAIN_DIR = mkdtempSync(join(tmpdir(), 'rg-brain-'));
});

async function seedWiki(pages: Record<string, string>): Promise<string> {
  const dir = await fs.mkdtemp(join(tmpdir(), 'rg-wiki-'));
  await fs.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
  for (const [slug, body] of Object.entries(pages)) {
    await fs.writeFile(join(dir, 'wiki', 'entities', `${slug}.md`),
      `---\ntitle: ${slug}\ndescription: ${slug} page\n---\n\n# ${slug}\n\n${body}\n`);
  }
  return dir;
}

describe('P8a retrieval guards (deterministic)', () => {
  it('exact-term canary: a unique rare term retrieves its page at rank #1', async () => {
    const dir = await seedWiki({
      auth: 'authentication and login session handling',
      cache: 'caching layer and invalidation',
      target: 'the zzqxueglerb subsystem orchestrates retries',
    });
    const r = await knowledgeSearch({ query: 'zzqxueglerb', knowledgeDir: dir });
    expect(r.candidates.length).toBeGreaterThan(0);
    expect(r.candidates[0].path).toContain('target.md');
  });

  it('knowledge-update: overwriting a page makes the new content win and the old content stop matching', async () => {
    const dir = await seedWiki({ note: 'the apple deployment runs on alpha hardware' });
    const file = join(dir, 'wiki', 'entities', 'note.md');

    const before = await knowledgeSearch({ query: 'apple alpha', knowledgeDir: dir });
    expect(before.candidates[0]?.path).toContain('note.md');

    // Overwrite in place with entirely new content (the "knowledge update").
    await fs.writeFile(file, `---\ntitle: note\ndescription: note page\n---\n\n# note\n\nthe banana deployment runs on beta hardware\n`);

    const after = await knowledgeSearch({ query: 'banana beta', knowledgeDir: dir });
    expect(after.candidates[0]?.path, 'new content must be retrievable').toContain('note.md');

    // The stale terms must no longer pull the page as a confident match.
    const stale = await knowledgeSearch({ query: 'apple alpha', knowledgeDir: dir });
    const staleHit = stale.candidates.find(c => c.path.includes('note.md'));
    expect(staleHit, 'overwritten page must not still match its OLD terms').toBeUndefined();
  });

  it('episodic recall round-trip: a planted exchange is found by search and read back by episodicRead', async () => {
    const brainDir = await fs.mkdtemp(join(tmpdir(), 'rg-epi-'));
    const tdir = join(brainDir, 'transcripts');
    await fs.mkdir(tdir, { recursive: true });
    const file = join(tdir, 'sess9_alpha_2026-06-28.txt');
    await fs.writeFile(file, [
      '--- session-meta ---', 'session_id: sess9', 'project_slug: alpha', 'date: 2026-06-28', '---', '',
      'USER:', 'we decided to use the zzqxueglerb retry strategy for the api', '',
    ].join('\n'));

    await buildEpisodicIndex(brainDir);

    // Retrieval: text mode finds the planted exchange.
    const res = await episodicSearch({ query: 'zzqxueglerb retry strategy', mode: 'text' }, brainDir);
    expect(res.results.length, 'planted exchange must be retrievable').toBeGreaterThan(0);
    expect(JSON.stringify(res.results)).toContain('zzqxueglerb');

    // Reading: the same exchange is readable back (retrieval-vs-reading decomposition).
    const read = await episodicRead(file);
    expect(read.content).toContain('zzqxueglerb retry strategy');
    expect(read.sessionId).toBe('sess9');
  });

  it('abstention: a query matching no document returns no positive-score candidate', async () => {
    const dir = await seedWiki({
      auth: 'authentication and login session handling',
      cache: 'caching layer and invalidation',
    });
    const r = await knowledgeSearch({ query: 'nonexistentzzqterm', knowledgeDir: dir });
    // BM25 score is 0 for zero term overlap, and the access-count boost is CUT + graph boost is
    // multiplicative on base, so nothing can fabricate a positive score for an absent term.
    expect(r.candidates.filter(c => c.score > 0), 'no doc should match an absent term').toHaveLength(0);
  });

  it('episodic golden + project scoping: each planted fact is retrievable and the project filter isolates', async () => {
    const brainDir = await fs.mkdtemp(join(tmpdir(), 'rg-epg-'));
    const tdir = join(brainDir, 'transcripts');
    await fs.mkdir(tdir, { recursive: true });
    const mk = (sess: string, proj: string, text: string) =>
      fs.writeFile(join(tdir, `${sess}_${proj}_2026-06-28.txt`),
        ['--- session-meta ---', `session_id: ${sess}`, `project_slug: ${proj}`, 'date: 2026-06-28', '---', '', 'USER:', text, ''].join('\n'));
    await mk('s1', 'alpha', 'we picked grpcwidget for alpha transport');
    await mk('s2', 'beta', 'we picked restwidget for beta transport');
    await buildEpisodicIndex(brainDir);

    // each distinctive fact is retrievable
    expect(JSON.stringify((await episodicSearch({ query: 'grpcwidget', mode: 'text' }, brainDir)).results)).toContain('grpcwidget');
    expect(JSON.stringify((await episodicSearch({ query: 'restwidget', mode: 'text' }, brainDir)).results)).toContain('restwidget');

    // the project hard-filter isolates: 'transport' appears in both, but scoped to alpha returns only alpha
    const scoped = JSON.stringify((await episodicSearch({ query: 'transport', mode: 'text', project: 'alpha' }, brainDir)).results);
    expect(scoped).toContain('grpcwidget');
    expect(scoped).not.toContain('restwidget');
  });

  it('graph ranking boost is OFF by default and re-enables only via SB_GRAPH_RANKING_BOOST (P7)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'rg-boost-'));
    await fs.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
    const W = (slug: string, related: string, body: string) =>
      fs.writeFile(join(dir, 'wiki', 'entities', `${slug}.md`),
        `---\ntitle: ${slug}\ntype: entities\ndescription: ${slug}\nrelated: ${related ? `[[${related}]]` : '[]'}\n---\n\n# ${slug}\n\n${body}\n`);
    // 'strong' (high base) is related to 'related-one', so the boost (when on) flows to 'related-one'.
    // 'loner-one' has the same weak text match but no relation — it is never boosted.
    await W('strong', 'related-one', 'zzqterm zzqterm zzqterm zzqterm subsystem');
    await W('related-one', '', 'zzqterm zzqterm related notes');
    await W('loner-one', '', 'zzqterm zzqterm loner notes');
    const scoreOf = (r: any, slug: string): number =>
      r.candidates.find((c: any) => String(c.path).replace(/\\/g, '/').endsWith(`/${slug}.md`))?.score ?? 0;

    delete process.env.SB_GRAPH_RANKING_BOOST;            // default
    const off = await knowledgeSearch({ query: 'zzqterm', knowledgeDir: dir });
    process.env.SB_GRAPH_RANKING_BOOST = '1';             // opt in
    const on = await knowledgeSearch({ query: 'zzqterm', knowledgeDir: dir });
    delete process.env.SB_GRAPH_RANKING_BOOST;

    // sanity: the related page is actually retrieved both ways (not floor-evicted)
    expect(scoreOf(off, 'related-one')).toBeGreaterThan(0);
    // The proof of the P7 demote: the related page is boosted ONLY when the flag is set. With the
    // default (flag unset) it is unboosted, so its with-flag score is strictly higher.
    expect(scoreOf(on, 'related-one')).toBeGreaterThan(scoreOf(off, 'related-one'));
  });
});

// --- Gate satisfiability (the 0.045 incident, 2026-08-20) ---------------------
//
// A relevance gate must be REACHABLE by the scale it gates. `SB_PERSONA_WIKI_MIN_SCORE`
// defaulted to 0.045 on `score`, but in hybrid mode `score` is RRF: a document ranked #1 by
// BOTH engines scores 2/(RRF_K+1) = 0.0328, and the only post-fusion multipliers are the stub
// penalty (x0.5, downward) and recency (x1.3). Ceiling 0.0426 < 0.045 — so the gate discarded
// 100% of hybrid-mode hits and per-prompt wiki injection was dead for every session with
// embeddings active. It passed only in bm25-only mode, where scores are raw open-ended BM25 —
// which is exactly why the whole test suite stayed green: every test that touches this path
// pins the gate to 0 and/or disables embeddings, so the failing configuration is the ONLY one
// never exercised. Measured cost before the fix: 0 reads over 83 injected items, 13 sessions.
//
// Pure arithmetic + source scan, so it runs in CI with no model and cannot be neutered by an
// env override the way the behavioural tests were.
describe('injection gate satisfiability', () => {
  const RRF_K = 60;
  const RECENCY_BOOST_MAX = 0.3;
  /** Best achievable fused score: rank 1 in both rankers, full recency boost. */
  const RRF_CEILING = (2 / (RRF_K + 1)) * (1 + RECENCY_BOOST_MAX);

  it('no shipped default gates `score` above the RRF ceiling', async () => {
    const hook = await fs.readFile(
      join(__dirname, '..', '..', '..', 'scripts', 'persona-context.sh'), 'utf8');
    const m = hook.match(/SB_PERSONA_WIKI_MIN_SCORE:-([0-9.]+)/);
    expect(m, 'SB_PERSONA_WIKI_MIN_SCORE default not found in persona-context.sh').toBeTruthy();
    const shipped = parseFloat(m![1]);
    // Strictly below, not equal: a gate AT the ceiling passes only the single perfect-rank
    // page with a same-day timestamp, which is indistinguishable from dead in practice.
    expect(shipped).toBeLessThan(RRF_CEILING);
  });

  it('exposes relevance + grounded so gates can use an absolute scale', async () => {
    const dir = await seedWiki({
      'tunnel-config': 'wireguard tunnel configuration details repeated tunnel tunnel',
      // Must share ONE query term in its BODY so it clears the relevance floor and is actually
      // RETURNED. With no overlap it scored 0, was floor-filtered out, `off` was undefined, and
      // the conditional assertion below silently never ran — a vacuous test, i.e. the exact
      // defect class this branch exists to fix, found in this branch's own new test by review.
      // Short body, repeated query term: enough BM25 weight to clear the relevance floor
      // (MIN_SCORE_RATIO = 15% of the top score) so it is actually RETURNED. With no overlap it
      // scored 0, was floor-filtered out, `off` was undefined, and the conditional assertion
      // below silently never ran — a vacuous test, i.e. the exact defect class this branch
      // exists to fix, found in this branch's own new test by review.
      'unrelated-page': 'wireguard wireguard tunnel tunnel tunnel gardening compost soil',
    });
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    const top = r.candidates[0];
    // relevance is frozen BM25 — an OPEN scale, so an absolute threshold is meaningful on it.
    expect(top.relevance).toBeGreaterThan(0);
    // grounded counts query terms in title/description/tags only; 'tunnel' is in the title.
    expect(top.grounded).toBeGreaterThanOrEqual(1);
    expect(top.query_terms).toBe(2);
    // The off-topic page shares no head-field term — this is the signal an absolute score
    // cannot give, and the reason the gate is a conjunction.
    const off = r.candidates.find(c => c.path.includes('unrelated-page'));
    expect(off, 'off-topic page must be RETURNED or this assertion proves nothing').toBeDefined();
    // It matches 'tunnel' in the BODY so it scores — but the term is absent from its title,
    // description and tags, so it is not ABOUT the query. That gap is the entire signal.
    expect(off!.grounded).toBe(0);
  });
});

// --- Grounding fails CLOSED on an all-filler query (review finding, 2026-08-20) ------------
// An earlier revision of discriminativeTerms() fell back to raw overlap whenever the df filter
// emptied the term list. Review proved that reopened the precision hole it was built to close:
// on a topically-narrow wiki a casual prompt made ENTIRELY of connector words has every term
// corpus-common, the fallback handed the filler back, and an off-topic page whose TITLE happens
// to contain "the"/"way" grounded at 2 and would be injected under the shipped defaults.
// No test covered the all-terms-common case, which is exactly why it survived. This is it.
describe('grounding: all-filler query grounds nothing', () => {
  it('a query whose every term is corpus-common cannot ground an off-topic page', async () => {
    const pages: Record<string, string> = {};
    // >= MIN_CORPUS_FOR_DF (8) so the df filter is active at all; every page carries the filler,
    // so df == N for each filler term and none of them is discriminative.
    for (let i = 0; i < 10; i++) {
      pages[`topic-${i}`] = 'what is the way of course general common material';
    }
    // The trap: filler words sitting in a TITLE, where grounding looks.
    pages['the-way-of-gardening'] = 'soil compost and general planting material';
    const dir = await seedWiki(pages);

    const r = await knowledgeSearch({ query: 'what is the way', knowledgeDir: dir });
    const bad = r.candidates.filter(c => c.grounded >= 2);
    expect(bad.map(c => c.path), 'no page may ground on filler terms alone').toHaveLength(0);
  });

  it('a small corpus still grounds on shared terms (the df filter must not fire below the gate)', async () => {
    // The mirror case: below MIN_CORPUS_FOR_DF a share carries no information, so the filter is
    // skipped and genuine queries still work. Without this, protecting the case above would make
    // every small/first-install wiki un-injectable — the same unsatisfiable-gate failure again.
    const dir = await seedWiki({
      'wireguard-tunnel-setup': 'wireguard tunnel configuration for the vpn',
      'other-note': 'wireguard tunnel mentioned here too',
    });
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    expect(r.candidates[0].grounded, 'small corpus must still ground').toBeGreaterThanOrEqual(2);
  });
});

// --- Per-prompt injection gate (context-serve-cli, R1#4 of the 2026-10 design) ---------------
// The per-prompt CLI gates on grounding with three additions the recall CLI does not have:
// stubs are never injected, a cross-project page needs one more grounded term, and the need is
// clamped to the DISCRIMINATIVE term count rather than the raw token count. The raw-count clamp
// was unsatisfiable for any query with one real term among filler ("what is the pagerank
// thing": 5 tokens, 1 discriminative, need min(2,5)=2, grounded can be at most 1). These locks
// read the shipped default from the CLI source, so an edit there cannot dodge them.
async function shippedMinGrounded(): Promise<number> {
  const src = await fs.readFile(join(__dirname, 'context-serve-cli.ts'), 'utf8');
  const m = src.match(/envNum\('SB_INJECT_MIN_GROUNDED',\s*(\d+)/);
  expect(m, 'SB_INJECT_MIN_GROUNDED default not found in context-serve-cli.ts').toBeTruthy();
  return Number(m![1]);
}

interface Page { slug: string; title: string; description: string; project?: string; body?: string }
async function seedPages(pages: Page[]): Promise<string> {
  const dir = await fs.mkdtemp(join(tmpdir(), 'rg-gate-'));
  await fs.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
  const long = 'This page carries enough prose to clear the short-body stub test, so only the gate decides. ';
  for (const p of pages) {
    await fs.writeFile(join(dir, 'wiki', 'learnings', `${p.slug}.md`),
      `---\ntitle: "${p.title}"\ndescription: "${p.description}"\ntype: learnings\n`
      + (p.project ? `project: ${p.project}\n` : '') + `---\n\n${p.body ?? long.repeat(2)}\n`);
  }
  return dir;
}
/** >= MIN_CORPUS_FOR_DF filler pages so the df filter is live, none sharing the query terms. */
const filler = (n: number): Page[] => Array.from({ length: n }, (_, i) => ({
  slug: `filler-${i}`, title: `unrelated filler note ${i}`, description: 'gardening compost soil',
}));
const slugOf = (p: string) => p.replace(/^.*[\\/]/, '').replace(/\.md$/, '');

describe('per-prompt injection gate satisfiability (context-serve-cli)', () => {
  it('arithmetic: the need is at least 1 and never above the discriminative-term count', async () => {
    const minG = await shippedMinGrounded();
    for (let disc = 1; disc <= 12; disc++) {
      const inP = injectionGroundingNeed(minG, disc, false);
      const cross = injectionGroundingNeed(minG, disc, true);
      expect(inP, `in-project need at disc=${disc}`).toBeGreaterThanOrEqual(1);
      expect(inP, `in-project need at disc=${disc} is unsatisfiable`).toBeLessThanOrEqual(disc);
      expect(cross, `cross-project need at disc=${disc} is unsatisfiable`).toBeLessThanOrEqual(disc);
      // one more than in-project wherever the query has room for it, clamped otherwise
      expect(cross, `cross-project need at disc=${disc}`).toBe(Math.min(inP + 1, disc));
    }
    expect(injectionGroundingNeed(minG, 1, false)).toBe(1);
    expect(injectionGroundingNeed(minG, 1, true)).toBe(1);
  });

  it('arithmetic: an all-filler query (0 discriminative terms) still needs a grounded term, so it injects nothing', async () => {
    const minG = await shippedMinGrounded();
    // grounded <= discriminative terms = 0, so any need >= 1 rejects every page.
    expect(injectionGroundingNeed(minG, 0, false)).toBeGreaterThanOrEqual(1);
    expect(injectionGroundingNeed(minG, 0, true)).toBeGreaterThanOrEqual(1);
  });

  it('a 1-discriminative-term query injects an in-project page at shipped defaults', async () => {
    const dir = await seedPages([
      ...filler(9),
      { slug: 'pagerank-code-map', title: 'zzqpagerank code map', description: 'ranked code structure', project: 'alpha' },
    ]);
    const r = await knowledgeSearch({ query: 'what is the zzqpagerank thing', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    const hit = r.candidates.find(c => slugOf(c.path) === 'pagerank-code-map');
    expect(hit, 'the page must be retrieved at all').toBeDefined();
    expect(hit!.query_terms).toBe(5);
    expect(hit!.discriminative_terms).toBe(1);
    const inj = injectableWiki(r.candidates, { minScore: 0, minRelevance: 0, minGrounded: await shippedMinGrounded() });
    expect(inj.map(c => slugOf(c.path))).toContain('pagerank-code-map');
  });

  it('a cross-project page is injectable when it grounds on all discriminative terms, and not on fewer', async () => {
    const dir = await seedPages([
      ...filler(9),
      { slug: 'beta-both', title: 'zzqwidget zzqgadget pairing', description: 'beta notes', project: 'Beta' },
      { slug: 'beta-one', title: 'zzqwidget only', description: 'beta notes', project: 'beta' },
      { slug: 'alpha-one', title: 'zzqwidget alone', description: 'alpha notes', project: 'ALPHA' },
    ]);
    const minG = await shippedMinGrounded();
    for (const env of [{}, { SB_PROJECT_SCOPE: 'off' }]) {
      Object.assign(process.env, env);
      try {
        // `ALPHA` equals `alpha` for the cross flag (case-insensitive) but not for the
        // case-sensitive tier-1 anchor count, so the first pass also runs the anchors=0 path;
        // the second runs with scoping switched off entirely.
        const r = await knowledgeSearch({ query: 'zzqwidget zzqgadget', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
        if (!('SB_PROJECT_SCOPE' in env)) expect(r.anchors).toBe(0);
        const by = new Map(r.candidates.map(c => [slugOf(c.path), c]));
        expect(by.get('beta-both')?.cross_project).toBe(true);
        expect(by.get('beta-one')?.cross_project).toBe(true);
        expect(by.get('alpha-one')?.cross_project, 'project match is case-insensitive').toBeUndefined();
        const inj = injectableWiki(r.candidates, { minScore: 0, minRelevance: 0, minGrounded: minG }).map(c => slugOf(c.path));
        expect(inj, JSON.stringify(env)).toContain('beta-both');
        expect(inj, JSON.stringify(env)).not.toContain('beta-one');
      } finally {
        delete process.env.SB_PROJECT_SCOPE;
      }
    }
  });

  it('stub pages are flagged and never injectable', async () => {
    const dir = await seedPages([
      ...filler(9),
      { slug: 'zzqcache-stub', title: 'zzqcache eviction', description: 'Auto-created stub — needs expansion' },
      { slug: 'zzqcache-short', title: 'zzqcache warmup', description: 'cache warmup', body: 'tiny body' },
      { slug: 'zzqcache-real', title: 'zzqcache sizing', description: 'cache sizing rules' },
    ]);
    const r = await knowledgeSearch({ query: 'zzqcache', knowledgeDir: dir });
    const by = new Map(r.candidates.map(c => [slugOf(c.path), c]));
    expect(by.get('zzqcache-stub')?.stub).toBe(true);
    expect(by.get('zzqcache-short')?.stub).toBe(true);
    expect(by.get('zzqcache-real')?.stub).toBeUndefined();
    const inj = injectableWiki(r.candidates, { minScore: 0, minRelevance: 0, minGrounded: await shippedMinGrounded() });
    expect(inj.map(c => slugOf(c.path))).toEqual(['zzqcache-real']);
  });

  it('context-serve-cli gates its wiki section through injectableWiki (source lock)', async () => {
    const src = await fs.readFile(join(__dirname, 'context-serve-cli.ts'), 'utf8');
    expect(src).toMatch(/injectableWiki\(\s*result\.candidates/);
  });
});

describe('grounding: single letters never ground, digits do', () => {
  it('"m" (from "I\'m") cannot ground a page, "8" in "season 8" can', async () => {
    const dir = await seedPages([
      ...filler(9),
      { slug: 'affaan-m-ecc', title: 'affaan m plugin reference', description: 'reference notes' },
      { slug: 'season-8-modes', title: 'zzqseason 8 modes', description: 'mode status' },
    ]);
    const m = await knowledgeSearch({ query: 'm affaan', knowledgeDir: dir });
    expect(m.candidates.find(c => slugOf(c.path) === 'affaan-m-ecc')?.grounded).toBe(1);
    const s = await knowledgeSearch({ query: 'zzqseason 8', knowledgeDir: dir });
    const hit = s.candidates.find(c => slugOf(c.path) === 'season-8-modes');
    expect(hit?.grounded).toBe(2);
    expect(hit?.discriminative_terms).toBe(2);
  });
});

// --- Data-validated grounding stopwords (R1#4, 2026-10) -----------------------------------------
// Each word below was re-graded against the 40-prompt relevance sample on the real wiki
// (scratchpad review/stopword-validation.md): adding it pushes no grader-identified R2 page
// below the gate. Two words were tested and must keep grounding: "new" grounds R2 #27 ("season 8
// artifacts ... new") and "changes" grounds R2 #38's version-bump tripwire page.
describe('grounding: generic prompt verbs never ground, validated content words still do', () => {
  const GENERIC = ['check', 'checks', 'checked', 'one', 'old', 'add', 'added', 'change', 'changed',
    'relevant', 'correct', 'valid', 'everything', 'update', 'updated', 'missing', 'still', 'final',
    'ready', 'sure', 'let', 'see', 'try', 'continue'];

  it('a page titled with every generic word grounds only on its real term', async () => {
    const dir = await seedPages([
      ...filler(9),
      { slug: 'generic-title', title: `zzqanchor ${GENERIC.join(' ')}`, description: 'notes' },
    ]);
    const r = await knowledgeSearch({ query: `zzqanchor ${GENERIC.join(' ')}`, knowledgeDir: dir });
    const hit = r.candidates.find(c => slugOf(c.path) === 'generic-title');
    expect(hit?.discriminative_terms).toBe(1);
    expect(hit?.grounded).toBe(1);
  });

  it('"new" and "changes" stay grounding terms (R2 #27 and #38 depend on them)', async () => {
    const dir = await seedPages([
      ...filler(9),
      { slug: 'season-changes', title: 'zzqseason new changes', description: 'notes' },
    ]);
    const r = await knowledgeSearch({ query: 'zzqseason new changes', knowledgeDir: dir });
    expect(r.candidates.find(c => slugOf(c.path) === 'season-changes')?.grounded).toBe(3);
  });
});
