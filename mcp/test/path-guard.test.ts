import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, mkdirSync, symlinkSync, writeFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { assertWithin, validateSlug, PathGuardError } from '../src/path-guard.js';

describe('assertWithin', () => {
  let baseDir: string;
  let outsideDir: string;
  beforeEach(() => {
    baseDir = mkdtempSync(join(tmpdir(), 'pg-base-'));
    outsideDir = mkdtempSync(join(tmpdir(), 'pg-out-'));
    mkdirSync(join(baseDir, 'projects'), { recursive: true });
  });
  afterEach(() => {
    rmSync(baseDir, { recursive: true, force: true });
    rmSync(outsideDir, { recursive: true, force: true });
  });

  it('allows normal joined paths inside baseDir', () => {
    const out = assertWithin(baseDir, 'projects', 'foo', 'PROJECT.md');
    expect(out).toMatch(/projects.foo.PROJECT.md$/);
  });

  it('rejects ../ escape via path traversal', () => {
    expect(() => assertWithin(baseDir, 'projects', '..', '..', '..', 'etc', 'passwd'))
      .toThrow(PathGuardError);
  });

  it('rejects absolute path component', () => {
    expect(() => assertWithin(baseDir, '/etc/passwd')).toThrow(PathGuardError);
  });

  it('rejects NUL byte in path component', () => {
    expect(() => assertWithin(baseDir, 'projects', 'foo\0bar')).toThrow(PathGuardError);
  });

  it('rejects symlink that escapes baseDir', () => {
    // baseDir/sneaky → outsideDir
    symlinkSync(outsideDir, join(baseDir, 'sneaky'));
    expect(() => assertWithin(baseDir, 'sneaky', 'evil.txt')).toThrow(PathGuardError);
  });

  it('allows symlink whose target stays inside baseDir', () => {
    mkdirSync(join(baseDir, 'real'), { recursive: true });
    symlinkSync(join(baseDir, 'real'), join(baseDir, 'alias'));
    const out = assertWithin(baseDir, 'alias', 'inside.txt');
    expect(out).toMatch(/real.inside.txt$/);
  });

  it('allows write-target whose leaf does not exist yet', () => {
    // The leaf file does not exist; helper must not throw on that alone.
    const out = assertWithin(baseDir, 'projects', 'new-slug', 'PROJECT.md');
    expect(out).toMatch(/projects.new-slug.PROJECT.md$/);
  });

  it('rejects when intermediate dir symlinks outside via missing leaf', () => {
    symlinkSync(outsideDir, join(baseDir, 'escape'));
    expect(() => assertWithin(baseDir, 'escape', 'newfile.txt')).toThrow(PathGuardError);
  });

  it('rejects baseDir-relative ../ even when target dir is created', () => {
    writeFileSync(join(outsideDir, 'real-target'), 'x');
    expect(() => assertWithin(baseDir, '..', 'pg-out-real-target'))
      .toThrow(PathGuardError);
  });
});

describe('validateSlug', () => {
  it('accepts kebab-case slugs', () => {
    expect(() => validateSlug('my-project-name')).not.toThrow();
    expect(() => validateSlug('claude-code-plugin')).not.toThrow();
  });

  it('accepts dot in middle (e.g. version-like)', () => {
    expect(() => validateSlug('v2.10.0')).not.toThrow();
  });

  it('accepts underscore', () => {
    expect(() => validateSlug('my_slug')).not.toThrow();
  });

  it('rejects empty string', () => {
    expect(() => validateSlug('')).toThrow(PathGuardError);
  });

  it('rejects path traversal', () => {
    expect(() => validateSlug('../etc')).toThrow(PathGuardError);
    expect(() => validateSlug('foo/../bar')).toThrow(PathGuardError);
  });

  it('rejects leading dot (would create hidden file)', () => {
    expect(() => validateSlug('.hidden')).toThrow(PathGuardError);
  });

  it('rejects forward slash', () => {
    expect(() => validateSlug('foo/bar')).toThrow(PathGuardError);
  });

  it('rejects null byte', () => {
    expect(() => validateSlug('foo\0bar')).toThrow(PathGuardError);
  });

  it('rejects whitespace', () => {
    expect(() => validateSlug('foo bar')).toThrow(PathGuardError);
  });

  it('rejects over-length (>128)', () => {
    expect(() => validateSlug('a'.repeat(129))).toThrow(PathGuardError);
  });
});
