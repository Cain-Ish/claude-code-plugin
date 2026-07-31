# Second Brain — Claude Code's memory of the project

A local-first memory layer for Claude Code. It gives Claude the mental model a senior dev holds
before opening a file — what exists, where it lives, why it's shaped that way — via a small hot
tier (`USER.md` + per-project `PROJECT.md`) auto-loaded every session and a larger local wiki
retrieved on demand. It learns on its own: hooks extract decisions, blockers, and learnings from
each session, and consolidation applies them to the knowledge base reversibly — fully unattended
where sandboxing permits (Linux); elsewhere changes stage automatically and apply on the next
`/second-brain:dream` or `/second-brain:maintain` run.

The mission and hard constraints (full autonomy, untrusted-content isolation, cross-platform)
are fixed in [CONSTITUTION.md](CONSTITUTION.md) and machine-enforced by the test suite.
Design history lives on the `archive/docs` branch.

## Install

```
/plugin marketplace add Cain-Ish/claude-code-plugin
/plugin install second-brain@second-brain
/second-brain:setup
```

The compiled MCP server (`mcp/dist/`) ships in the repo, so a marketplace install works out of
the box. Optional on-device vector search: `bash "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh"`
(search degrades cleanly to BM25/text-only without it). Session extraction needs Anthropic API
access — an `ANTHROPIC_API_KEY` or a Claude subscription; `sb auth doctor` walks through both.

## What runs automatically

Eight hook events wire the autonomous loop (`hooks/hooks.json`):

- **SessionStart** — ensures dirs, discovers installed plugins and tracked doc sources, loads the hot tier into context, banners pending/suggested dreams.
- **UserPromptSubmit** — injects persona card, catalog, and relevant wiki hits per prompt (no LLM call).
- **PreToolUse** — rules-based guards: tool guard (risky bash, hot-tier writes), wiki-write guard, symlink guard (denies writes resolving into `~/.ssh` and friends), outbound credential-flow guard, a soft plan-first nudge.
- **PostToolUse** — quality gate on writes, injection-pattern scan of tool returns (telemetry, never blocks), simplicity nudge on large single changes.
- **Stop** — verify gate, then the LLM extractor files what mattered into hot tier + wiki; SAR safety-summary banner.
- **SubagentStop** — archives substantive subagent results into the episodic transcript store.
- **PreCompact** — same extraction before a context compaction, so nothing is lost to the window.
- **ConfigChange** — audit-logs every settings/skills change (never blocks).

Every guard and pipeline has an `SB_*` kill switch. Consolidation itself stays reversible: dreams
stage changes for review, forgetting archives rather than deletes.

## Commands

15 user-invocable skills:

| Command | Purpose |
|---|---|
| `/second-brain:setup` | Scaffold hot tier + wiki for the active repo; idempotent |
| `/second-brain:upgrade` | Migrate an installed plugin to the current release; idempotent |
| `/second-brain:status` | Hot-tier and wiki health at a glance |
| `/second-brain:recall` | Search past session transcripts (hybrid vector + text) |
| `/second-brain:lint` | Wiki health check: orphans, dead `[[wiki-links]]`, broken cross-refs |
| `/second-brain:maintain` | Explicit full consolidation run, incl. draining the raw inbox into wiki nodes |
| `/second-brain:dream` | Staged consolidation — every change reviewed before accept; `--background` supported |
| `/second-brain:review` | Read-only cross-project overview: blockers, stale projects, pending dreams |
| `/second-brain:audit` | What the safety layer did this session (guard verdicts, injection flags) |
| `/second-brain:track` | Register local doc folders/globs to auto-index for retrieval |
| `/second-brain:import-host` | Fold existing `CLAUDE.md`/`AGENTS.md`/`.cursorrules` into the tiers |
| `/second-brain:think` | Opus advisor brief: intent, enrichment, risks (opt-in, ~$0.11/call) |
| `/second-brain:doubt` | Adversarial self-audit of the plugin's own layers |
| `/second-brain:code-review-deep` | Multi-pass PR review with parallel per-unit reviewers and FP-aware scoring |
| `/second-brain:team` | Run one goal as a team: task DAG, tiered team-worker waves, ledgered reports, judged merge gate |

`/second-brain:capture` is documented for its raw-inbox interface (`--list` to inspect, `--discard <id>` to prune) but is not a slash command — capture itself is automatic.

