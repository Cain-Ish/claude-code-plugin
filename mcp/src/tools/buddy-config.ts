// buddy-config — ~/.second-brain/buddy.json (name, mute, sprite, react) and the statusLine install.
//
// The buddy is one fixed capybara (2026-09-24). The 0.51.0 roll of species/rarity/eye/hat/shiny
// from a hash of the Claude account id is gone: the buddy is the visible layer
// between Claude and the knowledge base, and none of those fields carried memory state. A
// leftover `identity` block from a 0.51.0 hatch is dropped by `sb buddy` (dropStaleIdentity).
//
// Trust boundary: ~/.claude/settings.json is the user's audited file; buddy.json is unguarded data.
// So a chained statusline is only ever read back from the settings command itself (parseOurCommand),
// never from buddy.json — a data file must not be able to put a command into settings.json.
import { promises as fs } from 'fs';
import { join, dirname } from 'path';
import { homedir } from 'os';
import { cleanEnvPath } from '../path-guard.js';

export const DEFAULT_NAME = 'Kapi';

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === 'object' && !Array.isArray(v);
const errCode = (e: unknown): string | undefined => (e as NodeJS.ErrnoException)?.code;

/** The card `sb buddy` prints: the capybara at rest (native frame 0) and its name; no I/O. */
export function renderCard(name: string): string {
  return ['    n______n', '   ( ·    · )', '   (   oo   )', '    `------´', `   ${name} — capybara`].join('\n');
}

/** buddy.json, {} when absent. Present but unreadable, invalid JSON or not an object → throws. */
async function readConfigStrict(brainDir: string): Promise<Obj> {
  const file = join(brainDir, 'buddy.json');
  let raw: string;
  try { raw = await fs.readFile(file, 'utf-8'); } catch (e) {
    if (errCode(e) === 'ENOENT') return {};
    throw new Error(`cannot read ${file} (${errCode(e) ?? e})`);
  }
  if (!raw.trim()) return {};
  let j: unknown;
  try { j = JSON.parse(raw); } catch { throw new Error(`${file} is not valid JSON — fix or delete it, then re-run`); }
  if (!isObj(j)) throw new Error(`${file} is not a JSON object — fix or delete it, then re-run`);
  return j;
}

/** Lenient read for display: a broken buddy.json renders as defaults (patchConfig refuses it). */
export async function readConfig(brainDir: string): Promise<Obj> {
  try { return await readConfigStrict(brainDir); } catch { return {}; }
}

/** Shallow-merge `patch` into buddy.json (a `null` value deletes the key); tmp+rename. A broken
 *  buddy.json throws instead of being replaced by the patch alone (name/mute/prev_statusline lost). */
export async function patchConfig(brainDir: string, patch: Obj): Promise<Obj> {
  const cfg = await readConfigStrict(brainDir);
  for (const [k, v] of Object.entries(patch)) { if (v === null) delete cfg[k]; else cfg[k] = v; }
  await fs.mkdir(brainDir, { recursive: true });
  const file = join(brainDir, 'buddy.json');
  const tmp = `${file}.tmp.${process.pid}`;
  try {
    await fs.writeFile(tmp, JSON.stringify(cfg, null, 2) + '\n', 'utf-8');
    await fs.rename(tmp, file);
  } catch (e) { await fs.rm(tmp, { force: true }).catch(() => undefined); throw e; }   // the original error wins
  return cfg;
}

/** Control and format characters (bidi, zero-width, tags) — never part of a name the terminal shows. */
const UNPRINTABLE = /[\p{Cc}\p{Cf}\u2028\u2029]/u;
export function validName(name: string): boolean { return name.length >= 1 && name.length <= 14 && !UNPRINTABLE.test(name); }

/** Display name: stored (printable) name > DEFAULT_NAME. */
export function buddyName(cfg: Record<string, unknown>): string {
  const n = typeof cfg.name === 'string' ? cfg.name.trim().slice(0, 14) : '';
  return n && validName(n) ? n : DEFAULT_NAME;
}

