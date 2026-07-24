import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { slugFromProjectDir, activeProjectDir, resolveActiveSlug } from './project-dir.js';

describe('slugFromProjectDir', () => {
  it('returns the basename of a real path', () => {
    expect(slugFromProjectDir('/home/cainish/Projects/claude-code-plugin')).toBe('claude-code-plugin');
  });
  it('rejects degenerate paths', () => {
    expect(slugFromProjectDir(undefined)).toBeUndefined();
    expect(slugFromProjectDir('')).toBeUndefined();
    expect(slugFromProjectDir('/')).toBeUndefined();
    expect(slugFromProjectDir('.')).toBeUndefined();
  });
});

describe('activeProjectDir', () => {
  it('prefers CLAUDE_PROJECT_DIR over cwd', () => {
    const env = { CLAUDE_PROJECT_DIR: '/proj/root' } as NodeJS.ProcessEnv;
    expect(activeProjectDir(env, () => '/some/mcp/launch/dir')).toBe('/proj/root');
  });
  it('falls back to cwd when CLAUDE_PROJECT_DIR is unset (older CLI)', () => {
    const env = {} as NodeJS.ProcessEnv;
    expect(activeProjectDir(env, () => '/the/cwd')).toBe('/the/cwd');
  });
  it('end-to-end: env project dir resolves to its slug', () => {
    const env = { CLAUDE_PROJECT_DIR: '/home/u/my-repo' } as NodeJS.ProcessEnv;
    expect(slugFromProjectDir(activeProjectDir(env, () => '/tmp/x'))).toBe('my-repo');
  });
});

// --- folded from mcp/test/project-dir.test.ts (now co-located with its source module) ---

describe('slugFromProjectDir — tmp→scratch normalization (parity with session-load.sh)', () => {
  it('collapses tmp-like dirs to a single "scratch" project', () => {
    expect(slugFromProjectDir('/tmp/tmp.aB3xq9')).toBe('scratch');
    expect(slugFromProjectDir('/x/tmp')).toBe('scratch');
    expect(slugFromProjectDir('/x/.tmp.zzz')).toBe('scratch');
    expect(slugFromProjectDir('/x/tmpfs')).toBe('scratch');
  });
  it('leaves a real project basename intact', () => {
    expect(slugFromProjectDir('/home/u/Projects/my-app')).toBe('my-app');
    expect(slugFromProjectDir('/home/u/Projects/claude-code-plugin')).toBe('claude-code-plugin');
  });
  it('rejects degenerate dirs', () => {
    expect(slugFromProjectDir('/')).toBeUndefined();
    expect(slugFromProjectDir('/foo/..')).toBeUndefined();
    expect(slugFromProjectDir(undefined)).toBeUndefined();
  });
});

describe('resolveActiveSlug — per-session project dir beats the global pin', () => {
  let brainDir: string;
  beforeEach(() => {
    brainDir = mkdtempSync(join(tmpdir(), 'slug-resolve-'));
    // a STALE pin written by another (concurrent) session
    mkdirSync(join(brainDir, 'projects', 'cainish'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'cainish', 'PROJECT.md'), '# PROJECT: cainish\n');
    mkdirSync(join(brainDir, 'projects', 'claude-code-plugin'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'claude-code-plugin', 'PROJECT.md'), '# PROJECT: claude-code-plugin\n');
    writeFileSync(join(brainDir, '.active-session-slug'), 'cainish');
  });
  afterEach(() => rmSync(brainDir, { recursive: true, force: true }));

  it('prefers CLAUDE_PROJECT_DIR over a conflicting .active-session-slug pin (the concurrent-session bug)', () => {
    const slug = resolveActiveSlug(brainDir, { CLAUDE_PROJECT_DIR: '/home/u/Projects/claude-code-plugin' }, () => '/somewhere/else');
    expect(slug).toBe('claude-code-plugin'); // NOT the stale 'cainish' pin
  });

  it('a cwd that names a KNOWN project beats the stale pin when CLAUDE_PROJECT_DIR is unset (the live concurrent-session bug)', () => {
    // THIS is the case the merged 0.24.29 fix got wrong: no CLAUDE_PROJECT_DIR, cwd IS the real
    // project (projects/claude-code-plugin exists), pin clobbered to 'cainish' by another session.
    const slug = resolveActiveSlug(brainDir, {}, () => '/home/u/Projects/claude-code-plugin');
    expect(slug).toBe('claude-code-plugin'); // per-process cwd wins; the racy pin is ignored
  });

  it('a SUBDIR cwd (not a known project) falls to the pin (subdir survival preserved)', () => {
    // cwd is a subdir whose basename is not a registered project → use the session-root pin.
    const slug = resolveActiveSlug(brainDir, {}, () => '/home/u/Projects/claude-code-plugin/scripts');
    expect(slug).toBe('cainish');
  });

  it('falls back to cwd basename when CLAUDE_PROJECT_DIR unset and the pin is invalid', () => {
    writeFileSync(join(brainDir, '.active-session-slug'), 'no-such-project');
    const slug = resolveActiveSlug(brainDir, {}, () => '/home/u/Projects/my-app');
    expect(slug).toBe('my-app');
  });

  it('normalizes a tmp project dir to scratch (not the pin)', () => {
    const slug = resolveActiveSlug(brainDir, { CLAUDE_PROJECT_DIR: '/tmp/tmp.xY9' }, () => '/');
    expect(slug).toBe('scratch');
  });

  it('skips a degenerate CLAUDE_PROJECT_DIR ("/") and falls through to the pin (TS/bash parity)', () => {
    const slug = resolveActiveSlug(brainDir, { CLAUDE_PROJECT_DIR: '/' }, () => '/x');
    expect(slug).toBe('cainish');
  });
});

