import { basename } from 'path';
/** Resolve the active project slug from a project directory path.
 *  Rejects degenerate basenames ('/', '.', '', undefined) → undefined. */
export function slugFromProjectDir(dir) {
    if (!dir)
        return undefined;
    const base = basename(dir);
    return base && base !== '/' && base !== '.' ? base : undefined;
}
/** The project dir Claude Code exposes to a stdio MCP server, preferring the
 *  stable CLAUDE_PROJECT_DIR env var (set by CC v2.1.x in the server's env to
 *  the project root) and falling back to cwd on older CLIs that don't set it. */
export function activeProjectDir(env = process.env, cwd = process.cwd) {
    return env.CLAUDE_PROJECT_DIR || cwd();
}
//# sourceMappingURL=project-dir.js.map