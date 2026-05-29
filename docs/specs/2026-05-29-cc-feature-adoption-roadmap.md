# Roadmap: Claude Code feature adoption for the second-brain plugin

**Date:** 2026-05-29
**Status:** Approved (roadmap) — implementing in tranches
**Author:** second-brain session
**Method:** Dynamic-workflow research (`wk5vizd1u`): 12 doc clusters (169 features extracted from code.claude.com/docs) → 243 gap verdicts (26 adopt / 26 modify / 92 watch / 99 skip) → adversarial verify against the user's hard constraints. The verify pass overturned 7 gap-agent claims; corrections are folded in below. Verified against the live box: **claude 2.1.156**, plugin **0.22.0**, knowledge-base MCP **2.3.0**.

## Hard constraints every item is judged against (the user's threat model)

- **Supply-chain is P0** — no new attack surface, no unvetted deps, no download-and-execute.
- **Offline-first** — must degrade gracefully when Claude/network is down.
- **OAuth default (NOT api key)** — in-session recursive `claude` calls are queued/blocked; any automation that assumes a synchronous in-session `claude --bare` is disqualified or must enqueue out-of-session.
- **Verify before install / distrust community** — confirm a feature is real on THIS box before building on it.

---

## ⭐ Strategic call — native auto-memory is a live collision, not a competitor

Claude Code ships **auto-memory** (ON by default since v2.1.59): it autonomously extracts learnings/preferences from sessions and writes per-repo `MEMORY.md` — exactly what `stop-extract.sh` + `merge-project-update.sh` + `pin_to_user/pin_to_project` do. The `MEMORY.md` injected at session start IS native auto-memory. The two run **uncoordinated**: the plugin has zero awareness of it (grep for `autoMemory` across the repo returns nothing), so two extractors write overlapping notes into two stores the user must reconcile.

**Position: the plugin must own the namespace, not race a second writer.** Native is a flat per-repo markdown scratchpad — no graph, no cold-tier wiki, no vector recall, no validation, no safety hooks. The second-brain is the structured, queryable, self-healing layer. Resolve via **coordination, not a feature**: detect `autoMemoryEnabled`, report it loudly in `status` + `audit`, and **offer (never force)** to disable it via user-scoped `CLAUDE_CODE_DISABLE_AUTO_MEMORY` / `autoMemoryEnabled:false`. Make the differentiation explicit in README + setup. (Own spec — Task #28.)

---

## 🥇 ADOPT (verified, ranked)

| # | Item | Why it earns a place | Touchpoints | Effort/Risk |
|---|------|----------------------|-------------|-------------|
| 1 | **Auto-memory coordination** | Resolves a live dual-writer collision; defends the plugin's reason to exist | `setup`, `status`, `audit` skills; README differentiation section; optional user-scoped disable | med / med |
| 2 | **`SubagentStop` hook capture** | Headline gap: plugin is already multi-agent (code-review-deep fan-out; dream-runner) but extraction only sees the MAIN-session transcript — every subagent's learnings are lost. **Enqueue to `sb-extract-drain`, NEVER inline `claude --bare` (OAuth block).** | `hooks/hooks.json` (new SubagentStop), thin enqueue script, `lib.sh`/`episodic-index-cli.ts` glob `~/.claude/projects/{proj}/{sid}/subagents/agent-{id}.jsonl` | med / low |
| 3 | **`claude plugin validate --strict` in release gate** | Real flag on 2.1.156 ("treat warnings as errors"). `validate-plugin.sh` already calls plain `validate`; `--strict` promotes warnings. Reinforces deep-review gate ([[validate-the-real-capability]]) | `scripts/validate-plugin.sh` | small / low |
| 4 | **MCP `alwaysLoad: true`** | This session proves the symptom: ~25 knowledge-base tools are ToolSearch-deferred, so the wingman can't reflexively reach `knowledge_neighbors`. `alwaysLoad` (v2.1.121+, verified) un-defers. Trade-off: ~25 tools always in context + ≤5s startup block | `.mcp.json` | small / low |
| 5 | **MCP server reads `CLAUDE_PROJECT_DIR`** | Confirmed passed to stdio MCP servers. `server.ts resolveActiveSlug` uses `process.cwd()` (unreliable for an stdio proc) + pin file; prefer the env var with graceful fallback | `mcp/src/server.ts` | small / low |
| 6 | **`FileChanged` + `watchPaths` hook** | Direct fix for the known reindex bug ([[sb-reindex-esm-import]]): index.md/USER.md/PROJECT.md edits auto-reindex. **Caveat: matcher is LITERAL filenames, no globs** — enumerate the files | `hooks/hooks.json` (new FileChanged), `session-load.sh` emits `hookSpecificOutput.watchPaths` (absolute paths) | med / low |
| 7 | **`InstructionsLoaded` hook (audit-only)** | Mirrors `config-change-guard.sh`; lets `audit` show which memory files loaded + when. Pure bash, no dep, offline-safe | new `scripts/instructions-loaded-audit.sh`, `hooks/hooks.json` | small / low |
| 8 | **`${CLAUDE_PLUGIN_DATA}` awareness (doc)** | Verify confirmed the plugin's stores (`~/knowledge`, `~/.second-brain`) are OUTSIDE the ephemeral plugin root → **already safe**. Document so nobody writes state into `${CLAUDE_PLUGIN_ROOT}` (wiped ~7 days post-update) | RELEASING.md / architecture note | trivial / low |
| 9 | **`--plugin-dir` + `/reload-plugins` dev loop (doc)** | Resolves recurring [[plugin-cache-vs-repo-gap]] "edits do nothing". Use `--plugin-dir` (local) ONLY — **never `--plugin-url`** (remote zip = download-and-execute, fails verify-before-install) | RELEASING.md / Makefile / upgrade skill | trivial / low |

## 🔧 MODIFY (align how the plugin already does things)

- **Tighten read-only agents' `disallowedTools`** — `code-review-scorer`, `code-review-history-reviewer`, `search-conversations` are read-only; add explicit `disallowedTools: Write, Edit, WebFetch`. (P0 least-privilege. Verify note: allowlists already exist — add the deny half only.)
- **`Task`→`Agent` matcher rename (v2.1.63)** — `hooks.json` PreToolUse matcher says `Task`; add `Agent` or the persona guard silently stops matching subagent spawns. Keep `Task` for back-compat.
- **Command-hook exec form `{command, args}`** — converting from `bash -c` strings mitigates the ESM/quoting bug class ([[sb-reindex-esm-import]]).
- **`maxTurns` on write-capable background agents** (dream-runner, knowledge-maintainer) — currently unset; a runaway bound.
- **Preload `skills:` into worker agents** — ship graph-conventions as a preloaded skill so dream-runner/maintainer stop rediscovering conventions at runtime. (Gotcha: `skills:`/`mcpServers:` frontmatter is IGNORED on teammate agents — applies to subagents only.)

## 👀 WATCH (real but don't build — preview/experimental/cloud)

- **Agent teams** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) — experimental, env-gated; code-review-deep fan-out already covers it. *Flip signal: GA + works under OAuth.*
- **Dynamic workflows / ultracode / ultraplan / ultrareview** — useful (we used one) but cloud/experimental + offline-blind. Harvest the *patterns* (refute-until-converge), don't wire the plugin to call them.
- **Subagent persistent `memory:` field** — per-agent `MEMORY.md`; conflicts with single-graph-store. Watch if it becomes the native standard.
- **Routines** (Anthropic-managed cron) — overlaps systemd `sb-extract-drain`; cloud-dependent, so local timers stay the better fit.

