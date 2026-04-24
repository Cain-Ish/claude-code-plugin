# Changelog

## 0.3.0 (2026-04-24)

### Breaking Changes

- **Renamed plugin** from "companion" to "second-brain"
  - All skills now use `/second-brain:` prefix (was `/companion:`)
  - Learning state directory moved from `~/.claude-companion/` to `~/.second-brain/`
  - Auto-migration: `ensure-dirs.sh` moves old directory on first run

### Added

- **Automatic knowledge accumulation**: Stop hook creates pending reflection, next SessionStart processes it — creates wiki pages in `sessions/`, updates learnings and quality rules, all without user intervention
- **Tool-aware sessions**: SessionStart prompt now reads `tool-registry.json` and uses discovered MCP tools proactively throughout the session
- **`/second-brain:browse`**: new skill to browse and visualize knowledge base content

### Fixed

- **Stop hook error**: removed `type: "prompt"` from Stop hook (not supported at session end). Reflection now happens via deferred processing at next SessionStart
- LICENSE copyright made generic

## 0.2.0 (2026-04-24)

### Added

- **Human Developer Persona**: Claude thinks and acts like a senior human developer
  - SessionStart prompt hook loads persona rules from `~/.second-brain/persona.md`
  - Intent analysis: identifies unstated needs, verifies assumptions, checks tech choices
  - Human-style code and commits with zero AI attribution
  - Persona evolves via session reflection
- Persona check added to PostToolUse quality gate
- Cloud sync prevention: `.nosync` markers, Obsidian guidance, `.gitignore` inside knowledge dir

## 0.1.0 (2026-04-24)

Initial release.

### Features

- **Auto Self-Improvement**: automatic session analysis, learning extraction
- **Dynamic Tool Discovery**: enumerates MCP servers at session start
- **Local Second Brain**: Karpathy wiki + MCP semantic search server
- **Code Quality Self-Critique**: PostToolUse quality gate with evolving rules
- **Friction Detection**: logs correction/retry signals for session analysis

### Skills

- `/second-brain:setup` — first-run initialization
- `/second-brain:ingest [path|url]` — process source into wiki pages
- `/second-brain:query [question]` — semantic + keyword search
- `/second-brain:status` — knowledge base dashboard
- `/second-brain:lint` — wiki health check
- `/second-brain:improve` — manual session analysis
- `/second-brain:review [file]` — deep code review

### Privacy

All user data stays local. Plugin code contains zero user data.