/** Remove a 0.51.0 `identity` block (rarity/species/eye/hat/shiny/seed_source); true if one was there. */
export async function dropStaleIdentity(brainDir: string): Promise<boolean> {
  if (!('identity' in (await readConfig(brainDir)))) return false;
  await patchConfig(brainDir, { identity: null });
  return true;
}

// ─── statusLine install (user-level settings.json; plugins cannot declare it) ──────────────
function claudeConfigDir(): string { return cleanEnvPath(process.env.CLAUDE_CONFIG_DIR) || join(homedir(), '.claude'); }
export function settingsPath(): string { return join(claudeConfigDir(), 'settings.json'); }

const posix = (p: string) => p.replace(/\\/g, '/');
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;   // single-quote for bash
const unshq = (s: string) => s.replace(/'\\''/g, `'`);

/** The stable shim path; settings.json points here, never at a version-pinned cache dir. */
export function shimPath(brainDir: string): string { return join(brainDir, 'bin', 'buddy-statusline.sh'); }

/** The settings.json command: chained statusline as env, then the shim — both single-quoted. The
 *  env is ALWAYS set (empty = no chain): the renderer runs $SB_BUDDY_CHAIN, and an inherited value
 *  (a settings `env` block, a parent shell) must never become a command nobody audited. */
export function statuslineCommand(brainDir: string, chain: string | null): string {
  return `SB_BUDDY_CHAIN=${shq(chain ?? '')} bash ${shq(posix(shimPath(brainDir)))}`;
}

/** Inverse of statuslineCommand, for this and the older forms (no env; the 0.51.0 `bash "<shim>"`).
 *  null = not ours; chain null = none (an empty SB_BUDDY_CHAIN is none). */
export function parseOurCommand(command: string): { chain: string | null } | null {
  const m = /^(?:SB_BUDDY_CHAIN='((?:[^']|'\\'')*)' )?bash (?:"([^"$`\\]*)"|'((?:[^']|'\\'')*)')$/.exec(command);
  if (!m) return null;
  const path = m[2] ?? unshq(m[3] ?? '');
  if (!/[\\/]buddy-statusline\.sh$/.test(path)) return null;
  return { chain: m[1] ? unshq(m[1]) : null };
}

/** The marketplace's second-brain dir for a plugin root inside Claude Code's plugin cache, else null. */
export function cacheBaseOf(pluginRoot: string): string | null {
  const m = /^(.*[\\/]plugins[\\/]cache[\\/][^\\/]+[\\/]second-brain)[\\/][^\\/]+[\\/]?$/.exec(pluginRoot);
  return m ? m[1] : null;
}

/** Shim body: resolves the NEWEST installed version's renderer at run time, so a plugin update
 *  never leaves a dead pinned path. Scoped to the marketplace the install ran from (another
 *  marketplace's "second-brain" is not this plugin); a dev checkout is used as-is; with neither
 *  known, every marketplace under ${CLAUDE_CONFIG_DIR:-~/.claude}. It runs every second (the
 *  animation tick), so: bash builtins only — versions compared numerically (0.52.0 > 0.9.0) — and
 *  the renderer is SOURCED, not exec'd: one bash start per tick, not two. */
export function shimBody(devRoot: string | null, cacheBase: string | null): string {
  const glob = cacheBase ? `${shq(posix(cacheBase))}/*` : `"$_cfg"/plugins/cache/*/second-brain/*`;
  return `#!/bin/bash
# buddy-statusline shim — generated by \`sb buddy install\` (do not hand-edit). Stable path that
# survives plugin upgrades: resolves the newest installed second-brain version's renderer and
# sources it with this process's stdin (the statusline JSON) and env (SB_BUDDY_CHAIN, COLUMNS).
set -u
_r=""; _rk=-1; _dev=${devRoot ? shq(posix(devRoot)) : "''"}
_cfg="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; _cfg="\${_cfg//\\\\//}"   # C:\\x → C:/x: a backslash path never globs
if [ -n "$_dev" ] && [ -f "$_dev/scripts/buddy-statusline.sh" ]; then _r="$_dev/scripts/buddy-statusline.sh"
else
  for _d in ${glob}; do
    [[ "\${_d##*/}" =~ ^([0-9]+)\\.([0-9]+)\\.([0-9]+)$ ]] && [ -f "$_d/scripts/buddy-statusline.sh" ] || continue
    _k=$(( 10#\${BASH_REMATCH[1]} * 1000000 + 10#\${BASH_REMATCH[2]} * 1000 + 10#\${BASH_REMATCH[3]} ))
    [ "$_k" -gt "$_rk" ] && { _rk=$_k; _r="$_d/scripts/buddy-statusline.sh"; }
  done
fi
# fail loud, not blank: a pruned or renamed marketplace would otherwise just make the buddy vanish
[ -n "$_r" ] || { printf 'buddy: no second-brain renderer found — run /second-brain:buddy install\\n'; exit 0; }
. "$_r"
`;
}

