# Changelog

## 0.3.9 (2026-04-27)

Follow-up to 0.3.8: cleans up the remaining `${user_config.knowledge_dir}` references in skill markdown prose. These weren't in bash blocks (so they didn't trigger the "bad substitution" error), but they were in instructions like *"create at `${user_config.knowledge_dir}/wiki/sources/`"* — when Claude reads that, it might use the literal placeholder as a path and fail at Write time, or substitute it inconsistently.

### Fixed

- **Skill prose `${user_config.X}` → `<knowledge-dir>` placeholder + resolution note.** Affected skills: `ingest`, `query`, `browse`, `setup`. Each now either uses `<knowledge-dir>` with an explicit "resolve from `$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` or `~/knowledge`" guidance, or rewrites the prose to plain English. Claude no longer has to guess what the placeholder means.
- **`browse` skill "Open in Finder" suggestion** rewritten to be cross-platform: shows the right command for macOS (`open`), Linux (`xdg-open`), and Windows Git Bash (`start ""`).

## 0.3.8 (2026-04-27)

Critical hotfix for cross-platform substitution failures observed on real installs.

### Fixed

- **`${user_config.knowledge_dir}` substitution removed from hooks.json command fields** — on Linux (and likely macOS), Claude Code refuses to substitute the placeholder when the user hasn't manually configured the value via `/plugin manage`, even though `plugin.json` declares a `default`. The hook command then fails with `Plugin option "knowledge_dir" isn't set`. Hooks now invoke `ensure-dirs.sh` and `extract-learnings.sh` with no arg; the scripts already chain `$1` → `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` (auto-injected by Claude Code per the userConfig schema, which IS reliable cross-platform) → `$HOME/knowledge`.
- **`${user_config.knowledge_dir}` substitution removed from `mcp/.mcp.json`** — same root cause. The `env` block is gone; the MCP server's `resolveKnowledgeDir()` now reads `KNOWLEDGE_DIR` first, then `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR`, then defaults to `$HOME/knowledge`.
- **All skill body bash blocks rewritten** to resolve the knowledge dir from `${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}` instead of `${user_config.knowledge_dir}`. Skill content placeholder substitution does not apply inside bash code blocks — bash receives the literal string and chokes on the dot in `${user_config.knowledge_dir}`. Affected: `setup`, `status`, `browse`, `lint`, `query`. Markdown-prose mentions of `${user_config.knowledge_dir}` (in `ingest`, `query`, `setup` documentation text) stay since Claude reads them as documentation, not bash.

### Notes

- **0.3.7 is broken on Linux installs that didn't manually configure `knowledge_dir`.** Update to 0.3.8 immediately. Existing seed files (persona.md, schema.md, learnings.md, etc.) are not touched on upgrade.
- The `userConfig.knowledge_dir` declaration in `plugin.json` is still present for users who want to set a custom location via `/plugin manage`. The auto-injected `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` env var carries the value to all subprocesses (hooks, MCP server, skill bash blocks).

## 0.3.7 (2026-04-27)

### Fixed

- **Defense-in-depth knowledge_dir resolution** — `ensure-dirs.sh` and `extract-learnings.sh` now chain `$1` → `$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` → `~/knowledge`. Both substitution paths are documented; this honors whichever the host provides.
- **`validate-proposal.sh` now portable on macOS** — replaced GNU-only `sed \L` with a `tr`-based lowercase so BSD sed users get correct Windows-path normalization.
- **MCP server flushes vectordb on shutdown** — `SIGINT`/`SIGTERM`/`beforeExit` handlers call `vectordb.flush()` so a crash mid-reindex no longer loses pending pages.
- **Setup skill now passes `${user_config.knowledge_dir}`** to `ensure-dirs.sh` — manual `/second-brain:setup` honors the user's configured location instead of defaulting.
- **`validate-plugin.sh` no-matcher list expanded** to match the Claude Code spec (Stop, PostToolBatch, TeammateIdle, TaskCreated, TaskCompleted, WorktreeCreate, WorktreeRemove, CwdChanged); declaring a matcher on those now WARNs since it's a no-op at runtime.
- **`validate-plugin.sh` operator-precedence footgun** — replaced `[ A ] || [ B ] && continue` with explicit `if … then continue; fi`.
- **Test suite preconditions** — `tests/test-validate-proposal.sh` now exits 2 with a clear message if `jq` / `mktemp` / `bash` are missing.
- **Knowledge-dir fallback rejects literal placeholder at every stage** — even if the env-var step somehow holds an unsubstituted `${user_config.…}`, the script falls through to `~/knowledge` instead of using the literal as a path.
- **Auto-improve no longer auto-fires on a brand-new user's first session** — `extract-learnings.sh` now requires a real signal (≥2 friction or ≥3 learnings since last improve); the implicit "no last improve date" trigger is gone.
- **MCP shutdown handlers attached before transport opens**, and `SIGHUP` is now also handled so terminal-close doesn't lose pending vectordb writes.
- **`post-compact.sh` no longer tells Claude to read a missing `tool-registry.json`** on fresh installs — line is conditional on the file's existence, mirroring `session-load.sh`.
- **`pre-compact.sh` no longer claims a reflection was saved when it wasn't** — emits a different prompt when USER_TURNS < 3 and no reflection was written.
- **`discover-tools.sh` header comment** corrected — was "Runs async at SessionStart" (no longer true) and "Discover MCP tools" (it only discovers server names).
- **`quality-reviewer` subagent surfaced** — `review` skill now points at it for deep structural review; was previously discoverable only by Claude Code's agent registry.

### Changed

- **Auto-improve protocol externalized** — the ~600-token instruction block in `session-load.sh` is now a 3-line pointer to `scripts/improve-protocol.md`. Lower per-session token cost; protocol edits no longer touch the hook script.
- **`improve` skill body de-duplicated** — section 7 now references the same `scripts/improve-protocol.md` file instead of inlining the protocol again. The manual deep-dive flow (sections 1–6) and the auto-improve PR flow now share one source of truth, including the timestamped branch-name convention.
- **Setup skill builds the MCP server when the dist artifact is missing** — fresh installs no longer have a silently-broken `knowledge_search` until the user manually `npm install && npm run build`. The skill detects missing `mcp/dist/server.js` and runs the build itself.
- **README "How It Evolves" diagram refreshed** to reflect the auto-improve / proposal-gate flow added in 0.3.4–0.3.7.
- **README "Testing" section added** — `tests/test-validate-proposal.sh` and `scripts/validate-plugin.sh` are now discoverable for contributors.
- **`improve-protocol.md` "write today's date" instruction consolidated** into a single "On exit (always)" subsection so every termination path (success, abandon, validation failure) marks the attempt.
- **README MCP-server section refreshed** to point at `/second-brain:setup` for builds; manual build is now the fallback path, not the primary one.
- **Setup skill `Bash` permissions narrowed** — `Bash(npm *)` replaced with `Bash(npm install:*) Bash(npm run:*)` so the skill can't `npm publish` or `npm uninstall` etc.
- **Setup skill no longer hides npm errors** — dropped `--silent`, added an explicit fallback message pointing at the manual command if the build fails.
- **`validate-plugin.sh` checks for runtime-referenced files** — `scripts/improve-protocol.md`, `skills/improve/signal-patterns.md`, `mcp/.mcp.json`, `mcp/package.json` must exist or the validator FAILs. Catches accidental deletions before they break auto-improve at runtime.
- **`validate-plugin.sh` JSON-validates the MCP manifests** — `mcp/.mcp.json` and `mcp/package.json` must parse, not just exist.
- **Setup skill `Bash(node *)` permission removed** — the skill body never invoked `node` directly; npm handles it. Tighter blast radius.

### Added (cont.)

- **`tests/test-validate-plugin.sh`** — fixture-based smoke test for the plugin validator itself. Nine cases cover: clean skeleton, invalid hooks.json, undocumented SessionStart matcher (WARN), UserPromptSubmit-with-matcher (WARN), PreCompact-missing-matcher (FAIL), missing runtime-referenced file, corrupt mcp/package.json, shell-syntax error, and missing skill frontmatter.
- **`mcp/dist/` is now tracked in git** — marketplace installs work with zero build step. `knowledge_search`/`index`/`stats` are functional immediately after `/plugin install`. The setup skill's build step is now a recovery path for users who cloned with sparse-checkout or modified source.
- **README "Where files live" section** explains how `~/.second-brain/` and `~/knowledge/` resolve on Linux/macOS, Git Bash on Windows, and native Windows shells (`%USERPROFILE%\.second-brain\`).
- **Wiki nodes are now updated to current state, not appended-to** — the `ingest` skill and `knowledge-maintainer` agent both rewrite the body when new information supersedes old, and append a one-line `## History` entry per change. Two genuinely-conflicting sources of equal authority are the only case where both perspectives are kept (and the conflict is flagged in `## Open Questions`). The `lint` skill detects append-only drift (multiple "however,…" / "as of <old date>, but actually…" stretches) and offers to consolidate. `schema.md` documents the convention.
- **Learnings now appear as Obsidian graph nodes** — every entry written to `~/.second-brain/learnings.md` is also mirrored to `~/knowledge/wiki/learnings/YYYY-MM-DD-short-title.md` with `[[wiki-link]]` cross-references to the entities/concepts it touches and a back-link to the originating session page. `ensure-dirs.sh` creates `wiki/learnings/`, `index.md` gets a Learnings section, and the `knowledge-maintainer` agent reconciles the canonical store with the wiki mirror each maintenance pass.
- **Context-relevant node loading (Karpathy second-brain pattern)** — `session-load.sh` and `post-compact.sh` now instruct Claude to proactively call `knowledge_search` when the user's request touches a topic the wiki likely covers (named tool/library/framework, person, org, project, domain concept) and read any result with relevance > 0.6 before answering. Closes the previously implicit gap where wiki nodes only loaded on explicit `/second-brain:query` invocation.
- **Architectural review checklist** baked into the persona template, the `review` skill, AND the `quality-reviewer` agent — six concrete dimensions (update semantics, cross-surface integration, onboarding UX, cross-platform shells/paths, proactive vs lazy context loading, silent failure modes). All three places now apply the same checklist so the routing chain "review skill → quality-reviewer agent" stays consistent. Existing users get the behavior immediately via the `review` skill body and the agent file; new installs additionally get it in `~/.second-brain/persona.md`. To pull the checklist into an existing `~/.second-brain/persona.md`, copy the new "Architectural Review Checklist" section from the template in `scripts/ensure-dirs.sh`.
- **`status` and `browse` skills now show the `wiki/learnings/` subtree** — both iterated only the original five categories and silently dropped the new learnings count. Dashboards now report all six.
- **`improve` skill manual-path proposals can target `wiki/learnings/`** — destination list now matches the auto path's behavior so manual-mode reflections also produce graph-visible learning nodes.
- **`lint` skill check 6 ("Missing Entity Pages") also scans `wiki/learnings/`** — entities cross-linked from learnings now get the same missing-page detection as those cross-linked from sources.

