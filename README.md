## Skills

> **Companion plugin:** the discipline skills (brainstorming, TDD, systematic-debugging, writing-plans, verification-before-completion) come from the upstream [obra/superpowers](https://github.com/obra/superpowers) plugin (>= 5.1.0) — no longer vendored since 0.24.42 (see NOTICE.md). The second-brain works without it; install it for the full workflow loop.

| Skill | Purpose |# Second Brain — Hot-Tier Memory + Local Wiki for Claude Code

A Claude Code plugin that gives Claude a two-layer memory: a small hot tier (`USER.md` + `projects/<slug>/PROJECT.md`) auto-loaded at every SessionStart, and a larger local wiki retrievable on demand. The plugin extracts decisions, blockers, and cross-references from each session via Stop/PreCompact LLM hooks and merges them into the hot tier and wiki. You can still pin manually; the auto-extraction layer surfaces candidates so you don't have to remember to.

**Auth requirement:** the extractor calls the Anthropic API. You can use either an `ANTHROPIC_API_KEY` (token plan, works everywhere) or a Claude subscription via `claude /login` (OAuth, with a known in-session limitation — see [Auth modes](#auth-modes)). All knowledge stays on your machine; nothing is uploaded except the extraction prompts themselves.

## What it does

### 1. Hot-tier auto-load
At SessionStart, the plugin reads `~/.second-brain/USER.md` and the project-scoped `projects/<slug>/PROJECT.md` (slug derived from `git remote` or repo path) and emits them into context. These two files are intentionally short — durable preferences and project facts only. The full wiki stays on disk and is retrievable via `/second-brain:query`.

### 2. Explicit pin tools (MCP)
Three MCP tools — `pin_to_user`, `pin_to_project`, `archive_to_wiki` — let Claude (or you) write a fact into the right tier. Pins are append-with-dedupe; the user confirms each pin before it lands. The `/second-brain:improve` skill proposes up to 3 candidate pins from the current session's evidence and waits for your approval.

### 3. A local wiki it can search
Longer-form notes, sources, and past sessions live in a local wiki, cross-linked so related ideas connect. Claude searches it on demand and gets sharper results when an optional on-device model is present — but it all works offline, and nothing leaves your machine.

### 4. It learns automatically
At the end of a session (and before a context compaction), the plugin quietly captures what mattered — decisions made, problems hit, things worth reusing — and files them into the right place. Memory builds up on its own, so you don't have to remember to save anything. You can still pin facts by hand whenever you want.

### 5. It connects and tidies what it knows
Related notes are linked into a lightweight knowledge graph, so Claude can follow "what depends on what." Each note also carries a short machine-readable summary so an AI can grasp it without re-reading the prose. Over time a consolidation pass merges duplicates and retires stale notes — always reversibly, never a hard delete.

### 6. It can import what you already have
`/second-brain:import-host` finds AI-context files you already keep (`CLAUDE.md`, `AGENTS.md`, `.cursorrules`, and repo-local equivalents) and folds their contents into the right tier — preferences, project facts, or longer notes.

## Installation

In Claude Code, add the marketplace then install the plugin:

```
/plugin marketplace add Cain-Ish/claude-code-plugin
/plugin install second-brain@second-brain
```

First run:

```
/second-brain:setup
```

Then pick an auth mode (see [Auth modes](#auth-modes) below) and check it:

```
sb auth status
```

## Auth modes

The plugin runs LLM extraction (Stop/PreCompact hooks, persona advisor) against
the Anthropic API. Two paths are supported and the plugin auto-detects which
one you're on:

| Mode | How you enable it | Works in-session? | Works in cron/CI? |
|---|---|---|---|
| **API key** (token plan) | `export ANTHROPIC_API_KEY=sk-ant-...` | yes | yes |
| **Subscription** (OAuth) | `claude /login` (interactive browser flow) | **queued — see note** | yes |
| **none** | neither set | nothing extracts; banner warns at session start | — |

**Why subscription mode queues in-session:** A Stop/PreCompact hook fires *from
inside* a Claude Code session, so spawning `claude -p` from the hook re-enters
the same OAuth-locked process and reliably hangs to the timeout. The plugin
detects this and short-circuits to `status=queued` instead of burning the
timeout. To enable in-session extraction on a Claude subscription, either
also export an `ANTHROPIC_API_KEY` (preferred — the API key path doesn't go
through OAuth at all) or run extraction out-of-band via cron/systemd-timer.

**Extraction engine.** Claude is the engine — the universal path that works on
any OS with no extra software: an `ANTHROPIC_API_KEY` extracts in-session, a
subscription extracts out-of-band via the drainer (`install-extract-timer.sh`).
A **local model is optional, off by default**, and purely for offline/privacy:
set `SB_EXTRACTOR_LOCAL_URL=http://localhost:11434` (an ollama / OpenAI-compatible
`/v1` endpoint) and the extractor tries it first, falling back to Claude when it's
unset or can't deliver (e.g. a low-power CPU on a large transcript). The plugin
never assumes a local model is present.

**Auto-consolidation (opt-in).** By default nothing consolidates the knowledge
base unattended — you run `/second-brain:maintain` when you want it tidied. To let
the *content-free* upkeep (validate · project-backfill · reindex) run automatically
in the out-of-band drainer, set `"auto_improve": true` in `~/.second-brain/config.json`
(seeded `false`). This **never** authors prose or makes merge judgements — that
stays on the explicit `/second-brain:maintain` path (a Claude session). Installing
the drainer alone does **not** enable it: it gates on *both* the timer *and*
`auto_improve`. A SessionStart nudge appears when the raw inbox piles up and
auto-consolidation is off (`SB_AUTOCONSOLIDATE_NUDGE=off` to mute).

Inspect or repair your auth setup any time with:

```bash
sb auth status      # which mode is active right now
sb auth doctor      # walk-through of both setup paths
```

`sb auth status` is authoritative: when no `ANTHROPIC_API_KEY` is set it queries
the CLI's own `claude auth status` rather than guessing from `PATH`, so it
distinguishes a real subscription from a **logged-out** machine and from a
claude-managed API key. The probe is bounded by an untrappable timeout
(`SB_AUTH_PROBE_TIMEOUT_MS`, default `3000`, clamped `100..30000`) so a hung or
hijacked `claude` on `PATH` can't block it.

The SessionStart banner always shows the active mode in one line.

## Skills

| Skill | Purpose |
|-------|---------|
| `/second-brain:setup` | Initialize hot-tier files (`USER.md`, `projects/<slug>/PROJECT.md`), wiki dirs, and build the MCP server |
| `/second-brain:upgrade` | Detect installed plugin version and run idempotent migrations |
| `/second-brain:status` | Dashboard of hot-tier and wiki state (line counts, last-pin timestamps, project slug) plus a runtime smoke check via `verify.sh` |
| `/second-brain:query [question]` | Search the wiki via the `knowledge_search` MCP tool (local BM25, with an optional on-device vector boost) |
| `/second-brain:lint` | Health-check the wiki: orphan pages and dead `[[wiki-links]]` |
| `/second-brain:improve` | Propose up to 3 pins (USER.md / PROJECT.md / wiki) from session evidence; user confirms each |
| `/second-brain:doubt` | Adversarial drilling skill — challenge a claim or proposed change before acting |
| `/second-brain:import-host` | Import existing host AI-context files (`CLAUDE.md`, `AGENTS.md`, `.cursorrules`, etc.) into USER.md / PROJECT.md / wiki |
| `/second-brain:recall [query]` | Search past session transcripts via `episodic_search` (hybrid vector + text) |
| `/second-brain:capture <path\|url\|"text">` | Drop unprocessed material (a file, URL, or pasted text) into the project's raw inbox for the maintainer to refine later; `--list` / `--discard <id>` / `--node <slug>` |
| `/second-brain:maintain` | Run the knowledge-maintainer live over the KB — audit, dedup, relate, enrich, author ai-blocks, **and drain the raw inbox into wiki nodes** (the explicit full run; bounded + reversible) |
| `/second-brain:dream` | Background consolidation of the wiki (dedupe, link, prune); **stages** changes for review before accept (vs `maintain`, which writes live) |
| `/second-brain:review` | Read-only cross-project overview: open blockers, stale projects, pending dreams, ungraduated persona signals |
| `/second-brain:audit` | Show what the safety layer did this session — guard verdicts, tool-return flags, wiki-write decisions (read-only) |
| `/second-brain:track` | Register a docs/source location so the next session indexes it for retrieval |
| `/second-brain:using-second-brain` | The persona-as-collaborator protocol — how Claude consults identity, memory, and the tool catalog before answering |
| `/second-brain:code-review-deep [<PR#>]` | Multi-pass deep code review: review-unit decomposition + per-unit reviewers on the best available model (docs on Haiku), a git-history regression lens, an advisory architectural pass on critical/high units, FP-aware scoring with a surfaced lower-confidence band, wiki/episodic context. `--comment` posts to the PR |

The five `Vendored` skills are adapted from [obra/superpowers](https://github.com/obra/superpowers) (MIT). See `NOTICE.md`.

## Persona core

The persona is the *self* of second-brain — identity, memory, tools, judgment. Always present, rarely loud. The architecture follows three patterns from public research: pull-based escalation ([Anthropic Advisor Strategy](https://www.anthropic.com/engineering/multi-agent-research-system)), compile-on-ingest ([Karpathy's LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)), and silence-by-default ([CHI 2025 "Need Help?"](https://dl.acm.org/doi/full/10.1145/3706598.3714002)).

**Five layers:**

| | What | Cost | Always on |
|---|---|---|---|
| 1 Silent infrastructure | persona-card + plugin catalog + wiki hits injected per prompt as factual statements (no LLM) | $0 | yes |
| 2 Pull-based deep brief | `/?` prefix or `/second-brain:think` → Opus advisor brief (intent, enrichment, clarifying Qs, specialists, risks) | ~$0.11/call | opt-in |
| 3 Tool guard | rules-based PreToolUse mutation (strips `2>/dev/null`, asks on `git push --force` to main, `rm -rf`, direct writes to hot-tier files) | $0 | yes |
| 4 Quality Gate | filters low-quality extraction candidates before promotion to wiki (rules-based default; Haiku LLM opt-in) | ~$0.001/session-end | yes |
| 5 MCP surface | `persona_stats`, `persona_dismiss` for self-inspection and dismissal-aware backoff | $0 | on demand |

**Env vars:**
- `SB_PERSONA_GATE=off` — disable all persona hooks
- `SB_PERSONA_MODEL` — change Layer 2 model (default `claude-opus-4-7`)
- `SB_PERSONA_DAILY_BUDGET` — kill switch when daily spend exceeds (USD, default 20)
- `SB_QUALITY_GATE=off` — disable Layer 4
- `SB_QUALITY_GATE_LLM=on` — enable Haiku validation in Layer 4 (default rules-only)
- `SB_QUALITY_GATE_STRICTNESS=aggressive` — Layer 4 rejects more (~30% vs default ~10%)
- `SB_MAINTAINER_AUTO` — `off` suppresses the SessionStart "wiki maintenance suggested" banner. (default `on`) — note: the plugin does **not** auto-dispatch the maintainer (explicit-invocation only, per the Anthropic doctrine rethink in 0.21.0); the banner just nudges you to run `/second-brain:maintain` (live) or `/second-brain:dream` (staged).
- `SB_MAINTAINER_THRESHOLD` — wiki-write count at which that suggestion banner appears. Higher = less frequent nudging. (default `3`)
- `SB_MAINTAINER_MAX_FAILS` — fail-count for the retained manual reconcile path (`DISP_FILE`) that creates the per-project `.maintainer-auto-disabled` marker; the auto path no longer creates `DISP_FILE` itself. Delete the marker to re-arm. (default `3`)

**User-editable files:**
- `~/.second-brain/persona-card.md` — your identity card. Read by Layer 1; the plugin never auto-rewrites it.
- `~/.second-brain/persona-rules.json` — Layer 3 tool guard rules. Override the defaults shipped at `scripts/persona-rules.default.json`.

**Cost ceiling** with all hooks on, 50 substantive prompts + 5 session-ends + 10 explicit `/?` invocations per day: ~$1.10/day, ~$33/month. `SB_PERSONA_DAILY_BUDGET` enforces a hard cap.

## Standalone CLI

`bin/sb` is a shell shim that lets you use the wiki and episodic index from any terminal — no Claude session required.

```bash
# One-time build (only if installing from source)
cd mcp && npm install && npm run build

# Put on PATH
ln -s "$(pwd)/bin/sb" ~/.local/bin/sb     # macOS/Linux
# Windows: add the repo's bin/ directory to PATH

sb help
sb status                                    # hot-tier + wiki sizes
sb query "BM25 hybrid scoring"               # search the wiki
sb recall "how did we fix the migration?"    # search past conversations
sb pin user "prefer terse responses"         # append to USER.md
sb pin project myrepo blockers "stuck on X"  # append to project blockers
```

Resolution order for the dirs: `BRAIN_DIR` env → `~/.second-brain`; `KNOWLEDGE_DIR` → `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` → `~/knowledge`.

## MCP Server

The plugin includes a local MCP server. Tools:

| Tool | Purpose |
|---|---|
| `knowledge_search` | BM25-scored full-content search over `~/knowledge/wiki/`. Field-weighted (title 3x, description 2x, tags 2x, body 1x). Optional ONNX vector ranking (`Xenova/all-MiniLM-L6-v2`) fused via RRF when `@huggingface/transformers` is installed — automatic via the upgrade skill. |
| `knowledge_reindex` | Regenerate `wiki/index.md` catalog; runs validation with autofix |
| `knowledge_validate` | Health-check the wiki (broken links, orphans, duplicate slugs, empty pages) |
| `knowledge_stats` | Wiki size + per-category counts |
| `episodic_search` | Hybrid vector + text search over archived transcripts (`~/.second-brain/transcripts/`) |
| `episodic_read` | Read a specific transcript range by line numbers |
| `pin_to_user` | Append-with-dedupe write to `USER.md` |
| `pin_to_project` | Append-with-dedupe write to a project's `PROJECT.md` |
| `archive_to_wiki` | Write a longer-form note as a wiki page |
| `knowledge_relate` | Assert (or retire) a typed relationship between two pages |
| `knowledge_neighbors` | Walk a page's relationship neighbourhood (multi-hop, point-in-time) |
| `dream_*` | 6 tools for background knowledge consolidation (`create`, `status`, `list`, `accept`, `discard`, `cancel`) |
| `persona_stats`, `persona_dismiss`, `persona_think` | Layer 5 persona surface |

The compiled artifact `mcp/dist/server.bundle.js` and tool-specific bundles in `mcp/dist/tools/` are shipped in the repo, so a marketplace install works out of the box.

**One required post-install step for vector search**: `@huggingface/transformers` is bundled as `--external` (its native dependencies can't be statically packed), so it lives in `mcp/node_modules/` rather than the dist bundle. The `/second-brain:upgrade` skill detects and installs it automatically. To install manually:

```bash
bash "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh"   # ~70 MB native deps, one-time
```

If transformers isn't installed, `knowledge_search` degrades cleanly to BM25-only and `episodic_search` to text-only — a SessionStart banner flags the degradation and points at the installer.

To rebuild from source:

```bash
cd mcp && npm install && npm run build
```

## Where files live

The plugin uses two top-level directories under your home:

| Path (POSIX shorthand) | Linux / macOS | Windows (Git Bash / WSL) | Windows (cmd / PowerShell) |
|---|---|---|---|
| `~/.second-brain/` | `/home/<user>/.second-brain/` | `/c/Users/<user>/.second-brain/` (mapped) or `C:\Users\<user>\.second-brain\` | `%USERPROFILE%\.second-brain\` |
| `~/knowledge/` | `/home/<user>/knowledge/` | `/c/Users/<user>/knowledge/` or `C:\Users\<user>\knowledge\` | `%USERPROFILE%\knowledge\` |

If you set a custom `knowledge_dir` via `/plugin manage`, only the wiki tree moves — `~/.second-brain/` (learning state) always stays under your home. The custom value reaches every script via the auto-injected `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` env var; if it's not set, everything falls through to `~/knowledge`.

## Cross-platform support

The plugin is tested on:

- **Linux** — bash via shell hooks; Node 22+ for the MCP server (the primary target).
- **macOS** — same, with BSD coreutils and the stock `/bin/bash` **3.2** in mind: scripts avoid bash-4-only features (no `mapfile`/`readarray`, associative arrays, or `${x^^}`/`${x,,}`), and every GNU/BSD coreutils divergence is dual-pathed — `stat -c … || stat -f`, `date -d … || date -v`, `command -v timeout || command -v gtimeout`, fixed-string grep instead of PCRE `-P`, and a portable `realpath -m … || cd "$(dirname)" && pwd -P` resolver. Install GNU coreutils (`brew install coreutils`) for the optional `timeout`/`gtimeout` extraction bound; without it extraction simply runs unbounded.
- **Windows** — Git Bash from *Git for Windows* (or WSL) for the shell hooks; Node from the standard installer for the MCP server. Native cmd/PowerShell is **not** supported — the hooks run bash scripts, so a POSIX shell is required.

Path resolution uses the cross-platform-safe `$HOME` (Git Bash maps it to `/c/Users/<user>`) and Node's `os.homedir()`. CRLF line endings are handled (jq on Windows emits CRLF; the validator strips it). Portability is enforced by `tests/test-script-portability.sh`, which fails the suite on a re-introduced bash-4 builtin, unpaired `stat -c`/`date -d`, or PCRE `grep -P`. Tests require `jq`, `mktemp`, and `bash` — all bundled with Git Bash.

## Privacy

**Hard rule: all knowledge stays local. Nothing is synced, pushed, or shared externally by the core plugin.**

- Plugin code (shareable via marketplace): zero user data
- Knowledge base (`~/knowledge/`): completely local, never synced
- Hot-tier state (`~/.second-brain/`): completely local, never synced
- Search: runs locally — BM25 over your wiki files plus an optional on-device model; no cloud service, no external vectordb
- No telemetry, no cloud services, no API calls
- `.nosync` marker files are created on macOS to prevent iCloud sync (no-op on Windows/Linux — sync providers there have their own ignore mechanisms)

### What does talk to the network

The plugin makes Anthropic API calls in three places, and nothing else:

1. **Stop / PreCompact extractor** — sends the preprocessed session transcript (decisions, blockers, cross-references, files touched — roughly 15–20 KB after the jq preprocessor strips tool-result payloads and attachments) to whichever Anthropic endpoint your auth mode uses. Default model `claude-sonnet-4-6`, configurable via `SB_EXTRACTOR_MODEL`.
2. **Persona Layer 2 advisor brief** — opt-in only, via `/?` prefix or `/second-brain:think`. Calls `claude-opus-4-7` by default; hard daily cap via `SB_PERSONA_DAILY_BUDGET` (default $20).
3. **Persona Layer 4 quality gate (optional)** — when `SB_QUALITY_GATE_LLM=on`, calls Haiku to validate extraction candidates before merge. Default is rules-only (no network).

**Kill switches:** `SB_PERSONA_GATE=off` disables Layer 2+3+4 entirely. The extractor can be silenced by removing `Stop`/`PreCompact` hooks from `hooks/hooks.json`. Knowledge base, wiki, and `sb` CLI search are 100% local — `knowledge_search` and `episodic_search` never touch the network. Embeddings, when enabled, run on-device via ONNX (`Xenova/all-MiniLM-L6-v2`); the model itself is downloaded once on first use by the bundled `@huggingface/transformers` runtime.

If you bring your own MCP servers (Context7, web-fetch, etc.) those have their own network behavior; the second-brain plugin does not.

### Obsidian Users

The knowledge base at `~/knowledge/` is fully compatible with Obsidian (uses standard Markdown + `[[wiki-links]]`). However:

- **Do NOT enable Obsidian Sync** for the knowledge vault — your second brain should never leave your machine
- **Do NOT place the knowledge directory inside iCloud Drive, Dropbox, Google Drive, or OneDrive**
- If you use Obsidian, open `~/knowledge/` as a local-only vault with no sync plugins enabled

## How memory flows

```
Session N
  ├─ SessionStart loads your hot tier (USER.md + this project's PROJECT.md) into context
  ├─ Claude works; you can pin anything important by hand at any time
  └─ At the end (and before a context compaction), the extractor captures what
     mattered and files it for you — into the hot tier, the wiki, and the graph

Session N+1
  └─ The new knowledge is already loaded; relevant wiki notes surface on demand —
     scoped to the active project first, so you don't get another project's noise

Result: memory builds up on its own, plus whatever you pin by hand. Everything stays
        on your machine — written to your local knowledge base, never to your repo,
        never to the cloud.
```

You can also feed it explicitly, for material the extractor wouldn't catch on its own:

```
/second-brain:capture <file|url|"note">   ─┐  drop unprocessed material into the
/second-brain:setup   (scans a repo's docs) ─┤  per-project raw INBOX (held out of search)
                                              │
/second-brain:maintain  ──────────────────────┘─▶  the maintainer DRAINS the inbox into
                                                    proper wiki nodes (create/update, with
                                                    provenance) and consolidates the wiki
```

The inbox is a staging area: captured material is *not* searched until the maintainer refines
it into a wiki node — so a quick `capture` never pollutes retrieval, and you review what it
became via the normal wiki.

## Testing

Tests run in isolation under `mktemp` sandboxes (no real user data is touched). Require `jq`, `mktemp`, `bash`, and Node 22+ for the Vitest suite.

**Run the whole suite** — shell + vitest — with one command:

```bash
make test                       # or: bash tests/run-all.sh
```

Currently this runs 72 shell test suites + 357 vitest assertions (and grows with each feature). Output is a per-test verdict and a summary; exit code is non-zero on any failure.

**Install the pre-push gate** so broken commits cannot be pushed:

```bash
make hook-install               # sets core.hooksPath = .githooks
```

After install, every `git push` re-runs `tests/run-all.sh`. Bypass for one push (emergency only) via `SB_SKIP_PREPUSH=1 git push`. See `RELEASING.md` for the full release checklist.

To run individual tests:

```bash
bash tests/test-validate-plugin.sh                # plugin-structure validator
bash tests/test-lib-extractor-backend.sh          # extractor auth-mode selection
bash tests/test-upgrade-vector-deps.sh            # upgrade-skill vector-deps gate
bash tests/test-session-load-auth-banner.sh       # SessionStart auth-mode banner
# (full list: ls tests/test-*.sh)
```

## License

MIT
