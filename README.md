# Self-Evolving AI Companion for Claude Code

A Claude Code plugin that automatically gets smarter with every session. It learns from your patterns, discovers your tools, builds a personal knowledge base, self-critiques its own code quality, and thinks like a senior human developer.

## Five Capabilities

### 1. Auto Self-Improvement
The plugin automatically analyzes each session at end, extracts learnings from successes and failures, and stores them for future reference. No manual trigger needed.

### 2. Dynamic Tool Discovery
At session start, the plugin discovers all installed MCP tools and plugins. Skills automatically adapt to use whatever tools are available — Context7, episodic memory, web search, or any custom MCP servers.

### 3. Local Second Brain
A Karpathy-inspired LLM-maintained wiki with semantic search. Ingest articles, papers, and notes — the plugin creates structured wiki pages with cross-references. All knowledge stays on your machine.

### 4. Code Quality Self-Critique
After every code write/edit, a quality gate automatically reviews the code against evolving standards. When the plugin detects you correcting its output, it learns the pattern and catches it automatically next time.

### 5. Human Developer Persona
Claude thinks and acts like a senior human developer. It analyzes what you *actually* need (not just what you typed), proactively fills in unstated requirements, writes human-style code and commit messages with zero AI markers, and verifies tech choices against current best practices. The persona evolves as it learns your preferences.

## Installation

```bash
claude plugin add /path/to/companion
```

First run:
```
/companion:setup
```

## Skills

| Skill | Purpose |
|-------|---------|
| `/companion:setup` | Initialize knowledge base and learning directories |
| `/companion:ingest [path\|url]` | Process a source into the knowledge wiki |
| `/companion:query [question]` | Search the knowledge base |
| `/companion:status` | Dashboard of knowledge base health |
| `/companion:lint` | Health-check the wiki |
| `/companion:improve` | Deep manual session analysis |
| `/companion:review [file]` | Deep code review beyond the quality gate |

## MCP Server

The plugin includes a local MCP server for semantic search over the knowledge base. It uses `@xenova/transformers` (all-MiniLM-L6-v2) to generate embeddings locally — no API calls, no data leaving your machine.

Build:
```bash
cd mcp && npm install && npm run build
```

## Privacy

**Hard rule: all knowledge stays local. Nothing is synced, pushed, or shared externally.**

- Plugin code (shareable via marketplace): zero user data
- Knowledge base (`~/knowledge/`): completely local, never synced
- Learning state (`~/.claude-companion/`): completely local, never synced
- Embeddings: generated locally via ONNX Runtime in Node.js
- No telemetry, no cloud services, no API calls for core functionality
- `.nosync` marker files are created automatically to prevent iCloud sync

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
Stop hook extracts learnings → Updates quality-rules.md + learnings.md + persona.md
    ↓
Session N+1 → Quality gate is smarter → Knowledge base has more context
    ↓
Plugin gets better with every session
```

## License

MIT
