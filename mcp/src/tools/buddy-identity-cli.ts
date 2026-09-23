#!/usr/bin/env node
// buddy-identity-cli — hatch (or re-read) the buddy's bones and cache them in ~/.second-brain/buddy.json.
//
// NOT on the statusline hot path: session-load.sh runs this ONCE, when buddy.json has no
// `identity` block, and the bash renderer reads the cached JSON with jq afterwards. The bones are a
// pure function of the seed, so the cache is only a startup-cost optimisation, never a source of
// truth — `--rehatch` recomputes and overwrites.
//
// Seed resolution (first hit wins; recorded as identity.seed_source):
//   1. --user-id <id>                              "arg"
//   2. $CLAUDE_CONFIG_DIR/.claude.json  or  ~/.claude.json  → .oauthAccount.accountUuid
//                                                   "account"   ← the native /buddy seed
//   3. "sb:" + os.hostname() + ":" + os.userInfo().username
//                                                   "fallback"  (no Claude login on this machine)
// Modes:  (default) print identity JSON   --write  merge into buddy.json (atomic)   --card  print card
//         --rehatch  recompute even if cached
import { promises as fs } from 'fs';
import { join } from 'path';
import { homedir, hostname, userInfo } from 'os';
import { resolveBrainDir } from '../brain-paths.js';
import { cleanEnvPath } from '../path-guard.js';
import { generateBones, renderCard, defaultName, type BuddyBones } from '../buddy-identity.js';

export type SeedSource = 'arg' | 'account' | 'fallback';
export interface BuddyIdentity extends BuddyBones { seed_source: SeedSource; hatched_at: string; default_name: string; version: 1 }

export async function resolveSeed(userIdArg?: string): Promise<{ seed: string; source: SeedSource }> {
  if (userIdArg && userIdArg.trim()) return { seed: userIdArg.trim(), source: 'arg' };
  const cfgDir = cleanEnvPath(process.env.CLAUDE_CONFIG_DIR) || homedir();
  for (const f of [join(cfgDir, '.claude.json'), join(homedir(), '.claude.json')]) {
    try {
      const j = JSON.parse(await fs.readFile(f, 'utf-8')) as { oauthAccount?: { accountUuid?: unknown } };
      const id = j?.oauthAccount?.accountUuid;
      if (typeof id === 'string' && /^[0-9a-f-]{16,64}$/i.test(id)) return { seed: id, source: 'account' };
    } catch { /* absent or unparsable — try the next */ }
  }
  let user = '';
  try { user = userInfo().username; } catch { /* some CI containers */ }
  return { seed: `sb:${hostname()}:${user}`, source: 'fallback' };
}

export function hatch(seed: string, source: SeedSource): BuddyIdentity {
  return { ...generateBones(seed), seed_source: source, hatched_at: new Date().toISOString(), default_name: defaultName(seed), version: 1 };
}

/** Merge `identity` into buddy.json without touching name/chain/mute/sprite; tmp+rename. */
export async function writeIdentity(brainDir: string, identity: BuddyIdentity): Promise<string> {
  const file = join(brainDir, 'buddy.json');
  let cfg: Record<string, unknown> = {};
  try { const j = JSON.parse(await fs.readFile(file, 'utf-8')); if (j && typeof j === 'object' && !Array.isArray(j)) cfg = j; } catch { /* fresh */ }
  cfg.identity = identity;
  await fs.mkdir(brainDir, { recursive: true });
  const tmp = `${file}.tmp.${process.pid}`;
  await fs.writeFile(tmp, JSON.stringify(cfg, null, 2) + '\n', 'utf-8');
  await fs.rename(tmp, file);
  return file;
}

export async function readConfig(brainDir: string): Promise<Record<string, unknown>> {
  try { const j = JSON.parse(await fs.readFile(join(brainDir, 'buddy.json'), 'utf-8')); if (j && typeof j === 'object' && !Array.isArray(j)) return j; } catch { /* fresh */ }
  return {};
}

