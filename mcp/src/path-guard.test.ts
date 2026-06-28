// Path-traversal guard suite. The path-guard module is security-critical (it stops user/transcript-
// derived strings from escaping the KB dirs) but had no dedicated tests. This suite locks the full
// traversal-vector matrix AND applies the cross-platform discipline: every traversal vector is fed in
// BOTH forward-slash (`../`) and backslash (`..\`) form so a regression fails on either OS rather than
// silently skipping on the one whose separator it happens to use. (Adapted from vercel-labs/skills'
// paired Unix/Windows path tests — see PROJECT.md deep-scan decision.)
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { promises as fs } from 'fs';
import { join, sep } from 'path';
import { tmpdir } from 'os';
import { assertWithin, validateSlug, cleanEnvPath, PathGuardError } from './path-guard.js';
import { assertSafeSlug } from './tools/doc-sources.js';

const NUL = String.fromCharCode(0);
const SPACE = String.fromCharCode(32);

// The canonical traversal/abuse vectors, each given in both separator styles where relevant.
const TRAVERSAL_VECTORS = [
  '..', '../etc', '..\\etc', '../../secret', '..\\..\\secret',
  '/etc/passwd', 'C:\\Windows\\System32', '\\\\server\\share',
  'a/../../b', 'a\\..\\..\\b',
];

describe('validateSlug (strict syntactic slug guard)', () => {
  it('accepts well-formed slugs', () => {
    for (const ok of ['foo', 'foo-bar', 'foo_bar', 'Foo.Bar', 'a1', 'x'.repeat(128)]) {
      expect(() => validateSlug(ok), ok).not.toThrow();
    }
  });

  it('rejects every traversal vector in BOTH forward-slash and backslash form', () => {
    for (const v of TRAVERSAL_VECTORS) {
      expect(() => validateSlug(v), `should reject ${JSON.stringify(v)}`).toThrow(PathGuardError);
    }
  });

  it('rejects empty, oversize (>128), leading-dot, NUL, unicode, whitespace, and non-strings', () => {
    expect(() => validateSlug('')).toThrow(PathGuardError);
    expect(() => validateSlug('x'.repeat(129))).toThrow(PathGuardError);
    expect(() => validateSlug('.hidden')).toThrow(PathGuardError);
    expect(() => validateSlug('a' + SPACE + 'b')).toThrow(PathGuardError);
    expect(() => validateSlug('caf' + String.fromCharCode(0xE9))).toThrow(PathGuardError); // é, non-ASCII
    expect(() => validateSlug('a' + NUL + 'b')).toThrow(PathGuardError);
    // @ts-expect-error deliberate wrong type
    expect(() => validateSlug(undefined)).toThrow(PathGuardError);
  });
});

describe('assertSafeSlug (doc-sources slug guard) — parity with the traversal invariant', () => {
  it('rejects every separator/traversal vector in both forms', () => {
    for (const v of TRAVERSAL_VECTORS) {
      expect(() => assertSafeSlug(v), `should reject ${JSON.stringify(v)}`).toThrow();
    }
    expect(() => assertSafeSlug('')).toThrow();
  });

  it('rejects NUL and oversize slugs (hardening parity with validateSlug)', () => {
    expect(() => assertSafeSlug('a' + NUL + 'b')).toThrow();
    expect(() => assertSafeSlug('x'.repeat(129))).toThrow();
  });

  it('accepts ordinary slugs', () => {
    for (const ok of ['alpha', 'my-project', 'proj_1', 'A.B']) {
      expect(() => assertSafeSlug(ok)).not.toThrow();
    }
  });
});

describe('assertWithin (realpath-based containment)', () => {
  let base: string;
  beforeAll(async () => { base = await fs.realpath(await fs.mkdtemp(join(tmpdir(), 'pg-'))); });
  afterAll(async () => { await fs.rm(base, { recursive: true, force: true }); });

  it('accepts in-base paths and returns a path inside base', () => {
    const got = assertWithin(base, 'wiki', 'entities', 'page.md');
    expect(got.startsWith(base + sep)).toBe(true);
  });

  it('throws on a forward-slash `..` escape, an absolute part, and a NUL byte', () => {
    expect(() => assertWithin(base, '..', '..', 'etc')).toThrow(PathGuardError);
    expect(() => assertWithin(base, '/etc/passwd')).toThrow(PathGuardError);
    expect(() => assertWithin(base, 'a' + NUL + 'b')).toThrow(PathGuardError);
  });

  it('SAFETY INVARIANT: every traversal vector either throws or stays inside base on BOTH OSes — never escapes', () => {
    for (const v of TRAVERSAL_VECTORS) {
      let result: string | null = null;
      try { result = assertWithin(base, v); } catch (e) { expect(e).toBeInstanceOf(PathGuardError); }
      if (result !== null) {
        // Guard accepted it (e.g. on POSIX a backslash string is a literal filename) — it MUST be contained.
        expect(result === base || result.startsWith(base + sep), `${JSON.stringify(v)} escaped to ${result}`).toBe(true);
      }
    }
  });
});

describe('cleanEnvPath (CR/LF stripping for env-derived paths)', () => {
  it('strips CR, LF and CRLF in both Windows and POSIX path shapes (paired)', () => {
    expect(cleanEnvPath('C:\\Users\\me\\knowledge\r')).toBe('C:\\Users\\me\\knowledge');
    expect(cleanEnvPath('/home/me/knowledge\r')).toBe('/home/me/knowledge');
    expect(cleanEnvPath('a\r\nb')).toBe('ab');
  });

  it('is a no-op on clean input and returns "" for null/undefined', () => {
    expect(cleanEnvPath('/clean/path')).toBe('/clean/path');
    expect(cleanEnvPath(null)).toBe('');
    expect(cleanEnvPath(undefined)).toBe('');
  });
});
