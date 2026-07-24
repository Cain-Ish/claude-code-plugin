import { basename, join } from 'path';
import { readFileSync, existsSync } from 'fs';
import { cleanEnvPath } from '../path-guard.js';
import { originRemote } from '../brain-paths.js';
import { resolveSlugByPath, resolveSlugByRemote } from './project-registry.js';

/** Resolve the active project slug from a project directory path.
 *  Rejects degenerate basenames ('/', '.', '', undefined) → undefined.
 *  Collapses tmp/scratch-style dirs into one shared "scratch" project, matching
 *  scripts/lib.sh sb_slug_from_dir (so the TS and bash resolvers agree). */
export function slugFromProjectDir(dir: string | undefined): string | undefined {
  if (!dir) return undefined;
  // CR-strip for parity with sb_slug_from_dir: a CRLF-tainted CLAUDE_PROJECT_DIR must yield
  // the SAME slug on both sides, else the TS resolver and bash hooks split-brain the project.
  const base = basename(cleanEnvPath(dir));
  if (!base || base === '/' || base === '.' || base === '..') return undefined;
  if (/^tmp\.|^tmp$|^\.tmp\.|^tmpfs$/.test(base)) return 'scratch';
  return base;
}

/** The project dir Claude Code exposes to a stdio MCP server, preferring the
 *  stable CLAUDE_PROJECT_DIR env var (set by CC v2.1.x in the server's env to
 *  the project root) and falling back to cwd on older CLIs that don't set it. */
export function activeProjectDir(env: NodeJS.ProcessEnv = process.env, cwd: () => string = process.cwd): string {
  return cleanEnvPath(env.CLAUDE_PROJECT_DIR) || cwd();
}

/** Remote-identity upgrade for a basename-derived slug: the dir's origin remote
 *  (parsed from .git, no spawn) looked up in the projects.jsonl registry. The remote
 *  is the project IDENTITY; the basename is only the fallback for remote-less dirs —
 *  so a re-clone under a new folder name (`name-2` of repo `name`) resolves to the
 *  registered slug instead of minting a second project. Any failure → undefined
 *  (fail open to the basename). Mirrors sb_detect_project case 4 in scripts/lib.sh. */
function remoteIdentitySlug(brainDir: string, dir: string): string | undefined {
  const url = originRemote(dir);
  if (!url) return undefined;
  return resolveSlugByRemote(brainDir, url);
}

/** Loud observability for the identity override: .git/config is attacker-writable
 *  text, so a crafted origin can inherit a registered project's slug. The override
 *  is accepted (fail-open identity enhancement) but must never be silent — one
 *  structured stderr line per firing, mirroring the bash sb_log_audit
 *  remote-identity-override event. Never throws. */
function logRemoteOverride(dir: string, base: string, slug: string): void {
  try {
    console.error(JSON.stringify({ event: 'remote-identity-override', dir, basename: base, slug }));
  } catch { /* logging must never break resolution */ }
}

/** Resolve the active project slug.
 *  Precedence: CLAUDE_PROJECT_DIR (registry-path > remote-identity > basename)
 *  > cwd registry-path > cwd remote-identity > cwd-if-known-project > pin > cwd.
 *
 *  Both CLAUDE_PROJECT_DIR and cwd are PER-PROCESS (a concurrent session can't
 *  change them); the global ~/.second-brain/.active-session-slug pin is a single
 *  shared file the last session's SessionStart overwrites, so it must NOT outrank
 *  a per-process signal.
 *  - CLAUDE_PROJECT_DIR: first checked against the registry (longest-prefix root_path match
 *    yields the path-qualified slug for monorepo children), then falls back to bare basename.
 *  - cwd is checked against the registry first; if no root_path matches, trusted ONLY when
 *    its basename names a KNOWN project (projects/<slug>/PROJECT.md exists).
 *  - then the .active-session-slug pin (when it names a known project) is the per-session
 *    fallback; bare cwd basename is the last resort. */
export function resolveActiveSlug(
  brainDir: string,
  env: NodeJS.ProcessEnv = process.env,
  cwd: () => string = process.cwd,
): string | undefined {
  if (env.CLAUDE_PROJECT_DIR) {
    // A registered monorepo child whose root_path contains this dir wins (path-qualified slug),
    // else fall back to the basename slug.
    const byPath = resolveSlugByPath(brainDir, env.CLAUDE_PROJECT_DIR);
    if (byPath) return byPath;
    const fromEnv = slugFromProjectDir(env.CLAUDE_PROJECT_DIR);
    if (fromEnv) {
      const byRemote = remoteIdentitySlug(brainDir, env.CLAUDE_PROJECT_DIR);
      if (byRemote && byRemote !== fromEnv) {
        logRemoteOverride(env.CLAUDE_PROJECT_DIR, fromEnv, byRemote);
        return byRemote;
      }
      return fromEnv;
    }
  }
  const here = cwd();
  const byCwdPath = resolveSlugByPath(brainDir, here);
  if (byCwdPath) return byCwdPath;
  const cwdSlug = slugFromProjectDir(here);
  if (cwdSlug) {
    const byRemote = remoteIdentitySlug(brainDir, here);
    if (byRemote && byRemote !== cwdSlug) {
      logRemoteOverride(here, cwdSlug, byRemote);
      return byRemote;
    }
  }
  if (cwdSlug && existsSync(join(brainDir, 'projects', cwdSlug, 'PROJECT.md'))) return cwdSlug;
  try {
    const pin = readFileSync(join(brainDir, '.active-session-slug'), 'utf-8').trim();
    if (pin && existsSync(join(brainDir, 'projects', pin, 'PROJECT.md'))) return pin;
  } catch { /* no pin */ }
  return cwdSlug;
}
