import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from 'fs';
import { execFileSync } from 'child_process';
import { tmpdir } from 'os';
import { dirname, isAbsolute, join } from 'path';
import { fileURLToPath } from 'url';
import { scanSources } from './scan-sources.js';
import type { GitRunner } from './scan-sources.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(HERE, '__fixtures__', 'sample');

// Forces the glob fallback: the committed fixture lives INSIDE the plugin
// repo, so a real `git ls-files` there would enumerate the plugin repo's
// index (or nothing, pre-commit) instead of the fixture tree.
const noGit: GitRunner = async () => {
  throw new Error('stub: not a git repository');
};

const ENV_KEYS = ['SB_CODEMAP_MAX_FILE_BYTES', 'SB_CODEMAP_MAX_FILES'];

describe('scanSources', () => {
  const saved: Record<string, string | undefined> = {};
  const tempDirs: string[] = [];

  beforeEach(() => {
    for (const k of ENV_KEYS) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });

  afterEach(() => {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    for (const d of tempDirs.splice(0)) rmSync(d, { recursive: true, force: true });
  });

  function tempDir(): string {
    const d = mkdtempSync(join(tmpdir(), 'sb-codemap-scan-'));
    tempDirs.push(d);
    return d;
  }

  // The committed fixture holds only git-trackable files: the repo-root
  // .gitignore has a bare `node_modules/` rule, so a committed fixture
  // node_modules/ would silently vanish from fresh clones (and `git clean`).
  // The must-be-excluded dirs are therefore materialized at test time.
  function sampleTree(): string {
    const d = tempDir();
    cpSync(FIXTURE, d, { recursive: true });
    const junk: Array<[string, string]> = [
      ['node_modules/pkg/index.js', 'module.exports = 1;\n'],
      ['packages/a/node_modules/dep/x.js', 'module.exports = 2;\n'],
      ['dist/bundle.js', 'var bundled = 1;\n'],
      ['build/gen.js', 'var gen = 1;\n'],
      ['coverage/report.js', 'var cov = 1;\n'],
      ['vendor/lib.js', 'var vendored = 1;\n'],
      ['.next/page.js', 'var page = 1;\n'],
      ['out/main.js', 'var out = 1;\n'],
      ['.git/hooks/sample.js', 'var hook = 1;\n'],
    ];
    for (const [rel, body] of junk) {
      const abs = join(d, ...rel.split('/'));
      mkdirSync(dirname(abs), { recursive: true });
      writeFileSync(abs, body);
    }
    return d;
  }

  it('glob fallback excludes the hardcoded ignore dirs', async () => {
    const root = sampleTree();
    const { files, truncated } = await scanSources(root, { runGit: noGit });
    const ids = files.map((f) => f.id);
    expect(ids).toContain('src/app.ts');
    expect(ids).toContain('src/helper.ts');
    expect(ids).toContain('src/util.py');
    for (const id of ids) {
      expect(id).not.toMatch(
        /(^|\/)(node_modules|dist|build|coverage|vendor|\.next|out|\.git)\//
      );
    }
    expect(truncated).toBe(false);
  });

  it('tags langs by extension and drops non-code files', async () => {
    const root = tempDir();
    const sources: Array<[string, string]> = [
      ['a.ts', 'export const a = 1;\n'],
      ['b.tsx', 'export const b = 2;\n'],
      ['c.js', 'var c = 3;\n'],
      ['d.jsx', 'var d = 4;\n'],
      ['e.mjs', 'export const e = 5;\n'],
      ['f.cjs', 'module.exports = 6;\n'],
      ['g.py', 'g = 7\n'],
      ['readme.md', '# not code\n'],
      ['notes.txt', 'not code\n'],
    ];
    for (const [rel, body] of sources) writeFileSync(join(root, rel), body);
    const { files } = await scanSources(root, { runGit: noGit });
    const byId = new Map(files.map((f) => [f.id, f.lang]));
    expect(byId.get('a.ts')).toBe('ts');
    expect(byId.get('b.tsx')).toBe('ts');
    expect(byId.get('c.js')).toBe('js');
    expect(byId.get('d.jsx')).toBe('js');
    expect(byId.get('e.mjs')).toBe('js');
    expect(byId.get('f.cjs')).toBe('js');
    expect(byId.get('g.py')).toBe('py');
    expect(byId.has('readme.md')).toBe(false);
    expect(byId.has('notes.txt')).toBe(false);
    expect(files).toHaveLength(7);
  });

  it('drops *.min.js on the glob path', async () => {
    const root = sampleTree();
    const { files } = await scanSources(root, { runGit: noGit });
    expect(files.map((f) => f.id)).not.toContain('src/big.min.js');
  });

  it('drops *.min.js on the git path too (tracked minified bundles)', async () => {
    const root = sampleTree();
    const runGit: GitRunner = async () => 'src/app.ts\0src/big.min.js\0';
    const { files } = await scanSources(root, { runGit });
    expect(files.map((f) => f.id)).toEqual(['src/app.ts']);
  });

  it('ids are POSIX-relative with no backslash, even on Windows', async () => {
    const root = sampleTree();
    const { files } = await scanSources(root, { runGit: noGit });
    expect(files.length).toBeGreaterThan(0);
    for (const f of files) {
      expect(f.id).not.toContain('\\');
      expect(f.id.startsWith('/')).toBe(false);
      expect(isAbsolute(f.abs)).toBe(true);
    }
    expect(files.map((f) => f.id)).toContain('src/app.ts');
  });

  it('size cap drops oversized files and reports truncated', async () => {
    process.env.SB_CODEMAP_MAX_FILE_BYTES = '100';
    const root = tempDir();
    writeFileSync(join(root, 'small.ts'), 'export const s = 1;\n');
    writeFileSync(join(root, 'huge.ts'), `export const h = '${'x'.repeat(300)}';\n`);
    const result = await scanSources(root, { runGit: noGit });
    expect(result.files.map((f) => f.id)).toEqual(['small.ts']);
    expect(result.truncated).toBe(true);
  });

  it('count cap keeps most-recently-modified files and reports truncated', async () => {
    process.env.SB_CODEMAP_MAX_FILES = '2';
    const root = tempDir();
    const stamps: Array<[string, Date]> = [
      ['a.ts', new Date('2020-01-01T00:00:00Z')],
      ['b.ts', new Date('2021-01-01T00:00:00Z')],
      ['c.ts', new Date('2022-01-01T00:00:00Z')],
    ];
    for (const [rel, when] of stamps) {
      const abs = join(root, rel);
      writeFileSync(abs, `export const v = '${rel}';\n`);
      utimesSync(abs, when, when);
    }
    const result = await scanSources(root, { runGit: noGit });
    // a.ts (oldest) is dropped; output stays id-sorted after the mtime slice.
    expect(result.files.map((f) => f.id)).toEqual(['b.ts', 'c.ts']);
    expect(result.truncated).toBe(true);
  });

  it('defaults apply when cap env vars are invalid (no false truncation)', async () => {
    process.env.SB_CODEMAP_MAX_FILES = '0';
    process.env.SB_CODEMAP_MAX_FILE_BYTES = 'abc';
    const root = tempDir();
    for (const rel of ['a.ts', 'b.ts', 'c.py']) {
      writeFileSync(join(root, rel), 'x = 1\n');
    }
    const result = await scanSources(root, { runGit: noGit });
    expect(result.files).toHaveLength(3);
    expect(result.truncated).toBe(false);
  });

  it('git path enumerates via the injected runner (NUL-split), filtering langs', async () => {
    const root = sampleTree();
    const calls: string[][] = [];
    const runGit: GitRunner = async (args, cwd) => {
      calls.push(args);
      expect(cwd).toBe(root);
      return 'src/app.ts\0src/util.py\0readme.md\0';
    };
    const result = await scanSources(root, { runGit });
    expect(calls).toEqual([['ls-files', '-z']]);
    expect(result.files.map((f) => [f.id, f.lang])).toEqual([
      ['src/app.ts', 'ts'],
      ['src/util.py', 'py'],
    ]);
  });

  it('git path skips index entries missing from the worktree', async () => {
    const root = sampleTree();
    const runGit: GitRunner = async () => 'gone.ts\0src/app.ts\0';
    const result = await scanSources(root, { runGit });
    expect(result.files.map((f) => f.id)).toEqual(['src/app.ts']);
  });

  it('git path excludes TRACKED ignore-dir artifacts (committed bundles)', async () => {
    const root = sampleTree();
    // Materialize the artifacts on disk: if the IGNORE_DIRS cut regressed, a
    // stat-miss on a nonexistent path would still exclude them and false-green
    // this test — only IGNORE_DIR_RE may be doing the excluding here.
    const tracked: Array<[string, string]> = [
      ['mcp/dist/x.bundle.js', 'var bundled = 1;\n'],
      ['node_modules/y.js', 'module.exports = 1;\n'],
      ['vendor/z.py', 'z = 1\n'],
    ];
    for (const [rel, body] of tracked) {
      const abs = join(root, ...rel.split('/'));
      mkdirSync(dirname(abs), { recursive: true });
      writeFileSync(abs, body);
    }
    const runGit: GitRunner = async () =>
      'src/app.ts\0mcp/dist/x.bundle.js\0node_modules/y.js\0vendor/z.py\0src/util.py\0';
    const { files, truncated } = await scanSources(root, { runGit });
    expect(files.map((f) => f.id)).toEqual(['src/app.ts', 'src/util.py']);
    expect(truncated).toBe(false);
  });

  it('oversized file INSIDE an ignored dir cannot pin truncated:true (git path)', async () => {
    // Regression: ignore-dir exclusion must happen BEFORE the size cap — a
    // committed >cap bundle used to set truncated:true permanently.
    process.env.SB_CODEMAP_MAX_FILE_BYTES = '100';
    const root = tempDir();
    mkdirSync(join(root, 'src'), { recursive: true });
    mkdirSync(join(root, 'dist'), { recursive: true });
    writeFileSync(join(root, 'src', 'app.ts'), 'export const a = 1;\n');
    writeFileSync(join(root, 'dist', 'huge.bundle.js'), `var blob = '${'x'.repeat(300)}';\n`);
    const runGit: GitRunner = async () => 'src/app.ts\0dist/huge.bundle.js\0';
    const result = await scanSources(root, { runGit });
    expect(result.files.map((f) => f.id)).toEqual(['src/app.ts']);
    expect(result.truncated).toBe(false);
  });

  it('real git repo: enumerates tracked files only', async () => {
    const root = tempDir();
    const git = (...args: string[]) =>
      execFileSync('git', args, { cwd: root, stdio: 'pipe' });
    git('init', '--quiet');
    writeFileSync(join(root, 'tracked.ts'), 'export const t = 1;\n');
    writeFileSync(join(root, 'untracked.ts'), 'export const u = 2;\n');
    git('add', 'tracked.ts');
    // No runGit injection: exercises the real execFile('git', ...) default.
    const result = await scanSources(root);
    expect(result.files.map((f) => f.id)).toEqual(['tracked.ts']);
    expect(result.files[0].lang).toBe('ts');
  });

  it('throws on a nonexistent repoRoot (fail loud, not an empty result)', async () => {
    const missing = join(tmpdir(), 'sb-codemap-definitely-missing-root');
    await expect(scanSources(missing, { runGit: noGit })).rejects.toThrow(/repoRoot/);
  });

  it('is deterministic: identical input tree yields identical output', async () => {
    const root = sampleTree();
    const a = await scanSources(root, { runGit: noGit });
    const b = await scanSources(root, { runGit: noGit });
    expect(b).toEqual(a);
    const ids = a.files.map((f) => f.id);
    expect(ids).toEqual([...ids].sort());
  });
});
