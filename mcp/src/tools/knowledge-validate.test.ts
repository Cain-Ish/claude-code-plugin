import { describe, it, expect, vi } from 'vitest';
import { parseFrontmatter, frontmatterParses } from './test-oracle.js';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { addFrontmatter, knowledgeValidate } from './knowledge-validate.js';

describe('addFrontmatter category typing', () => {
  it('types a frontmatter-less page under wiki/themes/ as type: themes', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-themes-'));
    const wiki = join(dir, 'wiki');
    const f = join(wiki, 'themes', 'architecture.md');
    await fs.mkdir(join(wiki, 'themes'), { recursive: true });
    await fs.writeFile(f, '# Architecture\n\nbody\n');

    await addFrontmatter(f, wiki);

    const out = await fs.readFile(f, 'utf-8');
    expect(out).toMatch(/^type: themes$/m);   // not the 'state' fallback
  });

  it('still falls back to state for an unknown category', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-unk-'));
    const wiki = join(dir, 'wiki');
    const f = join(wiki, 'whatever', 'x.md');
    await fs.mkdir(join(wiki, 'whatever'), { recursive: true });
    await fs.writeFile(f, '# X\n\nbody\n');

    await addFrontmatter(f, wiki);

    expect(await fs.readFile(f, 'utf-8')).toMatch(/^type: state$/m);
  });

  it('warns (not errors) when an ai-block is missing a required field for its type', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-ai-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    await fs.writeFile(join(wiki, 'learnings', 'l.md'),
      '---\ntitle: L\ntype: learnings\n---\n<!-- ai:begin -->\nclaim: c\n<!-- ai:end -->\n# L\n');
    const res = await knowledgeValidate(dir, { autofix: false });
    const w = res.issues.find(i => i.type === 'ai_block_incomplete' && /action/.test(i.message));
    expect(w).toBeDefined();
    expect(w!.severity).toBe('warning');
  });
  it('does not warn when the page has no ai-block (additive/optional during migration)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-noai-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    await fs.writeFile(join(wiki, 'learnings', 'l.md'), '---\ntitle: L\ntype: learnings\n---\n# L\nprose\n');
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'ai_block_incomplete')).toBeUndefined();
  });

  it('does NOT flag a generated project MOC sharing a slug with a real page as duplicate_slug (#3)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-collide-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'decisions'), { recursive: true });
    await fs.mkdir(join(wiki, 'projects'), { recursive: true });
    // a real content page AND a project MOC, both basename "architecture-v1"
    await fs.writeFile(join(wiki, 'decisions', 'architecture-v1.md'), '---\ntitle: Arch\ntype: decisions\n---\n# Arch\n');
    await fs.writeFile(join(wiki, 'projects', 'architecture-v1.md'),
      '---\ntitle: architecture-v1\ntype: projects\ngenerated: true\ngraph: exclude\n---\n# moc\n');
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'duplicate_slug' && /architecture-v1/.test(i.message))).toBeUndefined();
  });

  it('flags a structured, substantive page with NO ai-block as ai_block_missing', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-miss-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    await fs.writeFile(join(wiki, 'learnings', 'big.md'),
      '---\ntitle: Big\ntype: learnings\n---\n# Big\n' + 'substantive prose detail. '.repeat(20));
    const res = await knowledgeValidate(dir, { autofix: false });
    const w = res.issues.find(i => i.type === 'ai_block_missing' && /big/.test(i.message));
    expect(w).toBeDefined();
    expect(w!.severity).toBe('warning');
  });
  it('does NOT flag a short structured stub as ai_block_missing', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-stub-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    await fs.writeFile(join(wiki, 'learnings', 's.md'), '---\ntitle: S\ntype: learnings\n---\n# S\ntiny.');
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'ai_block_missing')).toBeUndefined();
  });
  it('does NOT flag a non-structured type (state) or a generated MOC as ai_block_missing', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-nonstruct-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'state'), { recursive: true });
    await fs.mkdir(join(wiki, 'projects'), { recursive: true });
    await fs.writeFile(join(wiki, 'state', 'st.md'), '---\ntitle: St\ntype: state\n---\n# St\n' + 'long state prose. '.repeat(20));
    await fs.writeFile(join(wiki, 'projects', 'p.md'), '---\ntitle: P\ntype: projects\ngenerated: true\n---\n# P\n' + 'long moc prose. '.repeat(20));
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'ai_block_missing')).toBeUndefined();
  });
  it('does not crash or flag a page typed with an inherited Object key (constructor/__proto__)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-proto-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    // a structured-dir page whose type: is a prototype key, substantive prose, no block
    await fs.writeFile(join(wiki, 'learnings', 'a.md'),
      '---\ntitle: A\ntype: constructor\n---\n# A\n' + 'long prose detail. '.repeat(20));
    // and one WITH a block — exercises validateAiBlock's lookup (the TypeError crash path)
    await fs.writeFile(join(wiki, 'learnings', 'b.md'),
      '---\ntitle: B\ntype: __proto__\n---\n<!-- ai:begin -->\nclaim: c\n<!-- ai:end -->\n# B\nprose');
    const res = await knowledgeValidate(dir, { autofix: false }); // must not throw
    expect(res.issues.find(i => i.type === 'ai_block_missing')).toBeUndefined();
    expect(res.issues.find(i => i.type === 'ai_block_incomplete')).toBeUndefined();
  });
  it('strips CRLF frontmatter before measuring prose (no false-positive ai_block_missing)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-crlf-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    // CRLF page: frontmatter ALONE > 200 chars, body tiny — only flagged if FM isn't stripped
    const page = ['---', 'title: C', 'type: learnings', `description: ${'x'.repeat(260)}`, '---', '# C', 'tiny.'].join('\r\n');
    await fs.writeFile(join(wiki, 'learnings', 'c.md'), page);
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'ai_block_missing')).toBeUndefined();
  });
  it('does NOT double-flag: a page WITH a block is never ai_block_missing', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-has-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    await fs.writeFile(join(wiki, 'learnings', 'h.md'),
      '---\ntitle: H\ntype: learnings\n---\n<!-- ai:begin -->\nclaim: c\naction: a\n<!-- ai:end -->\n# H\n' + 'prose. '.repeat(20));
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'ai_block_missing')).toBeUndefined();
  });

  it('does NOT flag a valid [[target|alias]] related link as broken (alias split)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-alias-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'security'), { recursive: true });
    await fs.mkdir(join(wiki, 'decisions'), { recursive: true });
    await fs.writeFile(join(wiki, 'security', 'real-target.md'), '---\ntitle: T\ntype: security\n---\n# T\n');
    await fs.writeFile(join(wiki, 'decisions', 'src.md'),
      '---\ntitle: S\ntype: decisions\nrelated: [[real-target|nice display]]\n---\n# S\n');
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'broken_link' && /real-target/.test(i.message))).toBeUndefined();
  });
});