export interface InstallResult { settings: string; backup: string | null; chained: string | null; command: string; shim: string; changed: boolean }

/** refreshInterval re-runs the statusLine every N seconds while idle — the animation tick
 *  (Claude Code's minimum is 1; the native /buddy ticked every 500 ms). */
const REFRESH_S = 1;

/** settings.json, {raw:'', settings:{}} ONLY when absent: any other read error (EACCES, a Windows
 *  sharing lock) throws — treating it as "no file" once rewrote a user's settings with no backup. */
async function readSettings(file: string): Promise<{ raw: string; settings: Obj }> {
  let raw: string;
  try { raw = await fs.readFile(file, 'utf-8'); } catch (e) {
    if (errCode(e) === 'ENOENT') return { raw: '', settings: {} };
    throw new Error(`cannot read ${file} (${errCode(e) ?? e}) — nothing changed`);
  }
  if (!raw.trim()) return { raw, settings: {} };
  const j = JSON.parse(raw);                          // throws on a broken file: never clobber it
  if (!isObj(j)) throw new Error(`${file} is not a JSON object`);
  return { raw, settings: j };
}

/** Replace settings.json's real target (a dotfiles symlink stays a symlink) keeping its mode (a 0600
 *  file holding env tokens stays 0600), and only if it still holds `expectedRaw`: Claude Code or
 *  the user may have edited it since it was read, and that edit must not be silently lost. */
async function writeSettings(file: string, settings: Obj, expectedRaw: string): Promise<void> {
  let target = file;
  let mode: number | undefined;
  try { target = await fs.realpath(file); mode = (await fs.stat(target)).mode & 0o777; }
  catch (e) { if (errCode(e) !== 'ENOENT') throw e; }
  await fs.mkdir(dirname(target), { recursive: true });
  const tmp = `${target}.tmp.${process.pid}`;
  try {
    await fs.writeFile(tmp, JSON.stringify(settings, null, 2) + '\n', { encoding: 'utf-8', mode: mode ?? 0o666 });
    if (mode !== undefined) await fs.chmod(tmp, mode);   // writeFile's mode is masked by the umask
    let now = '';
    try { now = await fs.readFile(target, 'utf-8'); } catch (e) { if (errCode(e) !== 'ENOENT') throw e; }
    if (now !== expectedRaw) throw new Error(`${file} changed while sb buddy was editing it — nothing written; re-run`);
    await fs.rename(tmp, target);
  } catch (e) { await fs.rm(tmp, { force: true }).catch(() => undefined); throw e; }   // the original error wins
}

/** A timestamped copy of settings.json, owner-only (it may hold env tokens). */
async function backupSettings(file: string, raw: string): Promise<string> {
  const backup = `${file}.bak-${new Date().toISOString().replace(/[:.]/g, '-')}`;
  await fs.writeFile(backup, raw, { encoding: 'utf-8', mode: 0o600 });
  await fs.chmod(backup, 0o600);
  return backup;
}

/** Point settings.json's statusLine at the shim; an existing command is chained (line 1) and its
 *  other fields (padding …) kept. Idempotent; an older buddy install (no refreshInterval, no pinned
 *  SB_BUDDY_CHAIN, the 0.51.0 quoting, a stale shim) is upgraded in place, a user-set
 *  refreshInterval respected. Sets buddy.json react:true — installing is the consent for the
 *  two-way [buddy] line — only once the statusLine is really in place. */
