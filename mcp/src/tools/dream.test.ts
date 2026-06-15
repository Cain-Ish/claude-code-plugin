import { describe, it, expect } from 'vitest';
import { toBashPath } from './dream.js';
import { cleanEnvPath } from './../path-guard.js';

describe('toBashPath (Windows -> bash argv path)', () => {
  it('maps a Windows backslash path to a Git-Bash POSIX path', () => {
    // The exact failure: passing this to bash ate the \ escapes -> "No such file or directory".
    expect(toBashPath('C:\\Users\\curst\\.claude\\plugins\\cache\\sb\\scripts\\dream-snapshot.sh'))
      .toBe('/c/Users/curst/.claude/plugins/cache/sb/scripts/dream-snapshot.sh');
  });
  it('lowercases the drive letter and strips the colon', () => {
    expect(toBashPath('D:\\a\\b.sh')).toBe('/d/a/b.sh');
  });
  it('is a no-op on a POSIX path (Linux/macOS)', () => {
    expect(toBashPath('/home/cainish/.claude/scripts/dream-snapshot.sh'))
      .toBe('/home/cainish/.claude/scripts/dream-snapshot.sh');
  });
  it('handles a forward-slash Windows path (already slashed, drive letter only)', () => {
    expect(toBashPath('C:/Users/x/s.sh')).toBe('/c/Users/x/s.sh');
  });
  it('leaves a relative POSIX path untouched', () => {
    expect(toBashPath('scripts/dream-snapshot.sh')).toBe('scripts/dream-snapshot.sh');
  });
  // 0.30.0: the confirmed Windows dream_create failure — a CRLF-tainted CLAUDE_PLUGIN_ROOT
  // leaves a \r in the path, and `bash dream-snapshot.sh\r` → "No such file or directory" on a
  // script that exists. toBashPath must strip CR (trailing AND mid-path) before bash sees it.
  it('strips a TRAILING carriage return (the dream_create No-such-file signature)', () => {
    expect(toBashPath('/c/Users/x/scripts/dream-snapshot.sh\r')).toBe('/c/Users/x/scripts/dream-snapshot.sh');
  });
  it('strips a MID-PATH carriage return from a CRLF-tainted plugin root', () => {
    expect(toBashPath('C:\\Users\\x\\plugin\r\\scripts\\dream-snapshot.sh'))
      .toBe('/c/Users/x/plugin/scripts/dream-snapshot.sh');
  });
});

describe('cleanEnvPath (env-var path CR/LF sanitizer)', () => {
  it('strips trailing CR/LF', () => {
    expect(cleanEnvPath('/home/u/knowledge\r')).toBe('/home/u/knowledge');
    expect(cleanEnvPath('/home/u/knowledge\r\n')).toBe('/home/u/knowledge');
  });
  it('strips a mid-string CR', () => {
    expect(cleanEnvPath('/a\r/b')).toBe('/a/b');
  });
  it('is a no-op on a clean path and returns "" for null/undefined', () => {
    expect(cleanEnvPath('/clean/path')).toBe('/clean/path');
    expect(cleanEnvPath(undefined)).toBe('');
    expect(cleanEnvPath(null)).toBe('');
  });
});