describe('malformed-frontmatter normalization (graph-pipeline fix)', () => {
  const mkwiki = async (slug: string, fm: string) => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-mf-'));
    const wiki = join(dir, 'wiki', 'entities');
    await fs.mkdir(wiki, { recursive: true });
    const f = join(wiki, `${slug}.md`);
    await fs.writeFile(f, `---\n${fm}\n---\n\nbody body body\n`);
    return { dir, f };
  };

  it('flags bracketless multi-item related: [[a]], [[b]] as malformed_frontmatter', async () => {
    const { dir } = await mkwiki('p', 'title: P\ntype: entities\nrelated: [[a]], [[b]]');
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'malformed_frontmatter')).toBeTruthy();
  });

  it('flags orphaned block-list children under an inline related: as malformed', async () => {
    const { dir } = await mkwiki('p', 'title: P\ntype: entities\nrelated: [[a]]\n  - stale-b\n  - stale-c');
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'malformed_frontmatter')).toBeTruthy();
  });

  it('autofix rewrites related: to canonical β, drops orphans, and the heal is idempotent', async () => {
    const { dir, f } = await mkwiki('p', 'title: P\ntype: entities\nrelated: [[a]], [[b]]');
    const res = await knowledgeValidate(dir, { autofix: true });
    expect(res.fixed).toBeGreaterThanOrEqual(1);
    const out = await fs.readFile(f, 'utf-8');
    expect(frontmatterParses(out)).toBe(true);                 // REAL YAML parse (a throw is the failure)
    expect(parseFrontmatter(out).related).toEqual(['a', 'b']); // not re-read through isMalformedFrontmatter
    const res2 = await knowledgeValidate(dir, { autofix: false });
    expect(res2.issues.find(i => i.type === 'malformed_frontmatter')).toBeFalsy();
  });

  it('autofix consumes orphaned block-list children into the inline value', async () => {
    const { dir, f } = await mkwiki('p', 'title: P\ntype: entities\nrelated: [[a]]\n  - stale-b');
    await knowledgeValidate(dir, { autofix: true });
    const out = await fs.readFile(f, 'utf-8');
    expect(parseFrontmatter(out).related).toEqual(['a']);      // parsed: orphan 'stale-b' is GONE from the structure
    expect(JSON.stringify(parseFrontmatter(out).related)).not.toContain('stale');
  });

  it('does NOT flag or rewrite a clean, complete β page', async () => {
    const { dir, f } = await mkwiki('p', 'title: P\ndescription: ""\ntype: entities\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: [x]\nrelated: [a, b]');
    const before = await fs.readFile(f, 'utf-8');
    const res = await knowledgeValidate(dir, { autofix: true });
    expect(res.issues.find(i => i.type === 'malformed_frontmatter')).toBeFalsy();
    expect(res.issues.find(i => i.type === 'incomplete_frontmatter')).toBeFalsy();
    expect(await fs.readFile(f, 'utf-8')).toBe(before);   // untouched (idempotent)
  });

  it('does NOT flag a single valid [[a]] wiki-link (parses as nested array, not invalid)', async () => {
    const { dir } = await mkwiki('p', 'title: P\ntype: entities\nrelated: [[a]]');
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'malformed_frontmatter')).toBeFalsy();
  });
});

