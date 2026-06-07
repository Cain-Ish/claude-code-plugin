import { basename, join } from 'path';
import { readFileSync, existsSync } from 'fs';

/** Resolve the active project slug from a project directory path.
 *  Rejects degenerate basenames ('/', '.', '', undefined) → undefined.
 *  Collapses tmp/scratch-style dirs into one shared "scratch" project, matching
 *  scripts/lib.sh sb_slug_from_dir (so the TS and bash resolvers agree). */
export function slugFromProjectDir(dir: string | undefined): string | undefined {
  if (!dir) return undefined;
  const base = basename(dir);
  if (!base || base === '/' || base === '.' || base === '..') return undefined;
  if (/^tmp\.|^tmp$|^\.tmp\.|^tmpfs$/.test(base)) return 'scratch';
  return base;
}

/** The project dir Claude Code exposes to a stdio MCP server, preferring the
 *  stable CLAUDE_PROJECT_DIR env var (set by CC v2.1.x in the server's env to
 *  the project root) and falling back to cwd on older CLIs that don't set it. */
export function activeProjectDir(env: NodeJS.ProcessEnv = process.env, cwd: () => string = process.cwd): string {
  return env.CLAUDE_PROJECT_DIR || cwd();
}

/** Resolve the active project slug.
 *  Precedence: CLAUDE_PROJECT_DIR > cwd-if-known-project > pin > cwd.
 *
 *  Both CLAUDE_PROJECT_DIR and cwd are PER-PROCESS (a concurrent session can't
 *  change them); the global ~/.second-brain/.active-session-slug pin is a single
 *  shared file the last session's SessionStart overwrites, so it must NOT outrank
 *  a per-process signal.
 *  - CLAUDE_PROJECT_DIR (when set, the project root) wins outright.
 *  - cwd is trusted ONLY when its basename names a KNOWN project
 *    (projects/<slug>/PROJECT.md exists). That gate is the key: it accepts the
 *    real project root (so a concurrent session's stale pin can't hijack it) but
 *    rejects a subdir cwd (which falls to the pin — the session-root value).
 *  - the pin is the subdir/legacy fallback; bare cwd is the last resort (a brand
 *    new project session-load has just scaffolded). */
export function resolveActiveSlug(
  brainDir: string,
  env: NodeJS.ProcessEnv = process.env,
  cwd: () => string = process.cwd,
): string | undefined {
  if (env.CLAUDE_PROJECT_DIR) {
    const fromEnv = slugFromProjectDir(env.CLAUDE_PROJECT_DIR);
    if (fromEnv) return fromEnv;
  }
  const cwdSlug = slugFromProjectDir(cwd());
  if (cwdSlug && existsSync(join(brainDir, 'projects', cwdSlug, 'PROJECT.md'))) return cwdSlug;
  try {
    const pin = readFileSync(join(brainDir, '.active-session-slug'), 'utf-8').trim();
    if (pin && existsSync(join(brainDir, 'projects', pin, 'PROJECT.md'))) return pin;
  } catch { /* no pin */ }
  return cwdSlug;
}
