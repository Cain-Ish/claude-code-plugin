import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { promises as fs, mkdtempSync, rmSync, writeFileSync, mkdirSync, renameSync, unlinkSync, existsSync } from 'fs';
import { join, sep, parse } from 'path';
import { tmpdir } from 'os';
import { execFileSync } from 'child_process';
import {
  filterIgnored,
  extractGist,
  extractHeadings,
  readConfig,
  scanLocations,
  buildRegistry,
  loadRegistry,
  addLocation,
  removeLocation,
  listLocations,
  servableEntries,
} from './doc-sources.js';
import { hashContent } from './content-hash.js';

// Review 2 (P-T1, P-T6): an entry is served by its realpath but printed as registered, so only a
// plain absolute path in the host's own form qualifies: no `.`/`..` segment (a link inside the
// project plus `..` prints a path that names a file outside it), and on Windows a drive or UNC path
// (`\proj\x.md` is drive-relative). Both count as `relative`.
describe('servableEntries: only a plain absolute path is served (review 2)', () => {
  const entry = (path: string) => ({ id: 'i', path, rel: 'r', gist: 'g', headings: [], hash: 'h', mtime: 'x', size: 1 });
  it('refuses a dot segment and, on Windows, a drive-relative path', () => {
    const root = mkdtempSync(join(tmpdir(), 'se-dots-'));
    mkdirSync(join(root, 'docs'), { recursive: true });
    const inside = join(root, 'docs', 'a.md');
    writeFileSync(inside, '# a\n');
    const dotted = [root, 'docs', '..', 'docs', 'a.md'].join(sep);   // join() would normalise the `..` away
    const dotOnly = [root, '.', 'docs', 'a.md'].join(sep);
    const entries = [entry(inside), entry(dotted), entry(dotOnly)];
    if (process.platform === 'win32') entries.push(entry(inside.slice(2)));   // "\Users\...\a.md": drive-relative
    const r = servableEntries(entries, root);
    expect(r.kept.map(e => e.path)).toEqual([inside]);
    expect(r.relative).toBe(entries.length - 1);
    rmSync(root, { recursive: true, force: true });
  });

  // P-S7: a session started in the home directory (or above it, or at a drive root) made every file
  // under it servable: ~/.bash_history, ~/.env. Such a root serves nothing (fails closed); the
  // reason is reported (rootStatus) for the gate=local-doc-drop row.
  it('refuses a project root that is the home directory, contains it, or is a filesystem root (P-S7)', () => {
    const base = mkdtempSync(join(tmpdir(), 'se-home-'));
    const home = join(base, 'home', 'u');
    mkdirSync(join(home, 'proj', 'docs'), { recursive: true });
    const secret = join(home, '.bash_history');
    writeFileSync(secret, 'x\n');
    const doc = join(home, 'proj', 'docs', 'a.md');
    writeFileSync(doc, '# a\n');
    const entries = [entry(secret), entry(doc)];
    const at = (root: string | undefined) => servableEntries(entries, root, home);
    expect(at(home)).toMatchObject({ kept: [], outside: 2, rootUsable: false, rootStatus: 'home' });
    expect(at(join(base, 'home'))).toMatchObject({ kept: [], outside: 2, rootUsable: false, rootStatus: 'home' });
    expect(at(parse(base).root)).toMatchObject({ kept: [], outside: 2, rootUsable: false, rootStatus: 'fs-root' });
    expect(at(undefined)).toMatchObject({ kept: [], outside: 2, rootUsable: false, rootStatus: 'unusable' });
    expect(at(join(base, 'nope'))).toMatchObject({ kept: [], rootStatus: 'unusable' });
    const ok = at(join(home, 'proj'));
    expect(ok).toMatchObject({ rootUsable: true, rootStatus: 'ok', outside: 1 });
    expect(ok.kept.map(e => e.path)).toEqual([doc]);
    rmSync(base, { recursive: true, force: true });
  });

  // P-F5: a registry built in another checkout of the project (a worktree that shares the slug) and
  // a forged entry both counted as `outside`. An entry outside the root whose path ends in its own
  // `rel`, and whose `rel` names a file under this root, is counted as otherCheckout instead. It is
  // still not served: the registry entry, not this checkout's file, would be printed.
  it('counts an entry from another checkout of the project apart from a forged one (P-F5)', () => {
    const base = mkdtempSync(join(tmpdir(), 'se-other-'));
    const here = join(base, 'here'), there = join(base, 'there');
    for (const r of [here, there]) { mkdirSync(join(r, 'docs'), { recursive: true }); writeFileSync(join(r, 'docs', 'a.md'), '# a\n'); }
    writeFileSync(join(there, 'docs', 'only-there.md'), '# b\n');
    const e = (path: string, rel: string) => ({ ...entry(path), rel });
    const r = servableEntries([
      e(join(here, 'docs', 'a.md'), 'docs/a.md'),
      e(join(there, 'docs', 'a.md'), 'docs/a.md'),                 // the same doc in the other checkout
      e(join(there, 'docs', 'only-there.md'), 'docs/only-there.md'), // not in this checkout: outside
      e(join(there, 'docs', 'a.md'), 'a.md'),                       // rel does not match its path: outside
      e(join(there, 'docs', 'a.md'), '../here/docs/a.md'),          // a rel that climbs: outside
      e(join(there, 'docs', 'only-there.md'), 'docs/a.md'),         // a rel its own path does not end in: outside
    ], here, join(base, 'home'));
    expect(r.kept.map(x => x.path)).toEqual([join(here, 'docs', 'a.md')]);
    expect(r).toMatchObject({ otherCheckout: 1, outside: 4 });
    rmSync(base, { recursive: true, force: true });
  });
});