/** Shallow-merge `patch` into buddy.json (a `null` value deletes the key); tmp+rename. */
export async function patchConfig(brainDir: string, patch: Record<string, unknown>): Promise<Record<string, unknown>> {
  const cfg = await readConfig(brainDir);
  for (const [k, v] of Object.entries(patch)) { if (v === null) delete cfg[k]; else cfg[k] = v; }
  await fs.mkdir(brainDir, { recursive: true });
  const file = join(brainDir, 'buddy.json');
  const tmp = `${file}.tmp.${process.pid}`;
  await fs.writeFile(tmp, JSON.stringify(cfg, null, 2) + '\n', 'utf-8');
  await fs.rename(tmp, file);
  return cfg;
}

/** Display name: stored name > identity.default_name > "buddy". */
export function buddyName(cfg: Record<string, unknown>, identity: BuddyIdentity | null): string {
  if (typeof cfg.name === 'string' && cfg.name.trim()) return cfg.name.trim().slice(0, 14);
  return identity?.default_name || 'buddy';
}

// ─── statusLine install (user-level settings.json; plugins cannot declare it) ──────────────
export function settingsPath(): string {
  const cfgDir = cleanEnvPath(process.env.CLAUDE_CONFIG_DIR) || join(homedir(), '.claude');
  return join(cfgDir, 'settings.json');
}

const posix = (p: string) => p.replace(/\\/g, '/');
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;   // single-quote for bash

/** The stable shim path; settings.json points here, never at a version-pinned cache dir. */
export function shimPath(brainDir: string): string { return join(brainDir, 'bin', 'buddy-statusline.sh'); }

/** The settings.json command: chained statusline (if any) as env, then the shim. */
export function statuslineCommand(brainDir: string, chain: string | null): string {
  const env = chain ? `SB_BUDDY_CHAIN=${shq(chain)} ` : '';
  return `${env}bash "${posix(shimPath(brainDir))}"`;
}

/** Shim body: resolves the NEWEST installed plugin version's renderer at run time (the
 *  install-extract-timer pattern), so a plugin update never leaves a dead pinned path. A dev
 *  checkout (a pluginRoot outside the plugin cache) is tried first. */
export function shimBody(devRoot: string | null): string {
  return `#!/bin/bash
# buddy-statusline shim — generated by \`sb buddy install\` (do not hand-edit). Stable path that
# survives plugin upgrades: resolves the newest installed second-brain version's renderer and
# execs it with this process's stdin (the statusline JSON) and env (SB_BUDDY_CHAIN, COLUMNS).
set -u
_r=""
for _base in ${devRoot ? `"${posix(devRoot)}"` : '""'} "$HOME"/.claude/plugins/cache/*/second-brain; do
  [ -n "$_base" ] && [ -d "$_base" ] || continue
  if [ -f "$_base/scripts/buddy-statusline.sh" ]; then _r="$_base/scripts/buddy-statusline.sh"; break; fi
  for _v in $(ls -1 "$_base" 2>/dev/null | { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }); do
    [ -f "$_base/$_v/scripts/buddy-statusline.sh" ] && _r="$_base/$_v/scripts/buddy-statusline.sh"
  done
  [ -n "$_r" ] && break
done
[ -n "$_r" ] || exit 0
exec bash "$_r"
`;
}

export interface InstallResult { settings: string; backup: string | null; chained: string | null; command: string; shim: string }

