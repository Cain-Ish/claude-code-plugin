# Claude Code native memory capabilities (docs read 2026-10-19)

Status: [D] documented · [U] unclear / partly documented · [N] not documented. Every claim cites the doc page.
Gaps: the hooks reference was read only in part; the API memory-tool page, plugin-agent `memory:` and plugin skill `paths:` behaviour were not verified.

## 1. CLAUDE.md
- Locations: managed policy, `~/.claude/CLAUDE.md`, `./CLAUDE.md` or `./.claude/CLAUDE.md`, `CLAUDE.local.md`. [D] https://code.claude.com/docs/en/memory
- Ancestor CLAUDE.md files load at launch; subdirectory CLAUDE.md files load on demand when Claude works in that directory. [D]
- `@path` imports: relative to the importing file, max depth 4, load at launch (no context saving). External imports need one-time approval. [D]
- Size: target < 200 lines per file; files > 4 MiB skipped. [D]
- Compaction: root CLAUDE.md re-read from disk; nested CLAUDE.md reloads on demand. [D] https://code.claude.com/docs/en/context-window#what-survives-compaction
- Subagents: Explore and Plan do NOT load CLAUDE.md; general-purpose does; custom subagents do unless `omitClaudeMd: true`. Subdirectory CLAUDE.md and path rules still load for Explore/Plan when they touch files there. [D] https://code.claude.com/docs/en/sub-agents#what-loads-at-startup
- A CLAUDE.md at a plugin root is not loaded; `claude plugin validate` warns. [D] https://code.claude.com/docs/en/plugins/manifest-reference#standard-layout

## 2. `.claude/rules/*.md`
- Rules without `paths:` load at launch like `.claude/CLAUDE.md`. [D] https://code.claude.com/docs/en/memory#organize-rules-with-claude/rules/
- A path-scoped rule loads when Claude Reads/Writes/Edits a matching file, or a Bash read (`cat`, `head`) touches one; not on glob/listing. [D]
- Only `paths` is read from frontmatter; malformed YAML falls back to unconditional. [D]
- Path rules load inside subagents (incl. Explore and Plan) when they touch a matching file. [D] sub-agents page
- Compaction: path rules are NOT re-injected (reload on next touch); unscoped rules are. [D] context-window page
- Rules are not a plugin component type. [N]

