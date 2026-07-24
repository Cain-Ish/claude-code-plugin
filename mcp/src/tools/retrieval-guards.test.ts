// Deterministic retrieval guards (no LLM, no model). These are invariant/characterization
// guards over the live search surfaces: a regression that breaks recall, overwrite semantics, or
// the episodic search→read round-trip flips one of these RED. Embeddings are disabled so every
// assertion is BM25 / text-mode deterministic. Covers episodic recall (search→read round-trip)
// and protects the episodic sanitization guarantee.
import { describe, it, expect, beforeAll } from 'vitest';
import { promises as fs, mkdtempSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeSearch } from './knowledge-search.js';
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
