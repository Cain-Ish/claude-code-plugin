import { describe, it, expect } from 'vitest';
import { toBashPath } from './dream.js';

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
});