describe('incomplete-frontmatter PATCH (node-shape convergence)', () => {
  const mkwiki = async (slug: string, fm: string, body = '\n# Heading\n\nbody body body\n') => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-inc-'));
    const wiki = join(dir, 'wiki', 'entities');
    await fs.mkdir(wiki, { recursive: true });
    const f = join(wiki, `${slug}.md`);
    await fs.writeFile(f, `---\n${fm}\n---\n${body}`);
    return { dir, f };
  };

  it('flags a page with frontmatter missing required fields as incomplete_frontmatter', async () => {
    const { dir } = await mkwiki('p', 'title: P\ntype: entities');   // missing created/updated/tags/related
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'incomplete_frontmatter')).toBeTruthy();
  });

  it('autofix patches ONLY the absent required fields, preserving existing values', async () => {
    const { dir, f } = await mkwiki('p', 'title: "Custom Title"\ntype: entities\ntags: [keepme]');
    await knowledgeValidate(dir, { autofix: true });
    const fmBody = (await fs.readFile(f, 'utf-8')).match(/^---\n([\s\S]*?)\n---/)![1];
    expect(fmBody).toMatch(/^title: "Custom Title"$/m);   // existing value untouched
    expect(fmBody).toMatch(/^tags: \[keepme\]$/m);        // existing list untouched
    expect(fmBody).toMatch(/^created: \d{4}-\d{2}-\d{2}$/m); // added
    expect(fmBody).toMatch(/^updated: \d{4}-\d{2}-\d{2}$/m); // added
    expect(fmBody).toMatch(/^related: \[/m);              // added
    expect(fmBody).toMatch(/^description:/m);             // added
  });

  it('the patch is idempotent — a second run makes no change and no longer flags', async () => {
    const { dir, f } = await mkwiki('p', 'title: P\ntype: entities');
    await knowledgeValidate(dir, { autofix: true });
    const after1 = await fs.readFile(f, 'utf-8');
    const res2 = await knowledgeValidate(dir, { autofix: true });
    const after2 = await fs.readFile(f, 'utf-8');
    expect(after2).toBe(after1);                           // byte-stable
    expect(res2.issues.find(i => i.type === 'incomplete_frontmatter')).toBeFalsy();
  });

  it('never invents "today" for created — derives from a body **Date** line', async () => {
    const { dir, f } = await mkwiki('p', 'title: P\ntype: entities', '\n**Date**: 2025-03-14\n\nbody\n');
    await knowledgeValidate(dir, { autofix: true });
    const fmBody = (await fs.readFile(f, 'utf-8')).match(/^---\n([\s\S]*?)\n---/)![1];
    expect(fmBody).toMatch(/^created: 2025-03-14$/m);
  });

  it('does NOT flag a complete page', async () => {
    const { dir } = await mkwiki('p', 'title: P\ndescription: ""\ntype: entities\ncreated: 2026-01-01\nupdated: 2026-01-02\ntags: []\nrelated: []');
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'incomplete_frontmatter')).toBeFalsy();
  });
});

