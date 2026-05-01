# Second Brain — Hot-Tier Memory + Local Wiki for Claude Code

A Claude Code plugin that gives Claude a two-layer memory: a small hot tier (`USER.md` + `projects/<slug>/PROJECT.md`) auto-loaded at every SessionStart, and a larger local wiki retrievable on demand. **Memory is explicit: you pin what's worth remembering. There is no autonomous extraction, no critic loop, no auto-PR.**

## What it does

### 1. Hot-tier auto-load
At SessionStart, the plugin reads `~/.second-brain/USER.md` and the project-scoped `projects/<slug>/PROJECT.md` (slug derived from `git remote` or repo path) and emits them into context. These two files are intentionally short — durable preferences and project facts only. The full wiki stays on disk and is retrievable via `/second-brain:query`.

### 2. Explicit pin tools (MCP)
Three MCP tools — `pin_to_user`, `pin_to_project`, `archive_to_wiki` — let Claude (or you) write a fact into the right tier. Pins are append-with-dedupe; the user confirms each pin before it lands. The `/second-brain:improve` skill proposes up to 3 candidate pins from the current session's evidence and waits for your approval.

### 3. Local wiki + ripgrep search
A Karpathy-inspired wiki under `~/knowledge/wiki/` holds longer-form notes, sources, and archived sessions, cross-referenced via `[[wiki-links]]`. The `knowledge_search` MCP tool searches it with ripgrep — no embeddings, no vectordb, no API calls. All knowledge stays on your machine.

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
| `/second-brain:status` | Dashboard of hot-tier and wiki state (line counts, last-pin timestamps, project slug) |
| `/second-brain:query [question]` | Search the wiki via the `knowledge_search` MCP tool (ripgrep backend) |
| `/second-brain:lint` | Health-check the wiki: orphan pages and dead `[[wiki-links]]` |
| `/second-brain:improve` | Propose up to 3 pins (USER.md / PROJECT.md / wiki) from session evidence; user confirms each |
| `/second-brain:doubt` | Adversarial drilling skill — challenge a claim or proposed change before acting |
| `/second-brain:import-host` | Import existing host AI-context files (`CLAUDE.md`, `AGENTS.md`, `.cursorrules`, etc.) into USER.md / PROJECT.md / wiki |

## MCP Server

The plugin includes a local MCP server with four tools:

- `knowledge_search` — ripgrep search over `~/knowledge/wiki/` (no embeddings, no vectordb, no API calls)
- `pin_to_user` — append-with-dedupe write to `~/.second-brain/USER.md`
- `pin_to_project` — append-with-dedupe write to `~/.second-brain/projects/<slug>/PROJECT.md`
- `archive_to_wiki` — write a longer-form note as a wiki page

The compiled artifact `mcp/dist/server.js` is shipped in the repo, so a marketplace install works out of the box. To rebuild after pulling source changes:

```bash
cd mcp && npm install && npm run build
```

`/second-brain:setup` runs this automatically if `dist/server.js` is missing. `ripgrep` must be on PATH for `knowledge_search` to function.

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
- Search: ripgrep over local wiki files — no embeddings, no vectordb, no model download
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
        /second-brain:query (ripgrep).
```

## Testing

Tests run in isolation under `mktemp` sandboxes (no real user data is touched). Require `jq`, `mktemp`, and `bash`.

```bash
bash tests/test-validate-plugin.sh       # plugin-structure validator
bash tests/test-stop-hook-predicate.sh   # 4-condition stop-hook predicate
bash tests/test-hooks-regression.sh      # hooks.json regression suite
```

To run the plugin-structure validator against this repo directly:

```bash
bash scripts/validate-plugin.sh
```

## License

MIT