### Fixed (cont.)

- **Windows CRLF bug in `validate-plugin.sh` hooks block** — jq output on Git Bash has CRLF line endings; `while IFS= read -r event` kept the trailing `\r`, so every event lookup became `SessionStart\r` (no match) and the hooks-block validation silently skipped on Windows. The validator was passing not because hooks were valid but because no checks were running. Now strips `\r` from `event`. Surfaced and verified by `tests/test-validate-plugin.sh`.
- **`Stop` hook drops its `matcher: "*"`** in `hooks.json` — Stop ignores matchers per spec, so the field was misleading. Validator now WARNs if a no-matcher event declares one.
- **CHANGELOG 0.3.4 / 0.3.5 entries cite their commit SHAs** so readers can verify the descriptions against actual diffs.

## 0.3.6 (2026-04-27)

### Fixed

- **`userConfig.knowledge_dir` substitution unified** — hooks now explicitly pass `${user_config.knowledge_dir}` as `$1` to scripts, matching the documented substitution path. (The prior env-var path `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` is also documented and likely worked; 0.3.7 chains both for defense-in-depth.)
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

Commit: `3592a6f` (entry reconstructed from commit message; pre-dates the disciplined CHANGELOG entries).

### Added

- **Evidence-based proposal gate** for plugin self-improvement — `scripts/validate-proposal.sh` requires 2+ cited friction entries before any plugin change is accepted.

## 0.3.4 (2026-04-26)

Commit: `3e8c1c5` (entry reconstructed from commit message; pre-dates the disciplined CHANGELOG entries).

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