describe('related_drift detection (WARN-only relation visibility)', () => {
  const setup = async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-drift-'));
    const wiki = join(dir, 'wiki', 'entities');
    await fs.mkdir(wiki, { recursive: true });
    const page = (slug: string, related: string) =>
      fs.writeFile(join(wiki, `${slug}.md`),
        `---\ntitle: ${slug}\ndescription: ""\ntype: entities\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: [${related}]\n---\n\n# ${slug}\n\nbody\n`);
    return { dir, page };
  };

  it('flags a page whose related: disagrees with the current edge graph (WARN, no autofix)', async () => {
    const { dir, page } = await setup();
    await page('a', '');           // frontmatter says no relations…
    await page('b', '');
    const { appendEdge } = await import('./graph-store.js');
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const res = await knowledgeValidate(dir, { autofix: true });
    const drift = res.issues.find(i => i.type === 'related_drift');
    expect(drift).toBeTruthy();
    expect(drift!.severity).toBe('warning');
    expect(drift!.autofix).toBeUndefined();   // detection only — the projector owns related:
  });

  it('does NOT flag when related: matches the graph', async () => {
    const { dir, page } = await setup();
    await page('a', 'b');
    await page('b', 'a');
    const { appendEdge } = await import('./graph-store.js');
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'related_drift')).toBeFalsy();
  });

  it('no edges.jsonl → no drift check (graph not enabled)', async () => {
    const { dir, page } = await setup();
    await page('a', 'ghost');
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'related_drift')).toBeFalsy();
  });
});

// 0.29.2: 0.28.3 made parseDoc + the missing_frontmatter check CRLF-tolerant but
// left ~15 other LF-only `^---\n` frontmatter regexes — including the
// incomplete-frontmatter DETECTION (isIncompleteFrontmatter) and PATCH
// (patchFrontmatter). On a CRLF page those returned no match, so a Windows /
// autocrlf / imported page that lacked required fields was silently never flagged
// AND never patched — un-healable by the automation. ORACLE: js-yaml (test-oracle),
// not a re-implementation of the validator.
describe('CRLF frontmatter tolerance (0.29.2)', () => {
  const CRLF = (lines: string[]) => lines.join('\r\n');

  it('detects + patches an incomplete CRLF page, and the result is js-yaml-valid + idempotent', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-crlf-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    const f = join(wiki, 'learnings', 'crlf-page.md');
    // CRLF everywhere; missing the required `tags` + `related` fields.
    await fs.writeFile(f, CRLF([
      '---', 'title: CRLF Page', 'description: d', 'type: learnings',
      'created: 2026-01-01', 'updated: 2026-01-01', '---', '', '# CRLF Page', '', 'body', '',
    ]));

    // DETECT (read-only): pre-fix the LF-only regex returned no match → page silently
    // un-flagged. Post-fix it is correctly flagged incomplete.
    const ro = await knowledgeValidate(dir, { autofix: false });
    expect(ro.issues.some(i => i.type === 'incomplete_frontmatter' && /crlf-page/.test(i.path))).toBe(true);

    // PATCH.
    const fixedRes = await knowledgeValidate(dir, { autofix: true });
    expect(fixedRes.fixed).toBeGreaterThan(0);
    const out = await fs.readFile(f, 'utf-8');

    // INDEPENDENT ORACLE: the patched frontmatter parses under a real YAML parser,
    // and the two previously-missing required fields are now present.
    expect(frontmatterParses(out)).toBe(true);
    const fm = parseFrontmatter(out);
    expect(Object.keys(fm)).toEqual(expect.arrayContaining(['tags', 'related']));

    // IDEMPOTENT: a second pass has nothing left to patch (no oscillation).
    const again = await knowledgeValidate(dir, { autofix: true });
    expect(again.fixed).toBe(0);
  });
});