export async function installStatusline(brainDir: string, pluginRoot: string): Promise<InstallResult> {
  const file = settingsPath();
  const { raw, settings } = await readSettings(file);
  await readConfigStrict(brainDir);   // a broken buddy.json fails here, before settings.json is touched
  const prev = isObj(settings.statusLine) ? settings.statusLine : undefined;
  const prevCmd = prev && prev.type === 'command' && typeof prev.command === 'string' ? prev.command : '';
  const parsed = prevCmd ? parseOurCommand(prevCmd) : null;
  if (!parsed && prevCmd.includes('buddy-statusline')) {
    throw new Error(`${file} statusLine runs buddy-statusline but is not the form sb buddy writes (hand-edited?) — fix or remove it, then re-run`);
  }
  const cacheBase = cacheBaseOf(pluginRoot);
  const shim = shimPath(brainDir);
  await fs.mkdir(join(brainDir, 'bin'), { recursive: true });
  await fs.writeFile(shim, shimBody(cacheBase ? null : pluginRoot, cacheBase), { encoding: 'utf-8', mode: 0o755 });

  const chained = parsed ? parsed.chain : (prevCmd || null);
  const command = statuslineCommand(brainDir, chained);
  const keep = parsed && typeof prev?.refreshInterval === 'number' && prev.refreshInterval >= 1;
  const consent = { react: true, chain: null, identity: null };   // `chain`: 0.51.0 record, never read again
  if (parsed && prevCmd === command && keep) {
    await patchConfig(brainDir, consent);
    return { settings: file, backup: null, chained, command, shim, changed: false };
  }
  const backup = raw.trim() ? await backupSettings(file, raw) : null;
  settings.statusLine = { ...(prev ?? {}), type: 'command', command, refreshInterval: keep ? prev!.refreshInterval : REFRESH_S };
  await writeSettings(file, settings, raw);
  // prev_statusline: for uninstall, the padding etc. of the chained line (never its command).
  await patchConfig(brainDir, parsed ? consent : { ...consent, prev_statusline: prev ?? null });
  return { settings: file, backup, chained, command, shim, changed: true };
}

/** Remove the buddy statusLine; the chained command (read from the settings command itself) comes
 *  back, with the fields recorded at install only when that record's command matches it. The
 *  settings are rewritten FIRST: consent and the shim go only once nothing still runs the shim. */
export async function uninstallStatusline(brainDir: string): Promise<{ settings: string; restored: string | null; changed: boolean }> {
  const file = settingsPath();
  const { raw, settings } = await readSettings(file);
  const cfg = await readConfigStrict(brainDir);   // fail before settings.json is touched
  const cur = isObj(settings.statusLine) ? settings.statusLine : undefined;
  const curCmd = cur && typeof cur.command === 'string' ? cur.command : '';
  const parsed = curCmd ? parseOurCommand(curCmd) : null;
  if (!parsed && curCmd.includes('buddy-statusline')) {
    throw new Error(`${file} statusLine runs buddy-statusline but is not the form sb buddy writes (hand-edited?) — remove it by hand; nothing changed`);
  }
  const restored = parsed ? parsed.chain : null;
  if (parsed) {
    if (restored) {
      const rec = isObj(cfg.prev_statusline) ? cfg.prev_statusline : undefined;
      const next: Obj = { type: 'command', command: restored };
      if (rec && rec.command === restored) {
        for (const k of ['padding', 'refreshInterval'] as const) if (typeof rec[k] === 'number') next[k] = rec[k];
      }
      settings.statusLine = next;
    } else {
      delete settings.statusLine;
    }
    await writeSettings(file, settings, raw);
  }
  await patchConfig(brainDir, { react: null, chain: null, prev_statusline: null });
  try { await fs.unlink(shimPath(brainDir)); } catch (e) { if (errCode(e) !== 'ENOENT') throw e; }
  return { settings: file, restored, changed: !!parsed };
}
