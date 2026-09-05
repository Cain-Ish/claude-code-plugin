# Second Brain — Claude Code's memory of the project

A local-first memory layer for Claude Code. It gives Claude the mental model a senior dev holds
before opening a file — what exists, where it lives, why it's shaped that way — via a small hot
tier (`USER.md` + per-project `PROJECT.md`) auto-loaded every session and a larger local wiki
retrieved on demand. It learns on its own: hooks extract decisions, blockers, and learnings from
each session, and consolidation applies them to the knowledge base reversibly and fully
unattended — on every OS (Linux, macOS, Windows) where `brain_os` and `auto_maintain` are on
(both default on). On Linux, bubblewrap additionally sandboxes the consolidation spawn as
defense-in-depth; its absence gates nothing anywhere else. `auto_accept: "safe"` (the default)
still holds untrusted-only new pages for review rather than applying them unattended — see "The
offline engine" below.

## What it remembers

Four content classes, and only four — the things a senior dev carries between sessions and cannot
recover from a diff:

| Class | Where it lives |
|---|---|
| **Decisions** — what was chosen, what was rejected, why | `wiki/decisions/`, `pin_to_project`, `knowledge_relate` (`supersedes`) |
| **Architecture & high-level design** — why-this-way, invariants, constraints | `wiki/concepts/`, `wiki/entities/`, `wiki/themes/`, the typed graph |
| **Code map** — what exists, where, what breaks if it changes | `code_map`, `code_neighbors` (PageRank structure + import-graph blast radius) |
| **Session recap** — what mattered, distilled before the context closes | Stop/PreCompact extraction, `episodic_search`, `sessions-digest.jsonl` |

A surface that does not produce, store, or deliver one of these four is not memory and does not
belong here — however good a tool it is. The mission, that scope rule, and the hard constraints
(full autonomy, untrusted-content isolation, cross-platform) are fixed in
[CONSTITUTION.md](CONSTITUTION.md); the gates that enforce them are named there.
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

Nine hook events wire the autonomous loop (`hooks/hooks.json`):

- **SessionStart** — ensures dirs, discovers installed plugins and tracked doc sources, loads the hot tier into context, banners pending/suggested dreams.
- **UserPromptSubmit** — injects persona card, catalog, and relevant wiki hits per prompt (no LLM call).
- **PreToolUse** — rules-based guards: tool guard (risky bash, hot-tier writes), wiki-write guard, symlink guard (denies writes resolving into `~/.ssh` and friends), outbound credential-flow guard, and a plan-first gate — with `SB_INTENT_SPINE` on (the default), it hard-denies-once on multi-file code work with no plan on record (Gate A) and again on goal drift (Gate B); `SB_INTENT_SPINE=off` restores the original advisory-only nudge that never blocks.
- **PostToolUse** — quality gate on writes, injection-pattern scan of tool returns (telemetry, never blocks), simplicity nudge on large single changes, observation ledger.
- **PostToolUseFailure** — the observation ledger's failure side. `PostToolUse` fires only on success, so without this event every FAILED tool call — the error→fix pattern the ledger exists to mine — left no record.
- **Stop** — verify gate, then the LLM extractor files what mattered into hot tier + wiki; SAR safety-summary banner.
- **SubagentStop** — archives substantive subagent results into the episodic transcript store.
- **PreCompact** — same extraction before a context compaction, so nothing is lost to the window.
- **ConfigChange** — audit-logs every settings/skills change (never blocks).

Nearly every guard and pipeline has an `SB_*` kill switch — including the PostToolUse quality
gate (`SB_QUALITY_GATE=off`) and Stop/PreCompact LLM extraction (`SB_EXTRACT=off`). The one
committed exception is the always-included `PROJECT.md`/`USER.md` hot-tier injection at
SessionStart, which has no independent off switch yet. Consolidation itself stays reversible:
dreams stage changes for review, forgetting archives rather than deletes.

## Commands

13 user-invocable skills:

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

One output style, `second-brain:dev-focused` (select it under `/config` > Output style, or set `"outputStyle": "second-brain:dev-focused"` in settings). It shapes every reply for a reader who needs to act now: next action first, numbered steps, state restated each turn, no tangents, concrete time estimates, and work routed to the cheapest model tier (SCOUT/DO/THINK) that can do it. Opt-in only; it never overrides your chosen style.

`/second-brain:capture` documents the raw-inbox CLI (`--list` to inspect, `--discard <id>` to
prune); its frontmatter disables both user AND model invocation, so nothing can invoke it as a
skill — it exists to document the bundled `raw-capture-cli` for direct/scripted use. The only
automatic path into the raw inbox is `/second-brain:setup`'s one-time deep-scan.

`query` and `using-second-brain` are invoked by the model, not as slash commands. Four agents
back the loop: `dream-runner`, `knowledge-maintainer`, `raw-drainer`, and `search-conversations`
— consolidation and recall, nothing else.

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
| `~/.second-brain/` | Runtime state: hot tier (`USER.md`, `projects/`), transcripts, config, audit/error logs, dream working state (`dreams/`), and two IRREPLACEABLE stores worth backing up: `wiki-archive/` (the only copy of pages FORGET has archived) and, when `wiki_git: true`, `wiki-history.git/` (the reversibility window for unattended writes) |
| `~/knowledge/` | The wiki (standard Markdown + `[[wiki-links]]`, Obsidian-compatible) plus `graph/` (`edges.jsonl`, `project-registry.jsonl` — the typed relationship graph) |

Nothing is synced, pushed, or shared by the plugin — no telemetry, no cloud services, no external
vector DB. Search and embeddings run on-device. LLM network calls go to the Anthropic API: the
Stop/PreCompact extractor, the opt-in `/second-brain:think` advisor, and the optional LLM quality
gate. Two other network paths exist outside that: the optional vector-search tier fetches its
~70 MB embedding model from huggingface.co on first use (`bin/install-vector-deps.sh`, then
`@huggingface/transformers` at runtime) unless you never install vector deps, and that same
installer runs `npm install` against the npm registry. Don't put `~/knowledge/` inside a synced
drive.

## Configuration

- **`knowledge_dir`** (plugin userConfig, via `/plugin manage`) — moves the wiki tree; default `~/knowledge`. Runtime state stays in `~/.second-brain/`.
- **`~/.second-brain/config.json`** — persistent settings (e.g. `auto_improve`, `brain_os`).
- **`SB_*` environment variables** — nearly every guard, banner, nudge, and pipeline has a kill switch (`SB_PERSONA_GATE=off`, `SB_SYMLINK_GUARD=off`, `SB_INJECTION_SCAN=off`, `SB_QUALITY_GATE=off`, `SB_EXTRACT=off`, …) — the always-included hot-tier injection is the one exception. Precedence: env > config.json > defaults. `sb help` and `sb auth status`/`doctor` are the inspection surface.

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

Model-tier routing is built in: `model-ladder.json` is the single manifest of tiers and pins,
consumed by extraction, compaction, and consolidation (`stop-extract.sh`, `pre-compact.sh`,
`maintain-llm-drain.sh`). No model ID is hardcoded anywhere else — `tests/test-model-ladder.sh`
fails the suite if one appears.

## License

MIT