// D054: a UTF-8 BOM (U+FEFF) shifts the `---` fence to offset 1. The anchored missing_frontmatter
// check (and addFrontmatter's own defensive re-check) silently saw "no frontmatter" and PREPENDED
// A SECOND BLOCK on top of the original — losing project:/tags: and re-dating created/updated to
// today (PowerShell 5.1's `>`/Out-File default to UTF-8-with-BOM, so this is reachable on Windows
// from a routine `Out-File` save). A well-formed BOM page must not be flagged at all, and autofix
// on it must be a complete no-op.
describe('UTF-8 BOM frontmatter tolerance (D054)', () => {
  it('does not flag a well-formed BOM page as missing_frontmatter, and autofix is a no-op', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-bom-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    const f = join(wiki, 'learnings', 'bom-page.md');
    const bom = '﻿';
    const original = bom + [
      '---',
      'title: "BOM page"',
      'description: "x"',
      'type: learnings',
      'project: kiri',
      'created: 2026-01-01',
      'updated: 2026-01-01',
      'tags: []',
      'related: []',
      '---',
      '',
      '# BOM page',
      '',
      'body',
      '',
    ].join('\n');
    await fs.writeFile(f, original);

    const ro = await knowledgeValidate(dir, { autofix: false });
    expect(ro.issues.some(i => i.type === 'missing_frontmatter' && /bom-page/.test(i.path))).toBe(false);

    const fixedRes = await knowledgeValidate(dir, { autofix: true });
    expect(fixedRes.fixed).toBe(0);
    const out = await fs.readFile(f, 'utf-8');
    expect(out).toBe(original);   // byte-for-byte no-op — no second block, no re-dating
  });
});

// D066: empty_page issues are recorded during the initial full-tree scan; autofix unlinks them
// only after the WHOLE scan finishes, without re-checking. Pages are created non-atomically
// elsewhere (truncate-then-write, an editor's 0-byte-then-content autosave), and a concurrent
// session mutating the shared tree is a documented reality here — a page empty at scan time can
// be fully written by the time the unlink runs.
describe('empty-page autofix race guard (D066)', () => {
  it('does not delete a just-created empty page (too young — possibly mid-write)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-empty-young-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    const fresh = join(wiki, 'learnings', 'fresh-empty.md');
    await fs.writeFile(fresh, '');   // mtime = now

    const res = await knowledgeValidate(dir, { autofix: true });
    expect(res.issues.some(i => i.type === 'empty_page' && /fresh-empty/.test(i.path))).toBe(true);
    await expect(fs.stat(fresh)).resolves.toBeDefined();   // NOT deleted
  });

  it('deletes an empty page old enough to trust', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-empty-old-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    const old = join(wiki, 'learnings', 'old-empty.md');
    await fs.writeFile(old, '');
    const past = new Date(Date.now() - 10_000);
    await fs.utimes(old, past, past);

    await knowledgeValidate(dir, { autofix: true });
    await expect(fs.stat(old)).rejects.toThrow();
  });

  it('re-checks content right before unlinking: a page populated after the scan is spared', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-empty-race-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    const f = join(wiki, 'learnings', 'raced.md');
    await fs.writeFile(f, '');
    const past = new Date(Date.now() - 10_000);
    await fs.utimes(f, past, past);   // old enough to pass the age guard

    // Simulate another writer populating the file between the scan pass (1st readFile of `f`,
    // must still see it empty so the issue is recorded) and the autofix re-check (2nd readFile,
    // added by the fix — must see the new content and skip the delete).
    const realReadFile = fs.readFile.bind(fs);
    let calls = 0;
    const spy = vi.spyOn(fs, 'readFile').mockImplementation(async (path: any, ...rest: any[]) => {
      if (path === f) {
        calls++;
        if (calls >= 2) await fs.writeFile(f, '# Now populated\n\nreal content\n');
        return realReadFile(f, 'utf-8') as any;
      }
      return realReadFile(path, ...(rest as [any]));
    });

    try {
      await knowledgeValidate(dir, { autofix: true });
    } finally {
      spy.mockRestore();
    }
    const out = await fs.readFile(f, 'utf-8');
    expect(out).toContain('real content');   // re-check saw it was no longer empty — not deleted
  });
});