## 3. Auto memory (`~/.claude/projects/<project>/memory/`)
- Project derived from the git repo (worktrees share it). First 200 lines / 25 KB of `MEMORY.md` load at start; topic files on demand. [D] memory page
- Written by Claude (types user/feedback/project/reference). Disable: `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, `autoMemoryEnabled:false`, `/memory`; relocate with `autoMemoryDirectory`. [D]
- No documented plugin/hook write API. [N]
- Not loaded into subagents (a subagent with `memory:` gets its own). [D]
- Re-injected after compaction. [D]
- Machine-local, per user; not shared. [D]

## 4. Subagent `memory:` frontmatter
- Scopes: user `~/.claude/agent-memory/<name>/`, project `.claude/agent-memory/<name>/`, local `.claude/agent-memory-local/<name>/`; first 200 lines / 25 KB of its MEMORY.md in the system prompt; no effect if auto memory is off. [D] https://code.claude.com/docs/en/sub-agents#persistent-memory
- Plugin agents with `memory:`: [U].

## 5. Skills
- Always in context: name + description (≤1,536 chars in the listing). Body loads on invoke/auto-match. [D] https://code.claude.com/docs/en/skills
- `disable-model-invocation: true` removes the description from context. [D]
- `paths:` uses rule glob semantics; auto-activates when matching files are touched. [D]
- `!cmd` output injected at load; failing command aborts the invocation. [D]
- Compaction: invoked skill bodies re-injected (5k tokens/skill, 25k total); descriptions not re-injected. [D]
- Subagent `skills:` preloads full content. [D]
- Plugin skills with `paths:`: [U].

## 6. Plugins
- Can ship: skills, commands, agents (plugin agents ignore `hooks`, `mcpServers`, `permissionMode`), hooks, MCP, LSP, output styles, themes, workflows, monitors, `bin/` (on Bash PATH), settings.json (only `agent`, `subagentStatusLine`), userConfig, channels. [D] https://code.claude.com/docs/en/plugins/manifest-reference
- Cannot ship: a loaded CLAUDE.md, other settings, statusLine (by omission), rules, auto memory. [D]/[N]

## 7. Hooks — https://code.claude.com/docs/en/hooks
- 33 events incl. SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, SubagentStart/Stop, PreCompact, PostCompact, InstructionsLoaded. [D]
- `additionalContext` cap 10,000 chars; above it the text goes to a file with a 2,000-char preview. [D]
- Default timeout 600 s (command/http/mcp_tool), 30 s prompt, 60 s agent; 30 s on UserPromptSubmit. A PreToolUse timeout discards output and continues (fail-open); `"onFailure": "block"` (v2.1.295+) changes this. [D] — v1 set its own 3-25 s timeouts.
- `"async": true` runs without timeout; `asyncRewake` wakes Claude on exit 2. [D]
- SessionStart matchers: startup, resume, clear, compact, fork; cannot block; `compact` output re-injected. [D] https://code.claude.com/docs/en/hooks-guide#re-inject-context-after-compaction
- Hooks run inside subagents; SubagentStart can add context. [D]

## 8. MCP — https://code.claude.com/docs/en/mcp
- Tool search on by default: only tool names + server instructions load up front; schemas deferred. `alwaysLoad` forces upfront. [D]
- Server instructions cap 4,096 chars. [D]
- Resources: @-mention only, not auto-loaded. Prompts become slash commands. [D]
- Subagents get the parent's MCP servers. [D]

## 9. Compaction — https://code.claude.com/docs/en/context-window#what-survives-compaction
- Survives (from disk): system prompt, output style, root CLAUDE.md, unscoped rules, auto memory, plan file, 5 most recently touched files, invoked skill bodies (capped).
- Reloads on demand: path rules, nested CLAUDE.md. Lost: skill descriptions, earlier hook context (summarized).
- PreCompact can block; PostCompact has no decision control. [D]

## 10. Team memory (2026)
- No official shared/team memory in Claude Code; auto memory is per machine. [D by omission]
- API memory tool and compaction APIs exist (platform docs), behaviour inside Claude Code [U].

## 11. Plugin scoping and the skill listing (follow-up)
- `"<plugin>@<marketplace>": false` under `enabledPlugins` in `.claude/settings.local.json` disables a user-enabled plugin for one user in one project. [D] https://code.claude.com/docs/en/plugins/install#uninstall-a-plugin-the-project-enables
- Precedence: managed > command line > project local > shared project > user. [D] https://code.claude.com/docs/en/settings. A `false` in shared `.claude/settings.json` overriding a user `true`: [U].
- `skillOverrides` (`on` / `name-only` / `user-invocable-only` / `off`) per skill name; not for plugin skills. [D] https://code.claude.com/docs/en/skills#override-skill-visibility-from-settings
- No per-plugin hook switch; `disableAllHooks` or disabling the plugin. [D, index]
- Skill listing budget: 1% of the context window. Names always appear; on overflow, descriptions of the least-invoked skills are dropped first. Controls: `skillListingBudgetFraction`, `skillListingMaxDescChars`, env `SLASH_COMMAND_TOOL_CHAR_BUDGET`. Overflow is logged under `--debug`. [D] https://code.claude.com/docs/en/skills#skill-descriptions-are-cut-short
- Implication for v2: a plugin's own skills compete for the same 1% budget with every other installed plugin. Few skills with short descriptions, or knowledge that does not depend on skill selection at all.

## Channel table

| Channel | Always-on cost | Main | Subagents | Survives compaction | Plugin-writable | Shared via git |
|---|---|---|---|---|---|---|
| Root CLAUDE.md | whole file every request | yes | g-p + custom; not Explore/Plan | re-read | committed file | yes |
| Path rule (`paths:`) | 0 until a matching file is touched | on match | on match, incl. Explore/Plan | no; reloads on touch | not a plugin component (repo file) | yes |
| Unscoped rule | whole text every request | yes | as CLAUDE.md | re-read | repo file | yes |
| Auto memory MEMORY.md | ≤200 lines / 25 KB | yes | no | re-read | no documented API | no (per machine) |
| Subagent `memory:` | ≤200 lines / 25 KB | n/a | that subagent | [U] | [U] | project scope if committed |
| Skill description | ≤1,536 chars each | yes | via Skill tool | not re-injected | yes | yes |
| Skill body | 0 until invoked | on invoke | `skills:` preload | 5k/skill, 25k total | yes | yes |
| SessionStart hook | ≤10k chars per emission | yes | n/a | `compact` matcher re-runs | yes | hook config |
| MCP tools | names only | yes | parent's servers | n/a | yes | yes |
| MCP resources | 0 until @-mention | on mention | [U] | n/a | yes | yes |
