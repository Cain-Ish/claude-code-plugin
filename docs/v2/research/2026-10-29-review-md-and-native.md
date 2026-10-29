# REVIEW.md and Claude Code's native features, against v2

**Date:** 2026-10-29. **Question (user):** Anthropic ships REVIEW.md. Does it, or any native feature added since the
eval's CLI pin (2.1.305; installed now: 2.1.312), already do what v2 does? Read from Anthropic's docs and changelog.

## REVIEW.md

- **Who reads it:** the managed Code Review service on GitHub pull requests. "The service reads both CLAUDE.md and
  REVIEW.md. The /code-review command, which you run inside a Claude Code session on your own machine, reads your
  CLAUDE.md files and not REVIEW.md." [CR-CUSTOM]
- **Plans:** "Team and Enterprise" [CR]. Generally available since 2026-10-15 [CR-GA].
- **Content:** "freeform Markdown that changes what a review finds and reports". It can add checks, for example "new
  API routes must have an integration test", lower severities, exclude paths and cap nits. A REVIEW.md in a
  subdirectory adds checks for changes under that path. Limits: at most eight included files, 150,000 bytes with
  them [CR-CUSTOM].

**For v2.**
- REVIEW.md is the native place where a team writes the checks a pull request is held to, after the session. It is the
  check source that D20's net lacked ("no tested source writes the checks"), but only for teams on Team or Enterprise,
  and only at PR time, not in the session. So v2 builds no review gate of its own: D20's net stays deferred, and
  REVIEW.md is one more reason.
- v2's index already lists a REVIEW.md, as a Markdown file of the repo (D15, D22). Nothing needs to change for a
  session to read it.
- What a session decides and nobody has written yet (A1's three decisions) is not in REVIEW.md until someone writes it
  there. Capture into the map (D14) stays v2's.

## Native features since 2.1.305

Read from the changelog, entries 2.1.306 to 2.1.312 [CHANGELOG], and the current memory, hooks and subagent pages:

- No native decisions, ADR or team-memory feature. Auto memory is "machine-local ... not shared across machines or
  cloud environments"; its `project` type covers "decisions that Claude can't derive from the code or git history"
  [MEMORY]. It has no review state, no source check and no commit.
- 2.1.311: "Fixed Claude seeing stale MEMORY.md and CLAUDE.md content right after automatic compaction."
- 2.1.309: the on-demand CLAUDE.md size limit (40,000 characters on a 200K window) now applies to files that load on
  demand [MEMORY].
- Hook output stays capped at 10,000 characters, with a 2,000-character preview above it [HOOKS]. v2's session start
  already fits the cap (`plugin/scripts/map.mjs`, `CAP`).
- **`UserPromptSubmit` fires on turns nobody typed:** "Claude Code also runs them on: A session-scoped scheduled task
  firing, including a /loop iteration; A background subagent reporting back to the session that started it; A message
  another session sends to your main conversation" [HOOKS]. The hook's input carries only `prompt`, with no field for
  its source [HOOKS, "UserPromptSubmit input"]. The field check found the plugin spending its forced decision on such a
  turn (probes/V2-D17-field, C2).
- Inside a subagent, tool events carry `agent_id` and `agent_type`; `SubagentStart` receives both [HOOKS]. The
  subagent page lists what loads at a subagent's start, and `SessionStart` context is not on it [SUBAGENTS].
- **A hook's `if` field** filters tool events by permission-rule syntax, such as `"Bash(git *)"`, so the hook spawns
  only when the call matches. The filter is best effort: "When Claude Code can't determine which commands the Bash
  input runs, it runs your hook regardless of the pattern" [HOOKS]. This makes a read hook on Bash or Grep cheap enough
  to consider (the field check's C5 observation). Not decided here.

## Sources

- [CR-CUSTOM] https://code.claude.com/docs/en/code-review-customize.md
- [CR] https://code.claude.com/docs/en/code-review.md
- [CR-GA] https://claude.com/blog/code-review-is-now-generally-available
- [CHANGELOG] https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
- [MEMORY] https://code.claude.com/docs/en/memory.md
- [HOOKS] https://code.claude.com/docs/en/hooks.md
- [SUBAGENTS] https://code.claude.com/docs/en/sub-agents.md

Not checked: changelog entries before 2.1.306, and whether a REVIEW.md rule that adds a check needs branch protection
(the docs list protection only for lowering severity, excluding paths and capping nits).