The other four skills (`query`, `using-second-brain`, `capture`, `improve`) are invoked by the
model, not as slash commands. Ten agents back the loop: four code-review reviewers/scorers,
dream-runner, knowledge-maintainer, raw-drainer, quality-reviewer, search-conversations, and
the team-worker wave executor.

## MCP tools

The bundled local MCP server exposes 23 tools (`mcp/src/server.ts`):

- **Knowledge search & write** — `knowledge_search` (BM25 + optional ONNX vectors via RRF), `knowledge_fetch` (tiered page reads), `knowledge_stats`, `knowledge_reindex`, `knowledge_validate`, `pin_to_user`, `pin_to_project`, `archive_to_wiki`
- **Graph** — `knowledge_relate`, `knowledge_neighbors` (typed, bi-temporal relationships; point-in-time walks)
- **Dream** — `dream_create`, `dream_status`, `dream_list`, `dream_accept`, `dream_discard`, `dream_cancel`
- **Episodic** — `episodic_search`, `episodic_read` over archived transcripts
- **Persona** — `persona_think`, `persona_stats`, `persona_dismiss`
- **Code map** — `code_map` (PageRank-ranked structure map), `code_neighbors` (import-graph blast radius)

`bin/sb` is a standalone CLI over the same index — `sb status`, `sb query`, `sb recall`,
`sb pin`, `sb auth doctor` — no Claude session required.

## Data locations & privacy

Two directories under your home, both entirely local:

| Path | Contents |
|---|---|
| `~/.second-brain/` | Runtime state: hot tier (`USER.md`, `projects/`), transcripts, config, audit/error logs |
| `~/knowledge/` | The wiki (standard Markdown + `[[wiki-links]]`, Obsidian-compatible) |

Nothing is synced, pushed, or shared by the plugin — no telemetry, no cloud services, no external
vector DB. Search and embeddings run on-device. The only network calls are Anthropic API calls
for LLM steps: the Stop/PreCompact extractor, the opt-in `/second-brain:think` advisor, and the
optional LLM quality gate. Don't put `~/knowledge/` inside a synced drive.

## Configuration

- **`knowledge_dir`** (plugin userConfig, via `/plugin manage`) — moves the wiki tree; default `~/knowledge`. Runtime state stays in `~/.second-brain/`.
- **`~/.second-brain/config.json`** — persistent settings (e.g. `auto_improve`, `brain_os`).
- **`SB_*` environment variables** — every guard, banner, nudge, and pipeline has a kill switch (`SB_PERSONA_GATE=off`, `SB_SYMLINK_GUARD=off`, `SB_INJECTION_SCAN=off`, …). Precedence: env > config.json > defaults. `sb help` and `sb auth status`/`doctor` are the inspection surface.

## The offline engine (brain-os)

Work that *processes* already-captured knowledge — retention pruning, deterministic upkeep,
precomputing wiki embeddings, the consolidation lane, code-map regen — runs out-of-band behind
one seam, `scripts/brain-os-run.sh`, invoked from the drainer's scheduled tick. Nothing about it
is always-on: there is no daemon, it holds the drainer's single-flight lock, and each pass keeps
its own switch (`auto_improve`, `auto_embed`, `auto_maintain`, `auto_codemap`).

It is **optional by construction** — `brain_os: false` (or `SB_BRAIN_OS=off`) disables the whole
offline lane and capture, retrieval and the in-session `/second-brain:maintain` + `/second-brain:dream`
paths keep working exactly as before.

The consolidation lane inside it is a two-stage split: a **quarantined zero-tool summarizer**
reads transcripts as DATA and can only emit schema-validated candidate facts (its quarantine is
attested at runtime, not assumed), and a **deterministic netless writer** applies those facts to a
dream's staging tree — no LLM, no network, no transcripts in its context. What reaches the live
wiki is governed by `auto_accept` plus a confirm gate: transcript-derived pages with no live
counterpart are *held* (reversible, never deleted) rather than applied unattended, while updates
to pages that already exist apply under an explicit "candidate facts (untrusted)" heading.

## Model-tier routing

Model-tier routing is built in (the team protocol, `skills/team/PROTOCOL.md`); the former
cost-router plugin was absorbed and removed.

## License

MIT
