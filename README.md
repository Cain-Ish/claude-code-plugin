# Second Brain — Hot-Tier Memory + Local Wiki for Claude Code

A Claude Code plugin that gives Claude a two-layer memory: a small hot tier (`USER.md` + `projects/<slug>/PROJECT.md`) auto-loaded at every SessionStart, and a larger local wiki retrievable on demand. **Memory is explicit: you pin what's worth remembering. There is no autonomous extraction, no critic loop, no auto-PR.**

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
| `/second-brain:brainstorming` | Vendored from obra/superpowers — pause-and-design before implementation |
| `/second-brain:writing-plans` | Vendored — write detailed implementation plan from a spec |
| `/second-brain:test-driven-development` | Vendored — red-green-refactor discipline |
| `/second-brain:verification-before-completion` | Vendored — evidence before completion claims |
| `/second-brain:systematic-debugging` | Vendored — 4-phase root-cause-first debugging |

The five `Vendored` skills are adapted from [obra/superpowers](https://github.com/obra/superpowers) (MIT). See `NOTICE.md`.

## Persona core (v2.3.0)

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

The plugin includes a local MCP server with four tools:

- `knowledge_search` — Node filesystem walk + token-overlap scoring over `~/knowledge/wiki/` (no embeddings, no vectordb, no API calls, no external binaries)
- `pin_to_user` — append-with-dedupe write to `~/.second-brain/USER.md`
- `pin_to_project` — append-with-dedupe write to `~/.second-brain/projects/<slug>/PROJECT.md`
- `archive_to_wiki` — write a longer-form note as a wiki page

The compiled artifact `mcp/dist/server.js` is shipped in the repo, so a marketplace install works out of the box. To rebuild after pulling source changes:

```bash
cd mcp && npm install && npm run build
```

`/second-brain:setup` runs this automatically if `dist/server.js` is missing. `knowledge_search` runs entirely in-process (Node `fs` walk over `~/knowledge/wiki/` with token-overlap scoring) — no external binary required.

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

Nothing in the v1.0 default install. The plugin makes no network calls — no friction logging, no auto-improve PRs, no embedding model download. If you bring your own MCP servers (Context7, web-fetch, etc.) those have their own network behavior; the second-brain plugin does not.

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

Tests run in isolation under `mktemp` sandboxes (no real user data is touched). Require `jq`, `mktemp`, and `bash`.

```bash
bash tests/test-validate-plugin.sh                # plugin-structure validator
bash tests/test-validate-plugin-allowed-tools.sh  # allowed-tools frontmatter rule
bash tests/test-stop-hook-predicate.sh            # 4-condition stop-hook predicate
bash tests/test-hooks-regression.sh               # hooks.json regression suite
bash tests/test-session-load-compact.sh           # SessionStart-on-compact re-emit
bash tests/test-verify.sh                         # runtime smoke check (verify.sh)
```

To run the plugin-structure validator against this repo directly:

```bash
bash scripts/validate-plugin.sh
```

## License

MIT
