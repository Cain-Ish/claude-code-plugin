import { describe, it, expect, afterEach } from 'vitest';
import { isAbsolute, join } from 'path';
import { homedir, tmpdir } from 'os';
import { promises as fsp, mkdtempSync } from 'fs';
import { toBashPath, buildSnapshotArgs, resolveBashExePure, brainDir, dreamStatus, dreamDiscard, dreamCancel, dreamCreate } from './dream.js';
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

describe('buildSnapshotArgs', () => {
  it('defaults scope to the active project when none requested', () => {
    expect(buildSnapshotArgs({}, 'proja')).toEqual(['--slug', 'proja', '--max-count', '50']);
  });
  it('omits --slug for the explicit "all" opt-out', () => {
    expect(buildSnapshotArgs({ transcript_filter: { project_slug: 'all' } }, 'proja')).toEqual(['--max-count', '50']);
  });
  it('uses an explicit project_slug verbatim', () => {
    expect(buildSnapshotArgs({ transcript_filter: { project_slug: 'other' } }, 'proja')).toEqual(['--slug', 'other', '--max-count', '50']);
  });
  it('falls back to all transcripts when there is no active slug and none requested', () => {
    expect(buildSnapshotArgs({}, undefined)).toEqual(['--max-count', '50']);
  });
  it('clamps max_count to 100', () => {
    expect(buildSnapshotArgs({ transcript_filter: { max_count: 500 } }, undefined)).toEqual(['--max-count', '100']);
  });
});

describe('buildSnapshotArgs — family', () => {
  it('emits one --slug per family member (sorted)', () => {
    const args = { transcript_filter: { family: true } };
    const fam = new Set(['acme', 'acme__api', 'acme__web']);
    expect(buildSnapshotArgs(args, 'acme__api', fam)).toEqual(
      ['--slug', 'acme', '--slug', 'acme__api', '--slug', 'acme__web', '--max-count', '50']);
  });
  it('ignores the family set when family flag is not set (leaf default)', () => {
    const fam = new Set(['acme', 'acme__api', 'acme__web']);
    expect(buildSnapshotArgs({}, 'acme__api', fam)).toEqual(['--slug', 'acme__api', '--max-count', '50']);
  });
  it('"all" opt-out still wins over family', () => {
    const fam = new Set(['acme', 'acme__api']);
    expect(buildSnapshotArgs({ transcript_filter: { project_slug: 'all', family: true } }, 'acme__api', fam))
      .toEqual(['--max-count', '50']);
  });
});

describe('dreamCreate — transcript_filter.project_slug validation (review follow-up)', () => {
  // project_slug reaches dream-snapshot.sh's --slug and, before the D182 shell-side fix,
  // was matched by building it into a regex alternation — a value shaped like a regex
  // (".*") could act as an unintended wildcard. Reject it at the MCP boundary with the
  // same validateSlug charset guard every other slug-shaped arg gets, before it is ever
  // handed to the shell.
  it('rejects a regex-shaped project_slug (".*") without touching the filesystem', async () => {
    const result = await dreamCreate({ transcript_filter: { project_slug: '.*' } });
    expect(result.ok).toBe(false);
    expect(result.dream).toBeNull();
    expect(result.reason).toMatch(/invalid transcript_filter\.project_slug/);
  });
  it('still accepts the "all" cross-project sentinel (not slug-validated)', () => {
    // buildSnapshotArgs already covers "all" behavior; this just documents that dreamCreate's
    // new guard does not reject the one non-slug-shaped value the field is allowed to carry.
    expect(buildSnapshotArgs({ transcript_filter: { project_slug: 'all' } }, 'proja')).toEqual(['--max-count', '50']);
  });
});