/** Point settings.json's statusLine at the shim; an existing command is chained (line 1). Idempotent. */
export async function installStatusline(brainDir: string, pluginRoot: string): Promise<InstallResult> {
  const file = settingsPath();
  let settings: Record<string, unknown> = {};
  let raw = '';
  try { raw = await fs.readFile(file, 'utf-8'); } catch { /* no settings yet */ }
  if (raw.trim()) {
    const j = JSON.parse(raw);                        // throws on a broken file: never clobber it
    if (!j || typeof j !== 'object' || Array.isArray(j)) throw new Error(`${file} is not a JSON object`);
    settings = j;
  }
  const inCache = /[\\/]\.claude[\\/]plugins[\\/]cache[\\/]/.test(pluginRoot);
  const shim = shimPath(brainDir);
  await fs.mkdir(join(brainDir, 'bin'), { recursive: true });
  await fs.writeFile(shim, shimBody(inCache ? null : pluginRoot), { encoding: 'utf-8', mode: 0o755 });
  const prev = settings.statusLine as { type?: string; command?: string } | undefined;
  const prevCmd = prev && prev.type === 'command' && typeof prev.command === 'string' ? prev.command : '';
  const ours = prevCmd.includes('buddy-statusline');
  const cfg = await readConfig(brainDir);
  let chained: string | null = ours ? (typeof cfg.chain === 'string' && cfg.chain ? cfg.chain : null) : (prevCmd || null);
  const command = statuslineCommand(brainDir, chained);
  if (prevCmd === command) return { settings: file, backup: null, chained, command, shim };   // already installed
  if (chained && !ours) await patchConfig(brainDir, { chain: chained });   // record for uninstall (never executed from here)
  let backup: string | null = null;
  if (raw.trim()) {
    backup = `${file}.bak-${new Date().toISOString().replace(/[:.]/g, '-')}`;
    await fs.writeFile(backup, raw, 'utf-8');
  }
  settings.statusLine = { type: 'command', command };
  await fs.mkdir(join(file, '..'), { recursive: true });
  const tmp = `${file}.tmp.${process.pid}`;
  await fs.writeFile(tmp, JSON.stringify(settings, null, 2) + '\n', 'utf-8');
  await fs.rename(tmp, file);
  return { settings: file, backup, chained, command, shim };
}

/** Remove the buddy statusLine; restore the chained command if one was recorded. */
export async function uninstallStatusline(brainDir: string): Promise<{ settings: string; restored: string | null }> {
  const file = settingsPath();
  let settings: Record<string, unknown> = {};
  let raw = '';
  try { raw = await fs.readFile(file, 'utf-8'); } catch { return { settings: file, restored: null }; }
  if (raw.trim()) settings = JSON.parse(raw);
  const cur = settings.statusLine as { command?: string } | undefined;
  if (!cur || typeof cur.command !== 'string' || !cur.command.includes('buddy-statusline')) return { settings: file, restored: null };
  const cfg = await readConfig(brainDir);
  const restored = typeof cfg.chain === 'string' && cfg.chain ? cfg.chain : null;
  if (restored) settings.statusLine = { type: 'command', command: restored }; else delete settings.statusLine;
  await patchConfig(brainDir, { chain: null });
  const tmp = `${file}.tmp.${process.pid}`;
  await fs.writeFile(tmp, JSON.stringify(settings, null, 2) + '\n', 'utf-8');
  await fs.rename(tmp, file);
  try { await fs.unlink(shimPath(brainDir)); } catch { /* absent */ }
  return { settings: file, restored };
}

export async function readCached(brainDir: string): Promise<BuddyIdentity | null> {
  try {
    const j = JSON.parse(await fs.readFile(join(brainDir, 'buddy.json'), 'utf-8')) as { identity?: BuddyIdentity };
    return j?.identity && typeof j.identity.species === 'string' ? j.identity : null;
  } catch { return null; }
}

async function main(argv: string[]): Promise<number> {
  const flag = (n: string) => argv.includes(n);
  const val = (n: string) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : undefined; };
  const brainDir = resolveBrainDir(val('--brain-dir'));
  let identity = flag('--rehatch') ? null : await readCached(brainDir);
  if (!identity) {
    const { seed, source } = await resolveSeed(val('--user-id'));
    identity = hatch(seed, source);
    if (flag('--write') || flag('--rehatch')) await writeIdentity(brainDir, identity);
  }
  if (flag('--card')) {
    const name = buddyName(await readConfig(brainDir), identity);
    process.stdout.write(renderCard(identity, name) + `\n  seed: ${identity.seed_source}${identity.seed_source === 'fallback' ? ' (no Claude login found — log in and run: sb buddy --rehatch)' : ''}\n`);
  } else {
    process.stdout.write(JSON.stringify(identity) + '\n');
  }
  return 0;
}

// Only run as a CLI when executed directly (the sb entry imports the helpers).
const invokedDirectly = process.argv[1] && /buddy-identity-cli/.test(process.argv[1]);
if (invokedDirectly) {
  main(process.argv.slice(2)).then((c) => process.exit(c)).catch((e) => { process.stderr.write(`buddy-identity: ${(e as Error).message}\n`); process.exit(1); });
}
