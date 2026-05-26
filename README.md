# Second Brain — Hot-Tier Memory + Local Wiki for Claude Code

A Claude Code plugin that gives Claude a two-layer memory: a small hot tier (`USER.md` + `projects/<slug>/PROJECT.md`) auto-loaded at every SessionStart, and a larger local wiki retrievable on demand. The plugin extracts decisions, blockers, and cross-references from each session via Stop/PreCompact LLM hooks and merges them into the hot tier and wiki. You can still pin manually; the auto-extraction layer surfaces candidates so you don't have to remember to.

**Auth requirement:** the extractor calls the Anthropic API. You can use either an `ANTHROPIC_API_KEY` (token plan, works everywhere) or a Claude subscription via `claude /login` (OAuth, with a known in-session limitation — see [Auth modes](#auth-modes)). All knowledge stays on your machine; nothing is uploaded except the extraction prompts themselves.

## What it does

### 1. Hot-tier auto-load
At SessionStart, the plugin reads `~/.second-brain/USER.md` and the project-scoped `projects/<slug>/PROJECT.md` (slug derived from `git remote` or repo path) and emits them into context. These two files are intentionally short — durable preferences and project facts only. The full wiki stays on disk and is retrievable via `/second-brain:query`.

### 2. Explicit pin tools (MCP)
Three MCP tools — `pin_to_user`, `pin_to_project`, `archive_to_wiki` — let Claude (or you) write a fact into the right tier. Pins are append-with-dedupe; the user confirms each pin before it lands. The `/second-brain:improve` skill proposes up to 3 candidate pins from the current session's evidence and waits for your approval.

### 3. Local wiki + token-overlap search
A Karpathy-inspired wiki under `~/knowledge/wiki/` holds longer-form notes, sources, and archived sessions, cross-referenced via `[[wiki-links]]`. The `knowledge_search` MCP tool uses a fast Node filesystem walk + token-overlap scoring (no embeddings, no API calls, no external dependencies). All knowledge stays on your machine.

### 4. Stop-hook predicate
A 4-condition boolean diff at Stop time decides whether the session is worth offering a pin proposal for. No background extraction, no friction logging — the predicate fires only when the session crossed concrete thresholds (e.g. files touched, baseline divergence).

### 5. Host AI-context import
`/second-brain:import-host` finds existing AI-context files on your machine (`~/CLAUDE.md`, `~/AGENTS.md`, `.cursorrules`, repo-local equivalents) and routes their contents into the right tier — durable preferences to USER.md, project facts to PROJECT.md, longer narrative to wiki.

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

Inspect or repair your auth setup any time with:

```bash
sb auth status      # which mode is active right now
sb auth doctor      # walk-through of both setup paths
```

The SessionStart banner always shows the active mode in one line.

## Skills

| Skill | Purpose |
|-------|---------|
| `/second-brain:setup` | Initialize hot-tier files (`USER.md`, `projects/<slug>/PROJECT.md`), wiki dirs, and build the MCP server |
| `/second-brain:upgrade` | Detect installed plugin version and run idempotent migrations |
| `/second-brain:status` | Dashboard of hot-tier and wiki state (line counts, last-pin timestamps, project slug) plus a runtime smoke check via `verify.sh` |
| `/second-brain:query [question]` | Search the wiki via the `knowledge_search` MCP tool (Node fs walk + token-overlap scoring) |
| `/second-brain:lint` | Health-check the wiki: orphan pages and dead `[[wiki-links]]` |
| `/second-brain:improve` | Propose up to 3 pins (USER.md / PROJECT.md / wiki) from session evidence; user confirms each |
| `/second-brain:doubt` | Adversarial drilling skill — challenge a claim or proposed change before acting |
| `/second-brain:import-host` | Import existing host AI-context files (`CLAUDE.md`, `AGENTS.md`, `.cursorrules`, etc.) into USER.md / PROJECT.md / wiki |
| `/second-brain:recall [query]` | Search past session transcripts via `episodic_search` (hybrid vector + text) |
| `/second-brain:dream` | Background consolidation of the wiki (dedupe, link, prune); staging area, review before accept |
| `/second-brain:review` | Read-only cross-project overview: open blockers, stale projects, pending dreams, ungraduated persona signals |
| `/second-brain:code-review-deep [<PR#>]` | Multi-pass deep code review: review-unit decomposition + per-unit reviewers on the best available model (docs on Haiku), an advisory architectural pass on critical/high units, FP-aware scoring, wiki/episodic context, false-positive memory. `--comment` posts to the PR |
| `/second-brain:brainstorming` | Vendored from obra/superpowers — pause-and-design before implementation |
| `/second-brain:writing-plans` | Vendored — write detailed implementation plan from a spec |
| `/second-brain:test-driven-development` | Vendored — red-green-refactor discipline |
| `/second-brain:verification-before-completion` | Vendored — evidence before completion claims |
| `/second-brain:systematic-debugging` | Vendored — 4-phase root-cause-first debugging |

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
- `SB_MAINTAINER_AUTO` — `off` disables auto-dispatch of `knowledge-maintainer` from SessionStart entirely. State files still update but are not read. (default `on`)
- `SB_MAINTAINER_THRESHOLD` — wiki-write count at which the next SessionStart auto-dispatches the maintainer. Higher = less frequent consolidation. (default `3`)
- `SB_MAINTAINER_MAX_FAILS` — consecutive failure count that creates the per-project `.maintainer-auto-disabled` marker. Delete the marker manually to re-arm. (default `3`)

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

- **Linux** — bash via shell hooks; Node 22+ for the MCP server
- **macOS** — same; `tr`-based path normalization avoids GNU-only sed flags
- **Windows** — Git Bash from `git for windows` for the shell hooks; Node from the standard installer for the MCP server. Native cmd/PowerShell isn't supported because the hooks run bash scripts.

Path resolution uses the cross-platform-safe `$HOME` (Git Bash maps it to `/c/Users/<user>`), and Node's `os.homedir()`. No GNU-only flags. JSON output handles CRLF line endings (jq on Windows emits CRLF; the validator strips it). Tests require `jq`, `mktemp`, and `bash` — all bundled with Git Bash.

## Privacy

**Hard rule: all knowledge stays local. Nothing is synced, pushed, or shared externally by the core plugin.**

- Plugin code (shareable via marketplace): zero user data
- Knowledge base (`~/knowledge/`): completely local, never synced
- Hot-tier state (`~/.second-brain/`): completely local, never synced
- Search: Node filesystem walk + token-overlap scoring over local wiki files — no embeddings, no vectordb, no model download
- No telemetry, no cloud services, no API calls
- `.nosync` marker files are created on macOS to prevent iCloud sync (no-op on Windows/Linux — sync providers there have their own ignore mechanisms)

### What does talk to the network

The v2.x plugin makes Anthropic API calls in three places, and nothing else:

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
  ├─ SessionStart reads USER.md + projects/<slug>/PROJECT.md → emits as context
  ├─ Baseline captured (current hot-tier line counts + last-modified timestamps)
  ├─ Claude works; if something's worth remembering, it (or you) calls a pin MCP tool:
  │     pin_to_user      → durable preference, applies across all projects
  │     pin_to_project   → project-scoped fact, slug-routed
  │     archive_to_wiki  → longer-form note that doesn't belong in the hot tier
  └─ Stop hook → predicate evaluates 4 conditions vs. baseline; if any fired,
                 emits a one-line nudge: "consider /second-brain:improve to propose pins"

Session N+1 (SessionStart)
  └─ Same hot-tier load; pins from Session N are now part of the auto-loaded context

Result: memory is what *you* pinned. No autonomous writes, no background extraction,
        no PR opened against your repo. The wiki is searched on demand via
        /second-brain:query (token-overlap search).
```

## Testing

Tests run in isolation under `mktemp` sandboxes (no real user data is touched). Require `jq`, `mktemp`, `bash`, and Node 22+ for the Vitest suite.

**Run the whole suite** — shell + vitest — with one command:

```bash
make test                       # or: bash tests/run-all.sh
```

Currently this runs 24 shell tests + 59 vitest assertions. Output is a per-test verdict and a summary; exit code is non-zero on any failure.

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