describe('doc-sources filterIgnored', () => {
  it('drops junk-dir paths (node_modules) and keeps real docs', async () => {
    const root = await fs.mkdtemp(join(tmpdir(), 'fi-'));   // non-git → junk-skip-only path
    const junk = join(root, 'node_modules', 'pkg', 'x.md');
    const keep = join(root, 'docs', 'y.md');
    expect(filterIgnored(root, [junk, keep])).toEqual([keep]);
  });

  it('splits path segments on both separators (the junk regex is cross-OS)', () => {
    // The fix is `.split(/[\\/]+/)`; assert the regex segments a backslash path so the
    // JUNK_DIRS check works when path.relative emits native (Windows) separators.
    expect('node_modules\\pkg\\x.md'.split(/[\\/]+/)).toContain('node_modules');
  });
});

// --- folded from mcp/test/doc-sources.test.ts (now co-located with its source module) ---

describe('extractGist', () => {
  it('prefers the H1 heading', () => {
    expect(extractGist('---\ntitle: "FM"\n---\n# The H1\n\nbody')).toBe('The H1');
  });
  it('falls back to frontmatter title when no H1', () => {
    expect(extractGist('---\ntitle: "FM title"\n---\n\n## Sub\n')).toBe('FM title');
  });
  it('falls back to first non-empty line when neither', () => {
    expect(extractGist('\n\nFirst real line\nsecond')).toBe('First real line');
  });
  it('reads frontmatter title from a CRLF file with no H1', () => {
    expect(extractGist('---\r\ntitle: CR Doc\r\n---\r\n\r\nbody')).toBe('CR Doc');
  });
  it('uses first body line when frontmatter has no title and no H1', () => {
    expect(extractGist('---\nfoo: bar\n---\nFirst body line\nsecond')).toBe('First body line');
  });
});

describe('extractHeadings', () => {
  it('returns H2/H3 headings, not H1', () => {
    expect(extractHeadings('# Title\n## A\ntext\n### B\n#### C')).toEqual(['## A', '### B']);
  });
});

