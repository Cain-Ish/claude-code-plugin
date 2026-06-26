import { join } from 'path';
import { homedir } from 'os';
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
  return (
    cleanEnvPath(
      process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR || process.env.KNOWLEDGE_DIR
    ) || join(homedir(), 'knowledge')
  );
}
