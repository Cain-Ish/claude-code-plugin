import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { promises as fs } from 'fs';
import { join, sep } from 'path';
import { tmpdir } from 'os';
import { walkWiki } from './walk-wiki.js';

let root: string;

beforeAll(async () => {
  root = await fs.mkdtemp(join(tmpdir(), 'walkwiki-'));
  const mk = async (rel: string, content = 'x') => {
    const p = join(root, ...rel.split('/'));
    await fs.mkdir(join(p, '..'), { recursive: true });
    await fs.writeFile(p, content);
  };
  await mk('entities/a.md');
  await mk('entities/nested/b.md');
  await mk('entities/index.md');
  await mk('index.md');
  await mk('projects/moc.md');
  await mk('.hidden/h.md');
  await mk('entities/notes.txt');
});

afterAll(async () => { await fs.rm(root, { recursive: true, force: true }); });

const names = (paths: string[]) => paths.map(p => p.split(sep).join('/').split('/').slice(-1)[0]).sort();
const rels = (paths: string[]) => paths.map(p => p.split(sep).join('/').replace(root.split(sep).join('/') + '/', '')).sort();

describe('walkWiki', () => {
  it('default: recursive .md only, index.md excluded, dot-dirs and skip-less dirs included', async () => {
    expect(rels(await walkWiki(root))).toEqual(['.hidden/h.md', 'entities/a.md', 'entities/nested/b.md', 'projects/moc.md']);
  });

  it('includeIndex keeps index.md files (stats / projector parity with the old glob)', async () => {
    const got = rels(await walkWiki(root, { includeIndex: true, skipHidden: true }));
    expect(got).toEqual(['entities/a.md', 'entities/index.md', 'entities/nested/b.md', 'index.md', 'projects/moc.md']);
  });

  it('skipDirs prunes the generated MOC dirs; skipHidden prunes dot-entries (CLI walker parity)', async () => {
    const got = rels(await walkWiki(root, { skipHidden: true, skipDirs: ['projects', 'themes'] }));
    expect(got).toEqual(['entities/a.md', 'entities/nested/b.md']);
  });

  it('posix returns forward-slash paths (the search-result path contract)', async () => {
    for (const p of await walkWiki(root, { posix: true })) expect(p).not.toContain('\\');
    expect(names(await walkWiki(root, { posix: true }))).toContain('a.md');
  });

  it('missing directory yields [] (tolerant), never throws', async () => {
    expect(await walkWiki(join(root, 'no-such-dir'))).toEqual([]);
  });
});
