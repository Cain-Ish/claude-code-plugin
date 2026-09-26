import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { spawnSync } from 'child_process';
import {
  installStatusline, uninstallStatusline, shimPath, statuslineCommand, parseOurCommand, cacheBaseOf, validName, buddyName,
} from './buddy-config.js';

// `sb buddy install` edits the user's own settings.json — the one file here that is not ours. Its
// trust rule: a chained command is only ever read back from the settings command itself, never
// from buddy.json (unguarded data).
describe('buddy statusLine install / uninstall', () => {
  let root: string, brain: string, cfgDir: string, cache: string;
  const settings = () => JSON.parse(readFileSync(join(cfgDir, 'settings.json'), 'utf-8'));
  const buddy = () => JSON.parse(readFileSync(join(brain, 'buddy.json'), 'utf-8'));
  const backups = () => readdirSync(cfgDir).filter((f) => f.startsWith('settings.json.bak-'));
  const put = (o: unknown) => writeFileSync(join(cfgDir, 'settings.json'), JSON.stringify(o));
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'sb-buddy-install-'));
    brain = join(root, 'brain'); cfgDir = join(root, 'claude'); mkdirSync(cfgDir, { recursive: true });
    cache = join(cfgDir, 'plugins', 'cache', 'mkt', 'second-brain', '0.52.0');
    process.env.CLAUDE_CONFIG_DIR = cfgDir;
  });
  afterEach(() => { delete process.env.CLAUDE_CONFIG_DIR; rmSync(root, { recursive: true, force: true }); });

  it('chains an existing statusline (keeping its fields), sets refreshInterval 1 and react consent, backs up once', async () => {
    put({ theme: 'dark', statusLine: { type: 'command', command: 'echo prev', padding: 2 } });
    const r = await installStatusline(brain, cache);
    const s = settings();
    expect(s.theme).toBe('dark');
    expect(s.statusLine).toMatchObject({ type: 'command', padding: 2, refreshInterval: 1 });
    expect(s.statusLine.command).toBe(statuslineCommand(brain, 'echo prev'));
    expect(r).toMatchObject({ chained: 'echo prev', changed: true });
    expect(buddy().react).toBe(true);
    expect(backups()).toHaveLength(1);
    expect(existsSync(shimPath(brain))).toBe(true);
    const again = await installStatusline(brain, cache);          // idempotent
    expect(again).toMatchObject({ changed: false, backup: null });
    expect(backups()).toHaveLength(1);
  });

  it('reads the chain from settings.json, never from buddy.json (a tampered or missing data file changes nothing)', async () => {
    put({ statusLine: { type: 'command', command: 'echo real' } });
    await installStatusline(brain, cache);
    writeFileSync(join(brain, 'buddy.json'), JSON.stringify({ chain: 'echo TAMPERED', prev_statusline: { type: 'command', command: 'echo TAMPERED', evil: 1 } }));
    await installStatusline(brain, cache);
    expect(settings().statusLine.command).toBe(statuslineCommand(brain, 'echo real'));
    rmSync(join(brain, 'buddy.json'));                           // unreadable/missing data file
    await installStatusline(brain, cache);
    expect(settings().statusLine.command).toBe(statuslineCommand(brain, 'echo real'));
    writeFileSync(join(brain, 'buddy.json'), JSON.stringify({ prev_statusline: { type: 'command', command: 'echo TAMPERED', padding: 9, evil: 1 } }));
    const u = await uninstallStatusline(brain);
    expect(u).toMatchObject({ restored: 'echo real', changed: true });
    expect(settings().statusLine).toEqual({ type: 'command', command: 'echo real' });   // mismatched record: no fields taken
  });

  it('upgrades a 0.51.0 install in place (double-quoted shim, no refreshInterval), keeping padding and the chain', async () => {
    const old = `SB_BUDDY_CHAIN='echo prev' bash "${shimPath(brain).replace(/\\/g, '/')}"`;
    put({ statusLine: { type: 'command', command: old, padding: 1 } });
    const r = await installStatusline(brain, cache);
    expect(r).toMatchObject({ changed: true, chained: 'echo prev' });
    expect(r.backup).not.toBeNull();
    expect(settings().statusLine).toEqual({ type: 'command', command: statuslineCommand(brain, 'echo prev'), padding: 1, refreshInterval: 1 });
  });

  it('respects a user-set refreshInterval on our own line', async () => {
    put({ statusLine: { type: 'command', command: statuslineCommand(brain, null), refreshInterval: 5 } });
    const r = await installStatusline(brain, cache);
    expect(r.changed).toBe(false);
    expect(settings().statusLine.refreshInterval).toBe(5);
  });

  it('refuses a hand-edited command that runs the renderer in a form it cannot parse — with NO side effects (no consent, no shim)', async () => {
    put({ statusLine: { type: 'command', command: 'bash ~/x/buddy-statusline.sh | tee log' } });
    await expect(installStatusline(brain, cache)).rejects.toThrow(/hand-edited/);
    expect(existsSync(join(brain, 'buddy.json'))).toBe(false);
    expect(existsSync(shimPath(brain))).toBe(false);
  });

  it('an unreadable settings.json (any error but ENOENT) is never treated as absent — install and uninstall throw, nothing written', async () => {
    mkdirSync(join(cfgDir, 'settings.json'));                      // EISDIR: exists, cannot be read as a file
    await expect(installStatusline(brain, cache)).rejects.toThrow(/cannot read .*nothing changed/);
    await expect(uninstallStatusline(brain)).rejects.toThrow(/cannot read/);
    expect(backups()).toHaveLength(0);
    expect(existsSync(join(brain, 'buddy.json'))).toBe(false);
    expect(existsSync(shimPath(brain))).toBe(false);
  });

  it('a broken buddy.json fails install before settings.json is touched, and is never replaced by a patch', async () => {
    put({ statusLine: { type: 'command', command: 'echo prev' } });
    const before = readFileSync(join(cfgDir, 'settings.json'), 'utf-8');
    mkdirSync(brain, { recursive: true });
    writeFileSync(join(brain, 'buddy.json'), '{"name":"Mo", "mute": tru');
    await expect(installStatusline(brain, cache)).rejects.toThrow(/buddy\.json is not valid JSON/);
    expect(readFileSync(join(cfgDir, 'settings.json'), 'utf-8')).toBe(before);
    expect(readFileSync(join(brain, 'buddy.json'), 'utf-8')).toBe('{"name":"Mo", "mute": tru');
  });

  it('always pins SB_BUDDY_CHAIN (empty = no chain) so an inherited env value is never run; older forms upgrade in place', async () => {
    expect(statuslineCommand(brain, null).startsWith("SB_BUDDY_CHAIN='' bash '")).toBe(true);
    expect(parseOurCommand(statuslineCommand(brain, null))).toEqual({ chain: null });
    const legacy = `bash '${shimPath(brain).replace(/\\/g, '/')}'`;   // 0.52.0 form: no env at all
    expect(parseOurCommand(legacy)).toEqual({ chain: null });
    put({ statusLine: { type: 'command', command: legacy, refreshInterval: 1 } });
    const r = await installStatusline(brain, cache);
    expect(r.changed).toBe(true);
    expect(settings().statusLine.command).toBe(statuslineCommand(brain, null));
  });

  it('uninstall refuses a hand-edited buddy line with no side effects (shim and consent stay)', async () => {
    await installStatusline(brain, cache);
    put({ statusLine: { type: 'command', command: `NO_COLOR=1 bash '${shimPath(brain).replace(/\\/g, '/')}'` } });
    await expect(uninstallStatusline(brain)).rejects.toThrow(/hand-edited/);
    expect(existsSync(shimPath(brain))).toBe(true);
    expect(buddy().react).toBe(true);
  });

  it('uninstall with no chained line removes statusLine and keeps every other key', async () => {
    put({ theme: 'dark', model: 'opus' });
    await installStatusline(brain, cache);
    await uninstallStatusline(brain);
    expect(settings()).toEqual({ theme: 'dark', model: 'opus' });
  });

  it.skipIf(process.platform === 'win32')('keeps settings.json mode (0600 stays 0600) and writes the backup owner-only', async () => {
    const { chmodSync, statSync } = await import('fs');
    put({ env: { TOKEN: 'x' } });
    chmodSync(join(cfgDir, 'settings.json'), 0o600);
    await installStatusline(brain, cache);
    expect(statSync(join(cfgDir, 'settings.json')).mode & 0o777).toBe(0o600);
    expect(statSync(join(cfgDir, backups()[0])).mode & 0o777).toBe(0o600);
  });

  it('uninstall restores the chained line with its recorded fields, clears consent, drops the shim', async () => {
    put({ statusLine: { type: 'command', command: 'echo prev', padding: 2 } });
    await installStatusline(brain, cache);
    const u = await uninstallStatusline(brain);
    expect(u).toMatchObject({ restored: 'echo prev', changed: true });
    expect(settings().statusLine).toEqual({ type: 'command', command: 'echo prev', padding: 2 });
    expect(buddy().react).toBeUndefined();
    expect(existsSync(shimPath(brain))).toBe(false);
    const again = await uninstallStatusline(brain);             // nothing installed: nothing changes
    expect(again).toMatchObject({ changed: false, restored: null });
    expect(settings().statusLine).toEqual({ type: 'command', command: 'echo prev', padding: 2 });
  });

  it('parseOurCommand inverts statuslineCommand, quotes included', () => {
    for (const chain of [null, 'echo prev', `printf 'a'"b" $HOME`, `a'b'c`]) {
      expect(parseOurCommand(statuslineCommand(brain, chain))).toEqual({ chain });
    }
    expect(parseOurCommand('echo not-ours')).toBeNull();
    expect(parseOurCommand('bash "/x/y/other.sh"')).toBeNull();
  });

  it('cacheBaseOf finds the marketplace dir of a cached plugin root (any config dir), null for a dev checkout', () => {
    expect(cacheBaseOf('/h/.claude/plugins/cache/mkt/second-brain/0.52.0')).toBe('/h/.claude/plugins/cache/mkt/second-brain');
    expect(cacheBaseOf('C:\\cfg\\plugins\\cache\\mkt\\second-brain\\0.52.0')).toBe('C:\\cfg\\plugins\\cache\\mkt\\second-brain');
    expect(cacheBaseOf('/work/claude-code-plugin')).toBeNull();
  });

  it('names: printable only; an unprintable stored name falls back to Kapi', () => {
    expect(validName('Kapi')).toBe(true);
    expect(validName('Capy Bara')).toBe(true);
    expect(validName('a\u001b]0;x\u0007')).toBe(false);
    expect(validName('ab\u202ecd')).toBe(false);
    expect(validName('x'.repeat(15))).toBe(false);
    expect(buddyName({ name: 'bad\u001bname' })).toBe('Kapi');
  });

  // The shim runs every second: newest version NUMERICALLY (0.52.0 > 0.9.0 > 0.51.0 lexically would
  // pick 0.9.0), only within the marketplace the install ran from, builtins only, and the renderer
  // SOURCED — not exec'd (one bash start per tick, not two).
  it.skipIf(spawnSync('bash', ['-c', 'exit 0']).status !== 0)('shim: numeric newest within the install marketplace, sourced', async () => {
    const mk = (mkt: string, v: string) => {
      const d = join(cfgDir, 'plugins', 'cache', mkt, 'second-brain', v, 'scripts');
      mkdirSync(d, { recursive: true });
      // `_r` is the shim's own variable: the renderer sees it only when the shim SOURCES it.
      writeFileSync(join(d, 'buddy-statusline.sh'), `printf 'renderer %s %s %s\\n' '${mkt}' '${v}' "\${_r:+sourced}"\n`);
    };
    for (const v of ['0.9.0', '0.51.0', '0.52.0', 'unknown']) mk('mkt', v);
    mk('aaa-other', '9.9.9');                                     // another marketplace's "second-brain"
    put({});
    await installStatusline(brain, cache);
    const shim = readFileSync(shimPath(brain), 'utf-8');
    expect(shim).not.toMatch(/\bls\b|\bsort\b|exec bash/);
    const run = () => spawnSync('bash', [shimPath(brain).replace(/\\/g, '/')], { env: { ...process.env }, encoding: 'utf-8' });
    expect(run().stdout.trim()).toBe('renderer mkt 0.52.0 sourced');
    // a dev checkout (not in the cache) is used as-is
    const dev = join(root, 'dev'); mkdirSync(join(dev, 'scripts'), { recursive: true });
    writeFileSync(join(dev, 'scripts', 'buddy-statusline.sh'), `printf 'dev %s\\n' "\${_r:+sourced}"\n`);
    await installStatusline(brain, dev);
    expect(run().stdout.trim()).toBe('dev sourced');
    // nothing to resolve (marketplace pruned or renamed): a visible hint, never a silently blank statusline
    rmSync(dev, { recursive: true, force: true });
    rmSync(join(cfgDir, 'plugins'), { recursive: true, force: true });
    expect(run().stdout).toMatch(/no second-brain renderer found — run \/second-brain:buddy install/);
  });
});
