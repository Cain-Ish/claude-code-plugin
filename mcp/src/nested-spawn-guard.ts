// Caller-context guard for DESTRUCTIVE MCP write-tools. The headless
// maintain-llm-drain spawn runs `claude -p --permission-mode bypassPermissions`
// over UNTRUSTED transcript content with SB_NESTED_SPAWN=1 in its env; that env
// is inherited by any MCP server child claude forks (bwrap adds no --clearenv).
// A prompt-injected headless agent must NOT be able to mutate the LIVE wiki /
// dream state / PROJECT.md / USER.md unattended. Read-only tools stay open; the
// live interactive session (marker unset) is unaffected.
//
// Mirrors the SB_NESTED_SPAWN circuit-breaker the bash capture/context hooks use
// — but, like the PreToolUse/PostToolUse security guards, it is a SAFETY guard,
// so it refuses rather than silently no-ops, and there is no bypass env.

export function isNestedSpawn(): boolean {
  // Read at call time (not module load) so a test can toggle process.env per case.
  // Exact '1' match — any other value (unset/'0'/'') is treated as the live session.
  return process.env.SB_NESTED_SPAWN === '1';
}

type ToolResult = { content: Array<{ type: 'text'; text: string }>; isError?: boolean };

export function nestedSpawnRefusal(toolName: string): ToolResult {
  return {
    content: [{
      type: 'text' as const,
      text: `${toolName} is disabled in a nested/headless spawn (SB_NESTED_SPAWN=1): destructive knowledge-base writes are forbidden when running unattended over untrusted content. Re-run from an interactive session.`,
    }],
    isError: true,
  };
}

// Wrap a registered tool handler so it refuses under SB_NESTED_SPAWN=1 BEFORE the
// real handler runs (no disk touch, no child process). `handler` keeps its exact
// signature/return shape; the wrapper is transparent in the live session.
export function guardDestructive<A extends unknown[], R extends ToolResult>(
  toolName: string,
  handler: (...args: A) => Promise<R>,
): (...args: A) => Promise<R | ToolResult> {
  return async (...args: A) => {
    if (isNestedSpawn()) return nestedSpawnRefusal(toolName);
    return handler(...args);
  };
}

