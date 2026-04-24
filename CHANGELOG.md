# Changelog

## 0.2.0 (2026-04-24)

### Added

- **Human Developer Persona**: new capability — Claude thinks and acts like a senior human developer
  - SessionStart prompt hook loads persona rules from `~/.claude-companion/persona.md`
  - UserPromptSubmit prompt hook silently classifies requests as trivial vs substantive, triggers deep intent analysis on substantive requests
  - Intent analysis: identifies unstated needs, verifies assumptions, checks tech choices via Context7/web search before coding
  - Human-style code: no AI-telltale patterns (verbose comments, cookie-cutter structure, filler phrases)
  - Human-style commits: imperative mood, no AI attribution markers
  - Persona evolves via Stop hook — learns communication preferences and catches drift
- Persona check added to PostToolUse quality gate (check #7)
- Persona drift signals added to signal-patterns.md
- Persona analysis added to `/companion:improve` skill
- Persona rules count added to `/companion:status` dashboard
- Cloud sync prevention: `.nosync` markers, Obsidian guidance, `.gitignore` inside knowledge dir

## 0.1.0 (2026-04-24)

Initial release.

### Features

- **Auto Self-Improvement**: Stop hook automatically analyzes sessions, extracts learnings from successes and friction signals, and writes them to `~/.claude-companion/learnings.md` and `quality-rules.md`
- **Dynamic Tool Discovery**: SessionStart hook enumerates all installed MCP servers and writes `~/.claude-companion/tool-registry.json` — skills adapt to whatever tools are available
- **Local Second Brain**: Karpathy-inspired wiki at `~/knowledge/` with five page types (sources, entities, concepts, synthesis, sessions), plus an MCP server for semantic search using local embeddings (all-MiniLM-L6-v2 via @xenova/transformers)
- **Code Quality Self-Critique**: PostToolUse hook on Write/Edit triggers automatic silent self-review against evolved quality standards in `quality-rules.md`
- **Friction Detection**: UserPromptSubmit hook detects correction/retry patterns and logs them for session analysis

### Skills

- `/companion:setup` — first-run initialization
- `/companion:ingest [path|url]` — process source into wiki pages
- `/companion:query [question]` — semantic + keyword search with cited answers
- `/companion:status` — knowledge base dashboard
- `/companion:lint` — wiki health check
- `/companion:improve` — manual deep session analysis
- `/companion:review [file]` — deep code review beyond the quality gate

### Privacy

All user data stays local. Plugin code contains zero user data. Knowledge base (`~/knowledge/`) and learning state (`~/.claude-companion/`) are never synced.
