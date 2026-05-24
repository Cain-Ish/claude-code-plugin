import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { extractGist, extractHeadings, hashContent } from '../src/tools/doc-sources.js';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, renameSync, unlinkSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { execFileSync } from 'child_process';
import { readConfig, scanLocations, buildRegistry, loadRegistry } from '../src/tools/doc-sources.js';

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
});