describe('hashContent', () => {
  it('is stable and content-sensitive', () => {
    expect(hashContent('abc')).toBe(hashContent('abc'));
    expect(hashContent('abc')).not.toBe(hashContent('abd'));
    expect(hashContent('abc')).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe('readConfig', () => {
  it('returns {locations:[]} when no config exists', async () => {
    const brain = mkdtempSync(join(tmpdir(), 'ds-b-'));
    expect((await readConfig(brain, 'proj')).locations).toEqual([]);
    rmSync(brain, { recursive: true, force: true });
  });
});

describe('scanLocations', () => {
  let root: string;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'ds-r-'));
    mkdirSync(join(root, 'docs'), { recursive: true });
    writeFileSync(join(root, 'docs', 'deploy.md'), '# Deploy\n\n## Steps\n\ndo it\n');
    writeFileSync(join(root, 'docs', 'secret.md'), '# Secret\n\ntoken\n');
  });
  afterEach(() => rmSync(root, { recursive: true, force: true }));

  it('scans a folder location into entries with gist+headings+hash', async () => {
    const entries = await scanLocations(root, ['docs/']);
    const deploy = entries.find((e) => e.rel === 'docs/deploy.md');
    expect(deploy).toBeDefined();
    expect(deploy!.gist).toBe('Deploy');
    expect(deploy!.headings).toEqual(['## Steps']);
    expect(deploy!.hash).toMatch(/^[0-9a-f]{64}$/);
    expect(deploy!.id).toBe(deploy!.hash.slice(0, 12));
  });

  it('honors .gitignore (git repo) — ignored files are excluded', async () => {
    execFileSync('git', ['-C', root, 'init', '-q']);
    writeFileSync(join(root, '.gitignore'), 'docs/secret.md\n');
    const entries = await scanLocations(root, ['docs/']);
    expect(entries.some((e) => e.rel === 'docs/secret.md')).toBe(false);
    expect(entries.some((e) => e.rel === 'docs/deploy.md')).toBe(true);
  });

  it('does not scan an absolute-path location outside root', async () => {
    const outside = mkdtempSync(join(tmpdir(), 'ds-abs-'));
    writeFileSync(join(outside, 'leak.md'), '# Leak\n');
    try {
      const entries = await scanLocations(root, [outside]);
      expect(entries.some((e) => e.path.includes('leak'))).toBe(false);
    } finally { rmSync(outside, { recursive: true, force: true }); }
  });

  it('does not scan a ../ location outside root', async () => {
    const outside = mkdtempSync(join(tmpdir(), 'ds-up-'));
    writeFileSync(join(outside, 'leak.md'), '# Leak\n');
    try {
      const rel = '../' + (outside.split('/').pop() as string);
      const entries = await scanLocations(root, [rel]);
      expect(entries.some((e) => e.path.includes('leak'))).toBe(false);
    } finally { rmSync(outside, { recursive: true, force: true }); }
  });

  it('honors an explicit glob location', async () => {
    const entries = await scanLocations(root, ['docs/*.md']);
    expect(entries.map((e) => e.rel).sort()).toEqual(['docs/deploy.md', 'docs/secret.md']);
  });

  it('skips node_modules even without a git repo', async () => {
    mkdirSync(join(root, 'node_modules', 'pkg'), { recursive: true });
    writeFileSync(join(root, 'node_modules', 'pkg', 'readme.md'), '# Dep\n');
    const entries = await scanLocations(root, ['.']);
    expect(entries.some((e) => e.rel.includes('node_modules'))).toBe(false);
  });
});

