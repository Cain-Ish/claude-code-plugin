# Second Brain — Self-Evolving AI Plugin for Claude Code

A Claude Code plugin that automatically gets smarter with every session. It learns from your patterns, discovers your tools, builds a personal knowledge base, self-critiques its own code quality, and thinks like a senior human developer.

## Five Capabilities

### 1. Auto Self-Improvement
The plugin automatically analyzes each session, extracts learnings from successes and failures, and stores them for future reference. No manual trigger needed — reflection happens automatically between sessions.

### 2. Dynamic Tool Discovery
At session start, the plugin enumerates the names of installed MCP servers (from your Claude Code settings and plugin caches) and writes them to `~/.second-brain/tool-registry.json`. Skills check this registry and prefer matching servers when present — Context7 for docs, custom memory servers, etc. It is a server-name index, not a tool-level capability map.

### 3. Local Second Brain
A Karpathy-inspired LLM-maintained wiki with semantic search. Ingest articles, papers, and notes — the plugin creates structured wiki pages with cross-references. Session insights are automatically added to the wiki. All knowledge stays on your machine.

### 4. Code Quality Self-Critique
After every code write/edit, a quality gate automatically reviews the code against evolving standards. When the plugin detects you correcting its output, it learns the pattern and catches it automatically next time.

### 5. Human Developer Persona
Claude thinks and acts like a senior human developer. It analyzes what you *actually* need (not just what you typed), proactively fills in unstated requirements, writes human-style code and commit messages with zero AI markers, and verifies tech choices against current best practices. The persona evolves as it learns your preferences.

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
| `/second-brain:setup` | Initialize knowledge base and learning directories |
| `/second-brain:ingest [path\|url]` | Process a source into the knowledge wiki |
| `/second-brain:query [question]` | Search the knowledge base |
| `/second-brain:browse [category]` | Browse and visualize knowledge base content |
| `/second-brain:status` | Dashboard of knowledge base health |
| `/second-brain:lint` | Health-check the wiki |
| `/second-brain:improve` | Deep manual session analysis |
| `/second-brain:review [file]` | Deep code review beyond the quality gate |

## MCP Server

The plugin includes a local MCP server for semantic search over the knowledge base. It uses `@xenova/transformers` (all-MiniLM-L6-v2) to generate embeddings locally — no API calls, no data leaving your machine.

Build:
```bash
cd mcp && npm install && npm run build
```

## Privacy

**Hard rule: all knowledge stays local. Nothing is synced, pushed, or shared externally by the core plugin.**

- Plugin code (shareable via marketplace): zero user data
- Knowledge base (`~/knowledge/`): completely local, never synced
- Learning state (`~/.second-brain/`): completely local, never synced
- Embeddings: generated locally via ONNX Runtime in Node.js
- No telemetry, no cloud services, no API calls for the core knowledge base
- `.nosync` marker files are created on macOS to prevent iCloud sync (no-op on Windows/Linux — sync providers there have their own ignore mechanisms)

### What does talk to the network

- **Friction logging.** Prompts that look like corrections (e.g. "fix", "no, …", "wrong", "again") are appended to `~/.second-brain/friction-log.jsonl` with timestamp and prompt text. The file stays on your machine — but be aware it's a record of what you said when you were unhappy with the assistant. Wipe with `: > ~/.second-brain/friction-log.jsonl`. Other prompts are not logged.
- **Auto-improve (opt-in via `~/.second-brain/config.json` → `"auto_improve": true`).** When enabled, the plugin will branch, commit, push, and call `gh pr create` against your fork on GitHub. This *does* leave your machine. Default is off.
- **First MCP server start** downloads the embedding model (`Xenova/all-MiniLM-L6-v2`) from HuggingFace into the transformers cache. Subsequent runs are offline.

### Obsidian Users

The knowledge base at `~/knowledge/` is fully compatible with Obsidian (uses standard Markdown + `[[wiki-links]]`). However:

- **Do NOT enable Obsidian Sync** for the knowledge vault — your second brain should never leave your machine
- **Do NOT place the knowledge directory inside iCloud Drive, Dropbox, Google Drive, or OneDrive**
- If you use Obsidian, open `~/knowledge/` as a local-only vault with no sync plugins enabled
- The `.embeddings/` directory contains binary vector data — exclude it from any backup/sync tool

## How It Evolves

```
Session N → Quality gate catches issues → User corrects what it misses
    ↓
Stop hook captures session data → Creates pending reflection
    ↓
Session N+1 → Processes reflection → Updates learnings + quality rules + wiki
    ↓
Quality gate is smarter → Knowledge base has more context → Plugin keeps improving
```

## License

MIT
