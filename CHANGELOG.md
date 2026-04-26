# Changelog

## 0.3.6 (2026-04-27)

### Fixed

- **`userConfig.knowledge_dir` was dead** — shell hooks read a non-existent env var (`CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR`). Now passed as `$1` from `hooks.json` via `${user_config.knowledge_dir}` substitution with a graceful fallback.
- **`UserPromptSubmit` matcher silently ignored** — the regex matcher in `hooks.json` was a no-op per Claude Code spec, meaning *every* user prompt was logged to `friction-log.jsonl`. Gate moved inside `log-friction.sh`; only friction-shaped prompts are now logged.
- **SessionStart race** — `discover-tools.sh` was `async: true` while `session-load.sh` referenced its output. Removed `async`; `session-load.sh` also now omits the tool-registry line when the file isn't there yet.
- **SessionStart matcher `"*"`** replaced with documented `startup|resume|clear|compact`.
- **`extract-learnings.sh` LEARNINGS_SINCE** ignored its date filter — fixed to count only headers newer than `.last-plugin-improve`.
- **USER_TURNS** now counted via `jq` (no false positives from assistant messages quoting `"role":"user"`).
- **Friction count** now matched on the structured `session_id` field via `jq`, not substring grep.
- **Auto-improve branch name** includes `HHMMSS` so same-day runs don't collide.
- **`validate-proposal.sh` Windows path normalization** — backslashes and drive-letter casing handled.
- **Distinct-evidence gate** — proposals now require 2+ entries from distinct sessions or timestamps (not the same incident cited twice).
- **`validate-plugin.sh` shell-injection hardened** — event names from hooks.json now read via `while IFS= read`, never word-split.
- **MCP server `KNOWLEDGE_DIR`** — uses `os.homedir()`, expands leading `~`, ignores unsubstituted placeholders.

### Changed

- **Friction log rotation** — capped at 5000 lines, keeping the most recent half.
- **`log-friction.sh` JSON build** uses `jq -nc` so embedded quotes/newlines/control chars stay valid JSON.
- **Vector store batched flush** — `force` reindex now writes once at the end instead of N times.
- Removed dead `embedBatch` helper.
- `validate-plugin.sh` now warns when `SessionStart` matcher is outside the documented set.
- `improve` skill `allowed-tools` narrowed: replaced wildcard `Bash(git *)` with the specific git subcommands the flow needs.
- `setup` skill `allowed-tools` adds `Bash(bash *)` so the documented `bash …/ensure-dirs.sh` actually runs.
- `knowledge-maintainer` agent `maxTurns: 30 → 15`.
- `.gitignore` cleaned up (removed nonsense `~/knowledge/` line).

### Added

- `tests/test-validate-proposal.sh` — fixture-based smoke test for the proposal validator.

## 0.3.5 (2026-04-26)

### Added

- **Evidence-based proposal gate** for plugin self-improvement — `scripts/validate-proposal.sh` requires 2+ cited friction entries before any plugin change is accepted.

## 0.3.4 (2026-04-26)

### Added

- **Auto-improve toggle** — `~/.second-brain/config.json` now seeds `{"auto_improve": false}`. When enabled, the plugin writes a structured proposal, validates it, applies changes, and opens a PR — no direct pushes to main.
- **Wiki curation on pending reflection** — `session-load.sh` instructs the `knowledge-maintainer` agent to merge duplicates, fix broken wiki-links, and update cross-references.

## 0.3.3 (2026-04-24)

### Added

- **PreCompact hook**: extracts session insights before context compaction — creates a pending reflection so learnings survive the compression
- **PostCompact hook**: reloads brain context (persona, quality rules, learnings, tools) into the fresh post-compaction window
- New scripts: `pre-compact.sh`, `post-compact.sh`
- Lossless memory pipeline: PreCompact saves → compaction runs → PostCompact + SessionStart reload → pending reflection processed → zero knowledge loss

## 0.3.2 (2026-04-24)

### Fixed

- **Eliminated all `type: "prompt"` hooks** — prompt hooks fail with "JSON validation failed" across PostToolUse, Stop, and SessionStart:compact events. Converted all hooks to `type: "command"` with shell scripts that echo instructions to stdout. Zero hook errors now.
- New scripts: `session-load.sh` (SessionStart), `quality-gate.sh` (PostToolUse)

## 0.3.1 (2026-04-24)

### Optimized

- **~95K tokens saved per active session**: PostToolUse quality gate compressed from ~300 to ~59 tokens, eliminated redundant file re-reads on every Write/Edit
- SessionStart now loads quality-rules.md and learnings.md once upfront — PostToolUse references from memory instead of re-reading
- SessionStart prompt compressed from ~450 to ~180 tokens by removing duplicated intent analysis (already in persona.md)

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