describe('resolveBashExePure (win32 WSL-shadow fix)', () => {
  const noExist = (_p: string) => false;

  it('returns "bash" on non-win32 regardless of what exists', () => {
    const exists = (_p: string) => true; // everything exists — still not win32
    expect(resolveBashExePure('linux', exists, {})).toBe('bash');
    expect(resolveBashExePure('darwin', exists, {})).toBe('bash');
  });

  it('returns the first existing candidate on win32 (default PROGRAMFILES)', () => {
    // Simulate only C:\Program Files\Git\bin\bash.exe present
    const exists = (p: string) => p === 'C:\\Program Files\\Git\\bin\\bash.exe';
    expect(resolveBashExePure('win32', exists, {})).toBe('C:\\Program Files\\Git\\bin\\bash.exe');
  });

  it('returns a custom PROGRAMFILES path when set in env', () => {
    const env = { PROGRAMFILES: 'D:\\ProgramFiles' };
    const exists = (p: string) => p === 'D:\\ProgramFiles\\Git\\bin\\bash.exe';
    expect(resolveBashExePure('win32', exists, env)).toBe('D:\\ProgramFiles\\Git\\bin\\bash.exe');
  });

  it('falls through to x86 candidate when PROGRAMFILES candidate absent', () => {
    const env = { PROGRAMFILES: 'C:\\Program Files' };
    const exists = (p: string) => p === 'C:\\Program Files (x86)\\Git\\bin\\bash.exe';
    expect(resolveBashExePure('win32', exists, env)).toBe('C:\\Program Files (x86)\\Git\\bin\\bash.exe');
  });

  it('falls through to LOCALAPPDATA candidate when earlier candidates absent', () => {
    const env = { LOCALAPPDATA: 'C:\\Users\\u\\AppData\\Local' };
    const target = 'C:\\Users\\u\\AppData\\Local\\Programs\\Git\\bin\\bash.exe';
    const exists = (p: string) => p === target;
    expect(resolveBashExePure('win32', exists, env)).toBe(target);
  });

  it('falls back to "bash" on win32 when no candidate exists (no git-bash installed)', () => {
    expect(resolveBashExePure('win32', noExist, {})).toBe('bash');
  });

  it('probe order: PROGRAMFILES wins over x86 when both exist', () => {
    // Both present; must return the PROGRAMFILES one (first in probe order)
    const env = { PROGRAMFILES: 'C:\\Program Files' };
    const exists = (p: string) =>
      p === 'C:\\Program Files\\Git\\bin\\bash.exe' ||
      p === 'C:\\Program Files (x86)\\Git\\bin\\bash.exe';
    expect(resolveBashExePure('win32', exists, env)).toBe('C:\\Program Files\\Git\\bin\\bash.exe');
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

describe('brainDir() home resolution (Windows HOME-unset regression)', () => {
  const origEnv: Record<string, string | undefined> = {};

  afterEach(() => {
    // restore any env vars touched in these tests
    for (const k of ['SB_BRAIN_DIR', 'BRAIN_DIR']) {
      if (origEnv[k] === undefined) delete process.env[k];
      else process.env[k] = origEnv[k];
    }
  });

  it('returns an ABSOLUTE path when SB_BRAIN_DIR and BRAIN_DIR are unset (the Windows HOME bug)', () => {
    origEnv['SB_BRAIN_DIR'] = process.env['SB_BRAIN_DIR'];
    origEnv['BRAIN_DIR'] = process.env['BRAIN_DIR'];
    delete process.env['SB_BRAIN_DIR'];
    delete process.env['BRAIN_DIR'];

    const result = brainDir();
    // Regression assertion: NEVER a relative path when env vars are absent
    expect(isAbsolute(result)).toBe(true);
    // Must point inside the user home dir (os.homedir())
    expect(result).toBe(homedir() + require('path').sep + '.second-brain');
  });

  it('SB_BRAIN_DIR takes precedence over BRAIN_DIR and os.homedir()', () => {
    origEnv['SB_BRAIN_DIR'] = process.env['SB_BRAIN_DIR'];
    origEnv['BRAIN_DIR'] = process.env['BRAIN_DIR'];
    process.env['SB_BRAIN_DIR'] = '/custom/sb-brain';
    process.env['BRAIN_DIR'] = '/other/brain';

    expect(brainDir()).toBe('/custom/sb-brain');
  });

  it('BRAIN_DIR takes precedence over os.homedir() when SB_BRAIN_DIR is unset', () => {
    origEnv['SB_BRAIN_DIR'] = process.env['SB_BRAIN_DIR'];
    origEnv['BRAIN_DIR'] = process.env['BRAIN_DIR'];
    delete process.env['SB_BRAIN_DIR'];
    process.env['BRAIN_DIR'] = '/custom/brain';

    expect(brainDir()).toBe('/custom/brain');
  });
});

// D057-sibling: `dream_id` was joined straight into filesystem paths across every dream_* tool
// (including a recursive fs.rm in dreamDiscard) with no validation — 'dream_id:"../../outside"'
// could read a status.json outside the dreams dir, or delete an arbitrary directory's
// staging/transcripts subfolders. readStatus (the shared choke point) now runs
// validateSlug+assertWithin before ever touching the filesystem.
describe('dream_id path-traversal guard (D057-sibling)', () => {
  let brain = '';
  let outside = '';

  afterEach(async () => {
    delete process.env.SB_BRAIN_DIR;
    await fsp.rm(brain, { recursive: true, force: true }).catch(() => {});
    await fsp.rm(outside, { recursive: true, force: true }).catch(() => {});
  });

  async function plantOutsideDream(): Promise<{ brainRoot: string; outsideDreamDir: string }> {
    const root = mkdtempSync(join(tmpdir(), 'dream-guard-'));
    brain = join(root, 'brain');
    outside = join(root, 'outside');
    const outsideDreamDir = join(outside, 'drm_evil');
    await fsp.mkdir(join(brain, 'dreams'), { recursive: true });
    await fsp.mkdir(outsideDreamDir, { recursive: true });
    await fsp.writeFile(
      join(outsideDreamDir, 'status.json'),
      JSON.stringify({ id: 'drm_evil', status: 'completed', archived_at: null, outputs: {} })
    );
    await fsp.mkdir(join(outsideDreamDir, 'staging'), { recursive: true });
    await fsp.writeFile(join(outsideDreamDir, 'staging', 'XYZZYMARKER.md'), 'secret outside the dreams dir');
    process.env.SB_BRAIN_DIR = brain;
    return { brainRoot: brain, outsideDreamDir };
  }

  it('dreamStatus rejects a traversal dream_id instead of reading the outside status.json', async () => {
    await plantOutsideDream();
    const res = await dreamStatus({ dream_id: '../outside/drm_evil' });
    expect(res.ok).toBe(false);
    expect(res.dream).toBeNull();
  });

  it('dreamCancel rejects a traversal dream_id', async () => {
    await plantOutsideDream();
    const res = await dreamCancel({ dream_id: '../outside/drm_evil' });
    expect(res.ok).toBe(false);
  });

  it('dreamDiscard rejects a traversal dream_id and never touches the outside directory', async () => {
    const { outsideDreamDir } = await plantOutsideDream();
    const res = await dreamDiscard({ dream_id: '../outside/drm_evil' });
    expect(res.ok).toBe(false);
    // The outside staging dir (and its secret file) must survive untouched — proof the
    // recursive fs.rm never ran against it.
    await expect(fsp.readFile(join(outsideDreamDir, 'staging', 'XYZZYMARKER.md'), 'utf-8'))
      .resolves.toContain('secret outside the dreams dir');
  });
});
