import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { glob } from 'glob';
import yaml from 'js-yaml';
import { appendEdge } from './graph-store.js';
import { projectGraphToPages } from './graph-project.js';
import { knowledgeValidate } from './knowledge-validate.js';
import { parseDoc } from './knowledge-search.js';

// THE retrospective gate (deep-review §2.1). The entire "not-working logic" bug
// family shipped because every reader is a tolerant regex, so malformed writer
// output never failed a round-trip. This test uses js-yaml (a real parser) as an
// oracle INDEPENDENT of extractYamlList: after the projector and the validator
// autofix run, EVERY page's frontmatter must parse as valid YAML. This would have
// caught the original bracketless `related: [[a]], [[b]]` bug.
//
// As of 0.26.0 the runtime validator ITSELF uses yaml.load() (js-yaml is a real
// dependency, bundled into the server) to detect malformed frontmatter — so the
// detector can no longer diverge from real YAML validity. The detector-alignment
// test below is the contract that keeps it honest.

function frontmatterOf(md: string): string | null {
  const m = md.match(/^---\n([\s\S]*?)\n---/);
  return m ? m[1] : null;
}

async function assertAllPagesParse(dir: string) {
  const files = await glob('**/*.md', { cwd: join(dir, 'wiki'), absolute: true });
  for (const f of files) {
    const md = await fsp.readFile(f, 'utf-8');
    const fm = frontmatterOf(md);
    if (fm === null) continue;            // a page may legitimately have no frontmatter
    expect(() => yaml.load(fm), `frontmatter of ${f} must be valid YAML:\n${fm}`).not.toThrow();
  }
}

