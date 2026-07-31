import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { promises as fs } from 'fs';
import { readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';
import { applyCandidates, factHash, SearchFn } from './consolidate-writer.js';
import { CandidateFact } from './candidate-facts.js';

let root: string;
const noHits: SearchFn = async () => [];

async function mkStaging(): Promise<string> {
  const d = await fs.mkdtemp(join(tmpdir(), 'cw-test-'));
  await fs.mkdir(join(d, 'staging', 'wiki', 'entities'), { recursive: true });
  return d;
}

const OPTS = (searchFn: SearchFn = noHits) => ({
  dreamId: 'drm_20260730T120000Z', date: '2026-07-30', searchFn,
});

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
    const search: SearchFn = async () => [{ path: target, score_norm: 0.9 }];
    const facts: CandidateFact[] = [{ kind: 'entity', claim: 'widget gained a new mode', source: 's.txt' }];
    const r = await applyCandidates(join(root, 'staging'), facts, OPTS(search));
    expect(r.updated).toEqual(['entities/widget.md']);
    const page = await fs.readFile(target, 'utf-8');
    expect(page).toContain('## Candidate facts (untrusted)');
    expect(page).toContain('widget gained a new mode');
    expect(page).toContain('updated: 2026-07-30');
  });

  it('is idempotent: a second run over the same facts is a no-op (both ADD and UPDATE)', async () => {
    const target = join(root, 'staging', 'wiki', 'entities', 'widget.md');
    await fs.writeFile(target, '---\ntitle: widget\ndescription: d\ntype: entities\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: []\n---\n\n# widget\n\nbody\n');
    const search: SearchFn = async (q, scope) => (scope === 'entities' ? [{ path: target, score_norm: 0.9 }] : []);
    const facts: CandidateFact[] = [
      { kind: 'entity', claim: 'widget gained a new mode' },
      { kind: 'decision', claim: 'we chose X over Y' },
    ];
    const staging = join(root, 'staging');
    await applyCandidates(staging, facts, OPTS(search));
    const snap1 = await fs.readFile(target, 'utf-8');
    const r2 = await applyCandidates(staging, facts, OPTS(search));
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
    const search: SearchFn = async () => [{ path: target, score_norm: 0.9 }];
    await applyCandidates(join(root, 'staging'), [{ kind: 'entity', claim: 'a newer claim' }], OPTS(search));
    const page = await fs.readFile(target, 'utf-8');
    const bulletAt = page.indexOf('a newer claim');
    const graphAt = page.indexOf('<!-- graph:begin');
    expect(bulletAt).toBeGreaterThan(page.indexOf('## Candidate facts (untrusted)'));
    expect(bulletAt).toBeLessThan(graphAt);       // inside the section, not after the generated block
    expect(page).toContain('an earlier claim');   // pre-existing bullet preserved
    expect(page).toContain('<!-- graph:end -->'); // generated region intact
  });

  it('skips preference/relation kinds, naming them DROPPED (no consumer exists yet)', async () => {
    const r = await applyCandidates(join(root, 'staging'), [
      { kind: 'preference', claim: 'user prefers terse replies' },
      { kind: 'relation', claim: 'A requires B' },
    ], OPTS());
    expect(r.added).toEqual([]);
    expect(r.skipped).toHaveLength(2);
    expect(r.skipped[0].reason).toMatch(/DROPPED/);
    expect(r.skipped[1].reason).toMatch(/live maintainer/);
  });

  it('rejects a search hit that escapes the staging wiki (containment)', async () => {
    const outside = join(root, 'outside.md');
    await fs.writeFile(outside, 'x');
    const search: SearchFn = async () => [{ path: outside, score_norm: 0.99 }];
    const r = await applyCandidates(join(root, 'staging'), [{ kind: 'entity', claim: 'evil' }], OPTS(search));
    expect(r.updated).toEqual([]);
    expect(r.added).toEqual([]);
    expect(r.skipped[0].reason).toMatch(/escapes staging wiki/);
    expect(await fs.readFile(outside, 'utf-8')).toBe('x');
  });

  it('same-slug different-fact ADD disambiguates by hash instead of clobbering', async () => {
    const staging = join(root, 'staging');
    const f1: CandidateFact = { kind: 'learning', title: 'same title', claim: 'first claim' };
    const f2: CandidateFact = { kind: 'learning', title: 'same title', claim: 'second, different claim' };
    const r1 = await applyCandidates(staging, [f1], OPTS());
    const r2 = await applyCandidates(staging, [f2], OPTS());
    expect(r1.added).toEqual(['learnings/same-title.md']);
    expect(r2.added).toEqual([`learnings/same-title-${factHash(f2)}.md`]);
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
