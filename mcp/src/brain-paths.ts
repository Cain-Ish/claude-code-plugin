import { join, isAbsolute } from 'path';
import { homedir } from 'os';
import { readFileSync, statSync, existsSync } from 'fs';
import { cleanEnvPath } from './path-guard.js';

/**
 * Canonical resolvers for the second-brain home dir and the knowledge dir.
 *
 * THE BUG CLASS THIS CLOSES (0.33.x): ~14 tools each hand-rolled their own
 * resolution as `join(process.env.HOME ?? '', '.second-brain')`. On native
 * Windows, Node does NOT inherit `HOME` (Windows uses `USERPROFILE`), so the
 * fallback collapsed to a CWD-RELATIVE path and the tool wrote a stray
 * `.second-brain/` (or `knowledge/`) into whatever directory the MCP server's
 * process happened to be in. The plugin's bash hooks run under MSYS where
 * `$HOME` *is* set, which is why the shell side looked fine and the Node side
 * silently rotted.
 *
 * `os.homedir()` is the dedicated cross-OS primitive: it reads `USERPROFILE`
 * on Windows and `HOME` on Unix and NEVER returns an empty string. No code
 * should read `process.env.HOME` directly for path resolution. Every brain/
 * knowledge dir resolution funnels through here so a single source of truth
 * stays correct on Windows/Linux/macOS/BSD.
 *
 * `cleanEnvPath` strips CR/LF from env-derived paths (the separate Windows
 * CRLF-tainting bug — see path-guard.ts) so an override piped through a CRLF
 * file/registry/wrapper does not produce a phantom `"x\r"` path.
 */
export function resolveBrainDir(override?: string): string {
  if (override) return override;
  return (
    cleanEnvPath(process.env.SB_BRAIN_DIR || process.env.BRAIN_DIR) ||
    join(homedir(), '.second-brain')
  );
}

export function resolveKnowledgeDir(override?: string): string {
  if (override) return override;
  // THE SINGLE knowledge-dir resolver (server.ts and dream.ts once carried local
  // copies with the OPPOSITE precedence — env over option). Canonical precedence:
  // plugin option > env > ~/knowledge. Per-candidate guards absorbed from those
  // copies: a value still containing an unexpanded `${...}` placeholder (a root
  // .mcp.json loaded outside a plugin context leaves the literal
  // ${CLAUDE_PLUGIN_OPTION_...}) is rejected rather than used as a path, a
  // whitespace-only value is skipped, and a leading `~` expands against homedir().
  for (const raw of [process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR, process.env.KNOWLEDGE_DIR]) {
    const c = cleanEnvPath(raw);
    if (!c.trim() || c.includes('${')) continue;
    return c.startsWith('~') ? join(homedir(), c.slice(1)) : c;
  }
  return join(homedir(), 'knowledge');
}

/**
 * Canonicalize a git remote URL to its host/path identity so different URL forms of
 * the same repository compare equal: trim, lowercase, drop the scheme (proto://) and
 * any user@ prefix, fold the scp-form "host:path" colon to "/", strip trailing
 * slashes and one trailing ".git". Empty in -> empty out.
 *
 * LOCKSTEP: three twins implement this — this function, sb_normalize_remote and the
 * $SB_JQ_REMOTE_ID jq def in scripts/lib.sh. All are pinned to the shared fixture
 * tests/fixtures/remote-normalization.tsv so they cannot drift.
 */
export function normalizeRemote(url: string): string {
  // ASCII-only lowercasing (NOT toLowerCase): the bash twin (tr 'A-Z' 'a-z') and the
  // jq twin (ascii_downcase) leave non-ASCII untouched — Unicode-aware folding here
  // (Ö→ö) would fork the three twins on a non-ASCII owner/repo path.
  let s = (url ?? '').replace(/\r/g, '').replace(/[A-Z]/g, (c) => c.toLowerCase()).trim();
  s = s.replace(/^[a-z+]+:\/\//, '');
  s = s.replace(/^[^@/]*@/, '');
  s = s.replace(/^([^/:]+):/, '$1/');
  return s.replace(/\/+$/, '').replace(/\.git$/, '').replace(/\/+$/, '');
}

/**
 * The origin remote URL of a dir's git repo, read by parsing .git directly — no git
 * spawn (this sits on the per-tool-call slug-resolution hot path). Handles all three
 * .git layouts: a plain .git directory; a .git FILE whose `gitdir:` pointer names the
 * real git dir (submodule); and the worktree layout where that gitdir has no config
 * of its own and its `commondir` file points back at the main .git. Any failure
 * (no repo, no origin, unreadable) -> '' — identity enhancement, never a guard.
 */
export function originRemote(dir: string): string {
  try {
    const d = cleanEnvPath(dir);
    if (!d) return '';
    const gitPath = join(d, '.git');
    let configDir: string;
    if (statSync(gitPath).isDirectory()) {
      configDir = gitPath;
    } else {
      const m = readFileSync(gitPath, 'utf-8').match(/^gitdir:\s*(.+?)\s*$/m);
      if (!m) return '';
      const gd = m[1];
      configDir = isAbsolute(gd) ? gd : join(d, gd);
      if (!existsSync(join(configDir, 'config'))) {
        const cd = readFileSync(join(configDir, 'commondir'), 'utf-8').trim();
        configDir = isAbsolute(cd) ? cd : join(configDir, cd);
      }
    }
    const cfg = readFileSync(join(configDir, 'config'), 'utf-8');
    let inOrigin = false;
    for (const line of cfg.split('\n')) {
      const t = line.trim();
      if (t.startsWith('[')) { inOrigin = /^\[remote\s+"origin"\]/.test(t); continue; }
      if (!inOrigin) continue;
      const mu = t.match(/^url\s*=\s*(.+)$/);
      if (mu) return mu[1].trim();
    }
    return '';
  } catch {
    return '';
  }
}
