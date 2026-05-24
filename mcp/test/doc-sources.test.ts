import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { extractGist, extractHeadings, hashContent } from '../src/tools/doc-sources.js';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { execFileSync } from 'child_process';
import { readConfig, scanLocations } from '../src/tools/doc-sources.js';

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
});
