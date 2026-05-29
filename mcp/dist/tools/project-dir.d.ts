/** Resolve the active project slug from a project directory path.
 *  Rejects degenerate basenames ('/', '.', '', undefined) → undefined. */
export declare function slugFromProjectDir(dir: string | undefined): string | undefined;
/** The project dir Claude Code exposes to a stdio MCP server, preferring the
 *  stable CLAUDE_PROJECT_DIR env var (set by CC v2.1.x in the server's env to
 *  the project root) and falling back to cwd on older CLIs that don't set it. */
export declare function activeProjectDir(env?: NodeJS.ProcessEnv, cwd?: () => string): string;
//# sourceMappingURL=project-dir.d.ts.map