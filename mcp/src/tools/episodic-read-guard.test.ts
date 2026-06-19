import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { assertTranscriptPath } from './episodic-search.js';
import { PathGuardError } from '../path-guard.js';

function detectSymlinkSupport(): boolean {
  const tmp = mkdtempSync(join(tmpdir(), 'epg-symcap-'));
  try { symlinkSync(tmpdir(), join(tmp, 'probe')); return true; }
  catch { return false; }
  finally { rmSync(tmp, { recursive: true, force: true }); }
}
const canSymlink = detectSymlinkSupport();

describe.skipIf(!canSymlink)('episodic_read path guard (G-MCP-1, R1.3)', () => {
  let brain: string;
  let outside: string;
  beforeAll(() => {
    brain = mkdtempSync(join(tmpdir(), 'sb-brain-'));
    mkdirSync(join(brain, 'transcripts'), { recursive: true });
    writeFileSync(join(brain, 'transcripts', 'ok.txt'),
      '--- session-meta ---\nsession_id: s\nproject_slug: p\ndate: 2026-06-10\n---\n\nbody\n');
    outside = mkdtempSync(join(tmpdir(), 'sb-secret-'));
    writeFileSync(join(outside, 'secret.txt'), 'SECRET');
    symlinkSync(join(outside, 'secret.txt'), join(brain, 'transcripts', 'link.txt'));
  });
  afterAll(() => {
    rmSync(brain, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  });

  it('accepts an absolute path inside transcripts/', () => {
    expect(assertTranscriptPath(brain, join(brain, 'transcripts', 'ok.txt'))).toContain('ok.txt');
  });
  it('rejects an absolute path outside transcripts/', () => {
    expect(() => assertTranscriptPath(brain, join(outside, 'secret.txt'))).toThrow(PathGuardError);
  });
  it('rejects ../ traversal', () => {
    expect(() => assertTranscriptPath(brain, '../../etc/passwd')).toThrow(PathGuardError);
  });
  it('rejects a symlink that escapes transcripts/', () => {
    expect(() => assertTranscriptPath(brain, join(brain, 'transcripts', 'link.txt'))).toThrow(PathGuardError);
  });
  it('rejects NUL bytes', () => {
    expect(() => assertTranscriptPath(brain, 'a\0b')).toThrow(PathGuardError);
  });
});
