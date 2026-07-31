import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { promises as fs } from 'fs';
import { readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';
import { applyCandidates, factHash, isFoldInMatch } from './consolidate-writer.js';
import { CandidateFact } from './candidate-facts.js';

let root: string;

async function mkStaging(): Promise<string> {
  const d = await fs.mkdtemp(join(tmpdir(), 'cw-test-'));
  await fs.mkdir(join(d, 'staging', 'wiki', 'entities'), { recursive: true });
  return d;
}

// No search stub: resolution is deterministic and reads the staging tree itself. The old
// stubbed seam is exactly what hid the vacuous-threshold bug — hand-picked score_norm values
// (0.9/0.99) could never reveal that the real ranker always returns 1.0 for the top hit.
const OPTS = () => ({ dreamId: 'drm_20260730T120000Z', date: '2026-07-30' });

beforeEach(async () => { root = await mkStaging(); });
afterEach(async () => { await fs.rm(root, { recursive: true, force: true }); });

describe('applyCandidates', () => {
  it('ADD renders a born-valid page: 7 required fields + provenance + Sources back-ref', async () => {
    const facts: CandidateFact[] = [{ kind: 'learning', title: 'Foo needs bar', claim: 'Foo requires bar to work.', evidence: 'seen in session', source: 'a_b_2026-07-30.txt', confidence: 'high' }];
    const r = await applyCandidates(join(root, 'staging'), facts, OPTS());
    expect(r.added).toEqual(['learnings/foo-needs-bar.md']);
    const page = await fs.readFile(join(root, 'staging', 'wiki', 'learnings', 'foo-needs-bar.md'), 'utf-8');
    for (const k of ['title:', 'description:', 'type: learnings', 'created: 2026-07-30', 'updated: 2026-07-30', 'tags: []', 'related: []']) {
      expect(page).toContain(k);
    }
    expect(page).toContain('provenance: untrusted-derived');
    expect(page).toContain('origin: dream-summarizer');
    expect(page).toContain('captured from a_b_2026-07-30.txt, dream drm_20260730T120000Z, confidence high');
  });

  it('UPDATE folds a strong same-category hit into the existing page, bumps updated:', async () => {
    const target = join(root, 'staging', 'wiki', 'entities', 'widget.md');
    await fs.writeFile(target, '---\ntitle: widget\ndescription: d\ntype: entities\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: []\n---\n\n# widget\n\nbody\n');
    const facts: CandidateFact[] = [{ kind: 'entity', claim: 'widget gained a new mode', source: 's.txt' }];
    const r = await applyCandidates(join(root, 'staging'), facts, OPTS());
    expect(r.updated).toEqual(['entities/widget.md']);
    const page = await fs.readFile(target, 'utf-8');
    expect(page).toContain('## Candidate facts (untrusted)');
    expect(page).toContain('widget gained a new mode');
    expect(page).toContain('updated: 2026-07-30');
  });

  it('is idempotent: a second run over the same facts is a no-op (both ADD and UPDATE)', async () => {
    const target = join(root, 'staging', 'wiki', 'entities', 'widget.md');
    await fs.writeFile(target, '---\ntitle: widget\ndescription: d\ntype: entities\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: []\n---\n\n# widget\n\nbody\n');
    const facts: CandidateFact[] = [
      { kind: 'entity', claim: 'widget gained a new mode' },
      { kind: 'decision', claim: 'we chose X over Y' },
    ];
    const staging = join(root, 'staging');
    await applyCandidates(staging, facts, OPTS());
    const snap1 = await fs.readFile(target, 'utf-8');
    const r2 = await applyCandidates(staging, facts, OPTS());
    expect(r2.added).toEqual([]);
    expect(r2.updated).toEqual([]);
    expect(r2.skipped.every((s) => s.reason.includes('idempotent'))).toBe(true);
    expect(await fs.readFile(target, 'utf-8')).toBe(snap1);
  });

  it('appends fact bullets INSIDE the untrusted section, never after a generated block', async () => {
    const target = join(root, 'staging', 'wiki', 'entities', 'widget.md');
    await fs.writeFile(target,
      '---\ntitle: widget\ndescription: d\ntype: entities\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: []\n---\n\n# widget\n\nbody\n\n' +
      '## Candidate facts (untrusted)\n\n- (fact:old000) an earlier claim\n\n' +
      '<!-- graph:begin (generated) -->\n**Related:** [[x]]\n<!-- graph:end -->\n');
    await applyCandidates(join(root, 'staging'), [{ kind: 'entity', claim: 'widget got a newer claim' }], OPTS());
    const page = await fs.readFile(target, 'utf-8');
    const bulletAt = page.indexOf('widget got a newer claim');
    const graphAt = page.indexOf('<!-- graph:begin');
    expect(bulletAt).toBeGreaterThan(page.indexOf('## Candidate facts (untrusted)'));
    expect(bulletAt).toBeLessThan(graphAt);       // inside the section, not after the generated block
    expect(page).toContain('an earlier claim');   // pre-existing bullet preserved
    expect(page).toContain('<!-- graph:end -->'); // generated region intact
  });

  it('preference is DROPPED (still no consumer); relation is handled by the edge lane, not dropped', async () => {
    const r = await applyCandidates(join(root, 'staging'), [
      { kind: 'preference', claim: 'user prefers terse replies' },
      { kind: 'relation', claim: 'A relates to B', from_hint: 'nothing here', to_hint: 'nor here', rel: 'relates' },
    ], OPTS());
    expect(r.added).toEqual([]);
    expect(r.skipped.find((x) => x.kind === 'preference')?.reason).toMatch(/DROPPED/);
    // The relation reached the edge lane and failed on RESOLUTION, not on being unsupported.
    expect(r.skipped.find((x) => x.kind === 'relation')?.reason).toMatch(/endpoint unresolved/);
    expect(r.edges).toBeUndefined();
  });

  // THE regression test for the vacuous-threshold bug. The old BM25 seam returned
  // score_norm 1.0 for its top hit ALWAYS, so a fact sharing one incidental token was folded
  // onto an unrelated live page — and fold-ins bypass the hold gate. An unrelated fact must ADD.
  it('an unrelated fact ADDs a new page instead of grafting onto a lexically-similar one', async () => {
    const staging = join(root, 'staging');
    await fs.mkdir(join(staging, 'wiki', 'decisions'), { recursive: true });
    await fs.writeFile(join(staging, 'wiki', 'decisions', 'database-backup-retention.md'),
      '---\ntitle: database backup retention\ndescription: d\ntype: decisions\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: []\n---\n\n# database backup retention\n\nWe keep nightly database backups for 30 days.\n');
    const r = await applyCandidates(staging, [{
      kind: 'decision',
      claim: 'The team decided to adopt Vite for the frontend build; the database was not involved.',
    }], OPTS());
    expect(r.updated).toEqual([]);                       // must NOT graft onto the backup page
    expect(r.added).toHaveLength(1);
    const victim = await fs.readFile(join(staging, 'wiki', 'decisions', 'database-backup-retention.md'), 'utf-8');
    expect(victim).not.toContain('Vite');
    expect(victim).not.toContain('## Candidate facts (untrusted)');
  });

  it('relation facts resolve to edges only when BOTH endpoints are unambiguous', async () => {
    const staging = join(root, 'staging');
    await fs.mkdir(join(staging, 'wiki', 'decisions'), { recursive: true });
    await fs.writeFile(join(staging, 'wiki', 'entities', 'widget.md'),
      '---\ntitle: widget\ntype: entities\nrelated: []\n---\n\n# widget\n');
    await fs.writeFile(join(staging, 'wiki', 'decisions', 'adopt-vite.md'),
      '---\ntitle: adopt vite\ntype: decisions\nrelated: []\n---\n\n# adopt vite\n');
    const r = await applyCandidates(staging, [
      { kind: 'relation', claim: 'widget relates to the vite decision', from_hint: 'widget', to_hint: 'adopt vite', rel: 'relates' },
      { kind: 'relation', claim: 'dangling', from_hint: 'widget', to_hint: 'no such page here', rel: 'relates' },
      { kind: 'relation', claim: 'self', from_hint: 'widget', to_hint: 'widget', rel: 'relates' },
    ], OPTS());
    expect(r.edges).toEqual([{ from: 'widget', to: 'adopt-vite', type: 'relates', confidence: 'medium' }]);
    const reasons = r.skipped.map((x) => x.reason).join(' ');
    expect(reasons).toMatch(/unresolved/);
    expect(reasons).toMatch(/self-loop/);
    // Stage B must NEVER write the live graph itself.
    expect(r.added.concat(r.updated).some((p) => p.includes('graph'))).toBe(false);
  });

  // Found by a peer reviewer's probe: resolution scanned only the four categories the writer
  // CREATES pages in, so an endpoint in concepts/, security/, state/ or sources/ silently
  // resolved to nothing — indistinguishable from the model proposing a bad edge.
  it('resolves endpoints in categories the writer never creates pages in (concepts/, security/)', async () => {
    const staging = join(root, 'staging');
    await fs.mkdir(join(staging, 'wiki', 'concepts'), { recursive: true });
    await fs.mkdir(join(staging, 'wiki', 'security'), { recursive: true });
    const page = (t: string, ty: string) => `---\ntitle: ${t}\ntype: ${ty}\nrelated: []\n---\n\n# ${t}\n`;
    await fs.writeFile(join(staging, 'wiki', 'entities', 'widget.md'), page('widget', 'entities'));
    await fs.writeFile(join(staging, 'wiki', 'concepts', 'lethal-trifecta.md'), page('lethal trifecta', 'concepts'));
    await fs.writeFile(join(staging, 'wiki', 'security', 'threat-model.md'), page('threat model', 'security'));
    const r = await applyCandidates(staging, [
      { kind: 'relation', claim: 'a', from_hint: 'widget', to_hint: 'lethal-trifecta', rel: 'relates' },
      { kind: 'relation', claim: 'b', from_hint: 'widget', to_hint: 'threat model', rel: 'relates' },
    ], OPTS());
    expect(r.edges).toEqual([
      { from: 'widget', to: 'lethal-trifecta', type: 'relates', confidence: 'medium' },
      { from: 'widget', to: 'threat-model', type: 'relates', confidence: 'medium' },
    ]);
  });

  it('a relation can name a page created in the SAME run (relations resolve last)', async () => {
    const staging = join(root, 'staging');
    await fs.writeFile(join(staging, 'wiki', 'entities', 'widget.md'),
      '---\ntitle: widget\ntype: entities\nrelated: []\n---\n\n# widget\n');
    const r = await applyCandidates(staging, [
      { kind: 'relation', claim: 'links to the new page', from_hint: 'widget', to_hint: 'brand new finding', rel: 'relates' },
      { kind: 'learning', title: 'brand new finding', claim: 'something learned' },
    ], OPTS());
    expect(r.added).toEqual(['learnings/brand-new-finding.md']);
    expect(r.edges).toEqual([{ from: 'widget', to: 'brand-new-finding', type: 'relates', confidence: 'medium' }]);
  });

  it('fold-in matching is explainable: exact slug, or the page title fully contained in the fact', () => {
    expect(isFoldInMatch('Widget calibration', 'anything', 'widget-calibration', 'Widget calibration')).toBe(true);
    expect(isFoldInMatch('x', 'the widget gained a mode', 'widget', 'widget')).toBe(true);
    expect(isFoldInMatch('Vite adopted', 'the database was not involved', 'database-backup-retention', 'database backup retention')).toBe(false);
    expect(isFoldInMatch('anything', 'shares only the stopword the', 'alpha-policy', 'alpha policy')).toBe(false);
  });

  it('a second fact under the same title folds into that page instead of duplicating it', async () => {
    const staging = join(root, 'staging');
    const f1: CandidateFact = { kind: 'learning', title: 'same title', claim: 'first claim' };
    const f2: CandidateFact = { kind: 'learning', title: 'same title', claim: 'second, different claim' };
    const r1 = await applyCandidates(staging, [f1], OPTS());
    const r2 = await applyCandidates(staging, [f2], OPTS());
    expect(r1.added).toEqual(['learnings/same-title.md']);
    expect(r2.added).toEqual([]);                                  // no duplicate page
    expect(r2.updated).toEqual(['learnings/same-title.md']);
    const page = await fs.readFile(join(staging, 'wiki', 'learnings', 'same-title.md'), 'utf-8');
    expect(page).toContain(`(fact:${factHash(f2)})`);              // the new fact landed on it
    expect(page).toContain('first claim');                         // the original survives
  });
});

describe('netless + hermetic (structural boundary, enforced by source scan)', () => {
  const here = fileURLToPath(new URL('.', import.meta.url));
  const SOURCES = ['consolidate-writer.ts', 'consolidate-writer-cli.ts', 'candidate-facts.ts'];
  const FORBIDDEN = [
    /from\s+['"](node:)?(https?|net|tls|dgram|dns|child_process)['"]/,
    /require\(\s*['"](node:)?(https?|net|tls|dgram|dns|child_process)['"]\s*\)/,
    /\bfetch\s*\(/,
  ];

  it('writer sources import no network/child-process modules', () => {
    for (const f of SOURCES) {
      const src = readFileSync(join(here, f), 'utf-8');
      for (const re of FORBIDDEN) {
        expect(re.test(src), `${f} matches forbidden ${re}`).toBe(false);
      }
    }
  });

  it('CLI pins the hermetic env: embeddings off + scratch BRAIN_DIR inside the dream dir', () => {
    const src = readFileSync(join(here, 'consolidate-writer-cli.ts'), 'utf-8');
    expect(src).toContain("SECOND_BRAIN_DISABLE_EMBEDDINGS = '1'");
    expect(src).toMatch(/SB_BRAIN_DIR = join\(dreamDir/);
  });

  it('built bundle (committed) carries no child_process/net import', () => {
    // No try/catch fallback: dist/** is committed, so an unreadable bundle is a real
    // failure — swallowing it would make this netless assertion pass vacuously.
    const bundle = join(here, '..', '..', 'dist', 'tools', 'consolidate-writer-cli.bundle.js');
    const text = readFileSync(bundle, 'utf-8');
    expect(text.length).toBeGreaterThan(1000);
    for (const mod of ['child_process', 'net', 'tls', 'dns', 'https']) {
      expect(new RegExp(`require\\(\\s*['"](node:)?${mod}['"]\\s*\\)`).test(text), `bundle requires ${mod}`).toBe(false);
      expect(new RegExp(`from\\s*['"](node:)?${mod}['"]`).test(text), `bundle imports ${mod}`).toBe(false);
    }
  });
});
