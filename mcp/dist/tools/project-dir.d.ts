/** Resolve the active project slug from a project directory path.
 *  Rejects degenerate basenames ('/', '.', '', undefined) → undefined.
 *  Collapses tmp/scratch-style dirs into one shared "scratch" project, matching
 *  scripts/lib.sh sb_slug_from_dir (so the TS and bash resolvers agree). */
export declare function slugFromProjectDir(dir: string | undefined): string | undefined;
/** The project dir Claude Code exposes to a stdio MCP server, preferring the
 *  stable CLAUDE_PROJECT_DIR env var (set by CC v2.1.x in the server's env to
 *  the project root) and falling back to cwd on older CLIs that don't set it. */
export declare function activeProjectDir(env?: NodeJS.ProcessEnv, cwd?: () => string): string;
/** Resolve the active project slug. Precedence: CLAUDE_PROJECT_DIR > pin > cwd.
 *
 *  CLAUDE_PROJECT_DIR is the PER-SESSION project root Claude Code sets — checked
 *  FIRST so a concurrent session can't hijack scoping. The global
 *  ~/.second-brain/.active-session-slug pin is a single shared file the last
 *  session's SessionStart overwrites; it stays BELOW CLAUDE_PROJECT_DIR (so a
 *  stale/concurrent pin no longer wins) but ABOVE bare cwd (it is project-root
 *  level and survives a subdir cwd) — the legacy path for CLIs without a project dir. */
export declare function resolveActiveSlug(brainDir: string, env?: NodeJS.ProcessEnv, cwd?: () => string): string | undefined;
//# sourceMappingURL=project-dir.d.ts.map