## ✂️ SKIP — with reason (fail a hard constraint; the valuable "don't")

- **`permissionMode` field / auto-approved writes** — auto-approve = attack surface (P0). Also unusable on plugin agents.
- **Skill/agent-scoped `hooks:` field** — **silently ignored on plugin agents** → guards that look configured but don't run = security theater. `validate` should assert against it.
- **Mailbox/SendMessage, forked subagents, `--bg` dispatch** — assume multiple live in-session agents; OAuth-recursive-block queues/blocks them.
- **Ultraplan cloud handoff** — work leaves the local machine; fails the credential-exposure posture.
- **`!`command`` dynamic context injection** — new policy-driven failure mode; conflicts with always-on injection.

## Overturned by the adversarial verify pass (kept honest)

- `/goal` gating — `/goal` is upstream CLI surface, preview-stage; the plugin has no `/goal`. Only the "report hook-disable state" half is salvageable.
- "Full subagent frontmatter — add tool allowlists" — already satisfied on all 7 agents; the add is a no-op (deny-half is the only real delta).
- Workflow-permission "collision/bypass" claim — factually wrong; PreToolUse hooks still apply. Verdict stays watch, rationale corrected.
- `/deep-research` "redundant with shipped" — false; keep watch (harvest the pattern, don't wire it).
- Subagent transcript "resume + SendMessage" — experimental (teams-gated); narrow to transcript archival via SubagentStop only.

## Implementation tranches

1. **Quick-wins (this branch, `feat/cc-feature-adoption`):** #3, #4, #5, #8, #9 + `Task`→`Agent`. Mechanical, TDD, fold into 0.22.0.
2. **Own specs (separate cycles):** #1 auto-memory coordination, #2 SubagentStop capture, #6 FileChanged/watchPaths.
3. **Modify batch:** disallowedTools, command-hook form, maxTurns, preload skills — after tranche 1.
4. **Tier-1 skill upgrade (Task #20)** re-scoped: wingman now describes itself relative to native auto-memory (#1); SubagentStop (#2) is a bigger capture win than the original lint-guard.