describe('buildRegistry / lifecycle', () => {
  let root: string; let brain: string;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'ds-pr-'));
    brain = mkdtempSync(join(tmpdir(), 'ds-bn-'));
    mkdirSync(join(brain, 'projects', 'proj'), { recursive: true });
    mkdirSync(join(root, 'docs'), { recursive: true });
    writeFileSync(join(brain, 'projects', 'proj', 'doc-sources.config.json'), JSON.stringify({ locations: ['docs/'] }));
    writeFileSync(join(root, 'docs', 'a.md'), '# Alpha\n\nbody\n');
  });
  afterEach(() => { rmSync(root, { recursive: true, force: true }); rmSync(brain, { recursive: true, force: true }); });

  it('builds and loads a registry of the live files', async () => {
    const reg = await buildRegistry(root, brain, 'proj');
    expect(reg.project).toBe('proj');
    expect(reg.entries.map((e) => e.rel)).toEqual(['docs/a.md']);
    const loaded = await loadRegistry(brain, 'proj');
    expect(loaded!.entries).toEqual(reg.entries);
  });

  it('moved file keeps its id/hash with the new path', async () => {
    const r1 = await buildRegistry(root, brain, 'proj');
    const before = r1.entries[0];
    renameSync(join(root, 'docs', 'a.md'), join(root, 'docs', 'b.md'));
    const r2 = await buildRegistry(root, brain, 'proj');
    expect(r2.entries).toHaveLength(1);
    expect(r2.entries[0].rel).toBe('docs/b.md');
    expect(r2.entries[0].id).toBe(before.id);
    expect(r2.entries[0].hash).toBe(before.hash);
  });

  it('removed file drops out of the registry', async () => {
    await buildRegistry(root, brain, 'proj');
    unlinkSync(join(root, 'docs', 'a.md'));
    const r2 = await buildRegistry(root, brain, 'proj');
    expect(r2.entries).toEqual([]);
  });

  it('loadRegistry returns null when no registry exists', async () => {
    expect(await loadRegistry(brain, 'missing-slug')).toBeNull();
  });

  it('buildRegistry rejects an unsafe slug (path traversal) and writes nothing outside', async () => {
    await expect(buildRegistry(root, brain, '../escape')).rejects.toThrow(/unsafe slug/);
    expect(existsSync(join(brain, '..', 'escape', 'doc-sources.json'))).toBe(false);
  });
  it('loadRegistry returns null for an unsafe slug', async () => {
    expect(await loadRegistry(brain, '../escape')).toBeNull();
  });
});

describe('track config mutations', () => {
  let brain: string;
  beforeEach(() => {
    brain = mkdtempSync(join(tmpdir(), 'ds-cfg-'));
    mkdirSync(join(brain, 'projects', 'proj'), { recursive: true });
  });
  afterEach(() => rmSync(brain, { recursive: true, force: true }));

  it('adds a location (dedup) and lists it', async () => {
    const r1 = await addLocation(brain, 'proj', 'docs/');
    expect(r1.added).toBe(true);
    expect(await listLocations(brain, 'proj')).toEqual(['docs/']);
    const r2 = await addLocation(brain, 'proj', 'docs/');
    expect(r2.added).toBe(false);
    expect(await listLocations(brain, 'proj')).toEqual(['docs/']);
  });

  it('removes a location', async () => {
    await addLocation(brain, 'proj', 'docs/');
    await addLocation(brain, 'proj', '.ai-docs/');
    const r = await removeLocation(brain, 'proj', 'docs/');
    expect(r.removed).toBe(true);
    expect(await listLocations(brain, 'proj')).toEqual(['.ai-docs/']);
    const r2 = await removeLocation(brain, 'proj', 'nope/');
    expect(r2.removed).toBe(false);
  });

  it('rejects an unsafe location (absolute or ..)', async () => {
    await expect(addLocation(brain, 'proj', '/etc')).rejects.toThrow(/invalid location/);
    await expect(addLocation(brain, 'proj', '../outside')).rejects.toThrow(/invalid location/);
  });

  it('rejects an unsafe slug', async () => {
    await expect(addLocation(brain, '../escape', 'docs/')).rejects.toThrow(/unsafe slug/);
    expect(await listLocations(brain, '../escape').catch(() => 'threw')).toBe('threw');
  });

  it('normalizes ./ prefix and trims', async () => {
    await addLocation(brain, 'proj', '  ./docs/  ');
    expect(await listLocations(brain, 'proj')).toEqual(['docs/']);
  });
});
