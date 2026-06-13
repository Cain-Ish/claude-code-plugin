import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { glob } from 'glob';
import yaml from 'js-yaml';
import { appendEdge } from './graph-store.js';
import { projectGraphToPages } from './graph-project.js';
import { knowledgeValidate } from './knowledge-validate.js';

// THE retrospective gate (deep-review §2.1). The entire "not-working logic" bug
// family shipped because no YAML PARSER exists in the codebase — every reader is
// a tolerant regex, so malformed writer output never failed a round-trip. This
// test uses js-yaml (a real parser, dev-only — never bundled into the shipped
// server) as an oracle INDEPENDENT of extractYamlList: after the projector and
// the validator autofix run, EVERY page's frontmatter must parse as valid YAML.
// This would have caught the original bracketless `related: [[a]], [[b]]` bug.

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