describe('frontmatter parse-validity (real YAML oracle, independent of the regex reader)', () => {
  it('projector + validator-autofix output ALWAYS parses as valid YAML, across adversarial input shapes', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'fpv-'));
    const ent = join(dir, 'wiki', 'entities');
    await fsp.mkdir(ent, { recursive: true });
    const write = (s: string, fm: string, body = `\n# ${s}\n\nbody\n`) =>
      fsp.writeFile(join(ent, `${s}.md`), `---\n${fm}\n---\n${body}`);

    // every shape that has historically produced invalid YAML or near-misses:
    await write('inline-beta', 'title: a\ntype: entities\nrelated: [router-daemon, vps]');
    await write('bracketless', 'title: b\ntype: entities\nrelated: [[router-daemon]], [[vps]]'); // legacy invalid
    await write('block-list', 'title: c\ntype: entities\nrelated:\n  - router-daemon\n  - vps');
    await write('orphan-children', 'title: d\ntype: entities\nrelated: [[router-daemon]]\n  - vps'); // invalid
    await write('empty', 'title: e\ntype: entities\nrelated: []');
    await write('incomplete', 'title: f\ntype: entities');   // missing required fields
    await write('emptydesc', 'title: g\ndescription: ""\ntype: entities\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: []');
    await write('router-daemon', 'title: rd\ntype: entities\nrelated: []');
    await write('vps', 'title: vps\ntype: entities\nrelated: []');

    // pre-fix sanity: at least one fixture is INVALID YAML before any processing,
    // proving the oracle actually discriminates (not a vacuous pass).
    const bad = frontmatterOf(await fsp.readFile(join(ent, 'bracketless.md'), 'utf-8'))!;
    expect(() => yaml.load(bad)).toThrow();

    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'inline-beta', to: 'router-daemon', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });

    await projectGraphToPages(dir);
    await knowledgeValidate(dir, { autofix: true });

    await assertAllPagesParse(dir);   // EVERY page now valid YAML — the oracle
  });

  it('the malformed-frontmatter detector flags EXACTLY the pages a real YAML parser rejects (no more, no less)', async () => {
    // Oracle = js-yaml. The detector (knowledge-validate's isMalformedFrontmatter)
    // must agree with it on every shape — the 0.26.0 fix that replaced two
    // hard-coded regex shapes (which missed live dup-key + unquoted-colon pages)
    // with yaml.load(). Run WITHOUT autofix so we observe raw detection.
    const dir = await fsp.mkdtemp(join(tmpdir(), 'fpv-det-'));
    const ent = join(dir, 'wiki', 'entities');
    await fsp.mkdir(ent, { recursive: true });
    const write = (s: string, fm: string) =>
      fsp.writeFile(join(ent, `${s}.md`), `---\n${fm}\n---\n\n# ${s}\n\nbody\n`);

    const fixtures: Record<string, string> = {
      'ok-inline': 'title: a\ntype: entities\nrelated: [x, y]',
      'ok-block': 'title: b\ntype: entities\nrelated:\n  - x\n  - y',
      'ok-empty': 'title: c\ntype: entities\nrelated: []',
      'ok-nested-single': 'title: d\ntype: entities\nrelated: [[x]]',     // valid nested array
      'bad-bracketless': 'title: e\ntype: entities\nrelated: [[x]], [[y]]', // legacy invalid
      'bad-dupkey': 'title: f\ntype: entities\nupdated: 2026-05-15\ntags: [t]\nupdated: 2026-06-08', // live bug class
      'bad-colon': 'title: g\ntype: entities\ndescription: Map of Content (generated from project: facets).', // live bug class
      'x': 'title: x\ntype: entities\nrelated: []',
      'y': 'title: y\ntype: entities\nrelated: []',
    };
    for (const [s, fm] of Object.entries(fixtures)) await write(s, fm);

    // independent expected set: which fixtures does a REAL parser reject?
    const expectedBad = new Set(
      Object.entries(fixtures).filter(([, fm]) => { try { yaml.load(fm); return false; } catch { return true; } })
        .map(([s]) => s)
    );
    // sanity: the oracle actually discriminates (the 3 invalid classes are present)
    expect(expectedBad).toEqual(new Set(['bad-bracketless', 'bad-dupkey', 'bad-colon']));

    const res = await knowledgeValidate(dir, { autofix: false });
    const flagged = new Set(
      res.issues.filter(i => i.type === 'malformed_frontmatter')
        .map(i => i.path.replace(/.*[/\\]/, '').replace(/\.md$/, ''))
    );
    expect(flagged).toEqual(expectedBad);   // detector === real YAML validity
  });

  it('autofix repairs a duplicate-key page AND keeps the LAST (freshest) value', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'fpv-dup-'));
    const ent = join(dir, 'wiki', 'entities');
    await fsp.mkdir(ent, { recursive: true });
    const p = join(ent, 'dup.md');
    await fsp.writeFile(p, '---\ntitle: d\ntype: entities\nupdated: 2026-05-15\ntags: [t]\nrelated: []\nupdated: 2026-06-08\n---\n\n# d\n\nbody\n');

    // pre: invalid YAML, and the stale-first-value trap the regex reader fell into
    const beforeFm = frontmatterOf(await fsp.readFile(p, 'utf-8'))!;
    expect(() => yaml.load(beforeFm)).toThrow();

    await knowledgeValidate(dir, { autofix: true });

    const fm = frontmatterOf(await fsp.readFile(p, 'utf-8'))!;
    // (YAML coerces an unquoted date to a Date object, so assert on the raw text:
    //  the freshest value is kept and the stale duplicate is gone.)
    expect(() => yaml.load(fm)).not.toThrow();                 // valid YAML now
    expect(fm).toMatch(/^updated: 2026-06-08$/m);              // freshest value won
    expect(fm).not.toContain('2026-05-15');                    // stale duplicate dropped
    expect(fm).toMatch(/^title: d$/m);                         // unrelated fields preserved
  });

  it('CRLF frontmatter is READ by parseDoc and NOT double-blocked by the validator (Windows/autocrlf)', async () => {
    // A page hand-edited on Windows / checked out with autocrlf has `---\r\n`
    // fences. Pre-0.28.3 the LF-only `^---\n` missed it: parseDoc lost the
    // frontmatter (title/type/related), and the validator saw "no frontmatter"
    // → prepended a SECOND block (corruption on every reindex).
    const dir = await fsp.mkdtemp(join(tmpdir(), 'crlf-'));
    const ent = join(dir, 'wiki', 'entities');
    await fsp.mkdir(ent, { recursive: true });
    const p = join(ent, 'crlf.md');
    await fsp.writeFile(p, '---\r\ntitle: c\r\ntype: entities\r\nrelated: [x]\r\n---\r\n\r\n# c\r\n\r\nbody\r\n');

    // (1) parseDoc reads the CRLF frontmatter
    const doc = parseDoc(await fsp.readFile(p, 'utf8'), p);
    expect(doc.title).toBe('c');
    expect(doc.type).toBe('entities');
    expect(doc.related).toEqual(['x']);

    // (2) the validator does NOT flag it missing, and autofix does NOT double the block
    const res = await knowledgeValidate(dir, { autofix: true });
    expect(res.issues.filter(i => i.type === 'missing_frontmatter' && i.path.includes('crlf')).length).toBe(0);
    const after = await fsp.readFile(p, 'utf8');
    expect((after.match(/^---\r?$/gm) || []).length).toBe(2);   // exactly one block's two fences, not four
  });

  it('a second reindex cycle keeps every page valid YAML (idempotent validity)', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'fpv2-'));
    const ent = join(dir, 'wiki', 'entities');
    await fsp.mkdir(ent, { recursive: true });
    await fsp.writeFile(join(ent, 'lonely.md'), '---\ntitle: l\ntype: entities\nrelated:\n  - dead\n---\n\n# l\n\nbody\n');
    await fsp.writeFile(join(ent, 'a.md'), '---\ntitle: a\ntype: entities\nrelated: []\n---\n\n# a\n\n[[b]]\n');
    await fsp.writeFile(join(ent, 'b.md'), '---\ntitle: b\ntype: entities\nrelated: []\n---\n\n# b\n\nbody\n');
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    for (let i = 0; i < 2; i++) { await projectGraphToPages(dir); await knowledgeValidate(dir, { autofix: true }); }
    await assertAllPagesParse(dir);
  });
});