describe('resolveActiveSlug — registry-path (monorepo)', () => {
  function brainWithChild(): string {
    const dir = mkdtempSync(join(tmpdir(), 'sb-resolve-'));
    writeFileSync(join(dir, 'projects.jsonl'),
      '{"slug":"acme__api","parent":"acme","root_path":"/repos/acme/packages/api"}\n');
    mkdirSync(join(dir, 'projects', 'acme__api'), { recursive: true });
    writeFileSync(join(dir, 'projects', 'acme__api', 'PROJECT.md'), '# PROJECT: acme__api\n');
    return dir;
  }
  it('resolves a cwd inside a registered child to its path-qualified slug', () => {
    const dir = brainWithChild();
    const slug = resolveActiveSlug(dir, {} as NodeJS.ProcessEnv, () => '/repos/acme/packages/api/src');
    expect(slug).toBe('acme__api');
    rmSync(dir, { recursive: true, force: true });
  });
  it('CLAUDE_PROJECT_DIR inside a registered child also maps via root_path', () => {
    const dir = brainWithChild();
    const slug = resolveActiveSlug(dir, { CLAUDE_PROJECT_DIR: '/repos/acme/packages/api' } as any, () => '/elsewhere');
    expect(slug).toBe('acme__api');
    rmSync(dir, { recursive: true, force: true });
  });
  it('falls back to bare basename when no root_path matches (standalone, unchanged)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'sb-resolve2-'));
    const slug = resolveActiveSlug(dir, {} as NodeJS.ProcessEnv, () => '/repos/standalone');
    expect(slug).toBe('standalone');
    rmSync(dir, { recursive: true, force: true });
  });
  it('a cwd registry-path match wins over a same-basename known project', () => {
    const dir = brainWithChild();
    // also seed a bare `api` known project; the registry root_path match must still win
    mkdirSync(join(dir, 'projects', 'api'), { recursive: true });
    writeFileSync(join(dir, 'projects', 'api', 'PROJECT.md'), '# PROJECT: api\n');
    const slug = resolveActiveSlug(dir, {} as NodeJS.ProcessEnv, () => '/repos/acme/packages/api/src');
    expect(slug).toBe('acme__api');   // registry-path tier precedes the known-basename tier
    rmSync(dir, { recursive: true, force: true });
  });
});

describe('resolveActiveSlug — remote identity beats basename (the re-clone bug)', () => {
  let brainDir: string;
  let work: string;
  // repo `name` registered with remote X; the session runs from a re-clone dir `name-2`
  function cloneDir(dirName: string, remoteUrl?: string): string {
    const d = join(work, dirName);
    mkdirSync(join(d, '.git'), { recursive: true });
    writeFileSync(join(d, '.git', 'config'),
      remoteUrl ? `[remote "origin"]\n\turl = ${remoteUrl}\n` : '[core]\n\tbare = false\n');
    return d;
  }
  beforeEach(() => {
    brainDir = mkdtempSync(join(tmpdir(), 'sb-remote-'));
    work = mkdtempSync(join(tmpdir(), 'sb-remote-work-'));
    writeFileSync(join(brainDir, 'projects.jsonl'),
      '{"slug":"name","last_session_iso":"2026-01-01T00:00:00Z","git_remote":"https://github.com/example/name.git"}\n');
    mkdirSync(join(brainDir, 'projects', 'name'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'name', 'PROJECT.md'), '# PROJECT: name\n');
  });
  afterEach(() => {
    rmSync(brainDir, { recursive: true, force: true });
    rmSync(work, { recursive: true, force: true });
  });

  it('CLAUDE_PROJECT_DIR pointing at a re-clone resolves the registered slug', () => {
    const d = cloneDir('name-2', 'https://github.com/example/name.git');
    expect(resolveActiveSlug(brainDir, { CLAUDE_PROJECT_DIR: d }, () => '/elsewhere')).toBe('name');
  });

  it('ssh/scp remote form matches the https-registered identity', () => {
    const d = cloneDir('name-3', 'git@github.com:Example/Name.git');
    expect(resolveActiveSlug(brainDir, { CLAUDE_PROJECT_DIR: d }, () => '/elsewhere')).toBe('name');
  });

  it('cwd fallback path also gets the remote upgrade', () => {
    const d = cloneDir('name-2', 'https://github.com/example/name.git');
    expect(resolveActiveSlug(brainDir, {}, () => d)).toBe('name');
  });

  it('a remote-less dir keeps its basename (fail open, no behavior change)', () => {
    const d = cloneDir('name-4');
    expect(resolveActiveSlug(brainDir, { CLAUDE_PROJECT_DIR: d }, () => '/elsewhere')).toBe('name-4');
  });

  it('an unregistered remote falls back to the basename', () => {
    const d = cloneDir('other', 'https://github.com/example/other.git');
    expect(resolveActiveSlug(brainDir, { CLAUDE_PROJECT_DIR: d }, () => '/elsewhere')).toBe('other');
  });
});
