---
name: upgrade
description: Detect installed plugin version vs the version in plugin.json, run idempotent migrations between them, and update the installed-version marker. Safe to run anytime — no-op when already at current version. Use after pulling a new plugin release.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Write Edit Bash(cat *) Bash(jq *) Bash(test *) Bash(date *) Bash(grep *) Bash(awk *) Bash(cp *) Bash(mv *) Bash(mkdir *)
---

# Plugin Upgrade

Idempotent migration runner. Reads the canonical version from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`, compares to `~/.second-brain/.installed-version`, and applies only the migrations between them.

## Steps

### 1. Read both versions

```bash
CURRENT=$(jq -r '.version' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
INSTALLED=$(cat ~/.second-brain/.installed-version 2>/dev/null || echo "0.0.0")
echo "Installed: $INSTALLED -> Current: $CURRENT"
```

### 2. Decide what to do

- If `$INSTALLED == $CURRENT` -> exit "already up to date"
- If `$INSTALLED < $CURRENT` -> walk migrations between them
- If `$INSTALLED > $CURRENT` -> exit with warning ("installed version is newer than plugin.json — did you downgrade?"). Offer to overwrite the marker.

### 3. Migration registry

Each migration is identified by its target version. Run only migrations whose target is `> $INSTALLED AND <= $CURRENT`.

| To version | Migration | Idempotent check |
|---|---|---|
| **0.4.0** | Critic-log file is created on first write — nothing to migrate. Drift-log file ditto. | No precondition. |
| **0.5.0** | learnings.md entries gain `<!-- meta: confidence=X hits=Y last_used=Z -->` lines on next /improve write. Old entries without meta line are kept. (Note: decay tracking and `decay-learnings.sh` were removed in 1.0.0 — the meta lines in pre-1.0 `learnings.md` are no longer parsed but cause no harm if present, and 1.0.0 resets `learnings.md` to header-only anyway.) No bulk rewrite required. | `grep -c "^<!-- meta: " ~/.second-brain/learnings.md` — if 0, just record the version. |
| **0.5.0** | Wiki source pages gain `Coverage:` and `Freshness tier:` fields on next /ingest. Old pages without them skip lint freshness checks. | No bulk migration. |
| **0.5.0** | `~/.second-brain/regressions/` directory created (empty) so `/second-brain:regress` finds it. | `mkdir -p ~/.second-brain/regressions` |
| **0.7.0** | New wiki directories: `patterns/`, `issues/`, `decisions/`. Graph layer deprecated (compile-graph.sh is now a no-op). Reflection gating on friction/positive signals — trivial sessions no longer queue reflections. | `KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"; mkdir -p "$KNOWLEDGE_DIR"/wiki/{patterns,issues,decisions}` |
| **0.7.0 retro-fix** | Purge pre-0.7.0 stale entries from `~/.second-brain/.pending-reflections.jsonl`. The 0.7.0 gate (`extract-learnings.sh:23`) blocks `friction_count==0 AND positive_signals==0 AND priority!="high"`, but entries queued by older code don't satisfy the gate and become permanent dead weight. Move (don't delete) them and their orphan `.reflection-context/` snapshots to `~/.second-brain/.0.7.0-purge-backup/<ISO-timestamp>/`. Discovered via `/second-brain:doubt --layer learning` 2026-05-01: 5 stale entries from session b2baa1fd (2026-04-29) plus 1 orphan snapshot. | If `test -f ~/.second-brain/.0.7.0-purge-completed`, skip. Otherwise: `mkdir -p ~/.second-brain/.0.7.0-purge-backup/$(date -u +%Y%m%dT%H%M%SZ)`, scan pending-reflections.jsonl for entries matching the dead-weight predicate (use `jq` to filter `friction_count==0 and positive_signals==0 and (priority!="high")`), move matching JSONL lines + their `context_snapshot` files to backup dir, then scan `.reflection-context/` for snapshot files with no JSONL match (orphans) and move those too. After successful run: `touch ~/.second-brain/.0.7.0-purge-completed`. Requires user confirmation if `auto_improve=false` in config.json. |
| **1.0.0** | Wipe reflection runtime (`.pending-reflections.jsonl`, `.reflection-context/`, `.learnings-hot.md`, `.compact-count`, `friction-log.jsonl`, `drift-log.jsonl`, `error-log.jsonl`, `critic-log.jsonl`, `doubt-history.jsonl`). Backup all to `~/.second-brain/.0.7.0-backup/<ISO>/`. Reset `learnings.md` to header-only. Condense `persona.md` (90 lines) → USER.md (≤15 lines) interactively. Scaffold first PROJECT.md from current repo. Keep curated wiki pages untouched. | If `cat ~/.second-brain/.installed-version` returns `1.0.0`, no-op. Otherwise run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/migrate-to-1.0.0.sh`. |
| **1.1.0** | Additive only. New `scripts/verify.sh` runtime smoke check (surfaced via `/second-brain:status` Step 6); creates `~/.second-brain/.last-verify` (ISO-8601 UTC timestamp) lazily on first successful run. `validate-plugin.sh` now requires `allowed-tools:` in skill frontmatter — universal in shipped skills so no remediation needed. No state migration. | No precondition. Bumping the marker is sufficient. |
| **1.2.0** | Additive. (a) New `## Intent` section appended to `~/.second-brain/USER.md` (persona-as-first-thought protocol: keywords → `second-brain:query` → self-followups → answer-from-context → focused clarifying question only when ambiguous). New `UserPromptSubmit` hook (`scripts/intent-gate.sh`) re-injects the Intent reminder mid-session for substantive prompts. (b) New Stop-hook orchestrator (`scripts/stop-extract.sh`) replaces `run-stop-predicate.sh` in `hooks.json`. Spawns `claude -p` (default model `claude-haiku-4-5-20251001`, override via `SB_EXTRACTOR_MODEL`) to extract decisions/blockers/cross-refs/files-touched from the session transcript and idempotently merges them into PROJECT.md + wiki stubs at `~/.second-brain/wiki/`. New `scripts/merge-project-update.sh` performs the merge with case-insensitive dedupe, hard caps (3/15/3), and atomic writes. Backups USER.md to `~/.second-brain/.1.2.0-backup/<ISO>/USER.md` before mutation; creates `~/.second-brain/wiki/` if missing. | If `cat ~/.second-brain/.installed-version` returns `1.2.0`, no-op. Otherwise run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/migrate-to-1.2.0.sh`. |
| **1.2.1** | Observability-only. `stop-extract.sh` and `pre-compact.sh` now route every silent `exit 0` precondition through `sb_log_error` with a `gate=<tag>` message (`empty-stdin`, `tool-count-zero`, `project-md-missing`, etc.) so failures land in `~/.second-brain/error-log.jsonl` and surface via `/second-brain:status`'s freshness check. No state migration. | No precondition. Bumping the marker is sufficient. |
| **1.2.2** | Tooling. Adds `.claude/settings.local.json` to `.gitignore` so per-user Claude Code session settings (permission grants, local hooks) don't leak into commits. No runtime change. | No precondition. Bumping the marker is sufficient. |
| **1.3.1** | MCP server bundled with esbuild — all dependencies inlined into `dist/server.bundle.js` so the plugin cache works without `node_modules`. Scripts updated to use `.bundle.js` imports. No state migration. | No precondition. Bumping the marker is sufficient. |
| **1.4.0** | On-demand knowledge injection. `UserPromptSubmit` hook now runs BM25 search against the wiki and injects top results directly into context — Claude gets relevant knowledge without a separate MCP tool call. New `knowledge-search-cli.bundle.js` standalone entry point. Hook timeout increased from 5s to 8s. Includes 1.3.2 MCP discovery fix. No state migration. | No precondition. Bumping the marker is sufficient. |
| **1.3.2** | Move `.mcp.json` from `mcp/` subdirectory to project root — standard plugin location so Claude Code discovers the MCP server correctly. No state migration. | No precondition. Bumping the marker is sufficient. |
| **1.8.0** | Complete learning loop. (a) PreCompact hook rewritten with full LLM extraction — runs same pipeline as Stop hook on unprocessed transcript window before compaction discards context. Shared line-marker file (`.last-extracted-line-<slug>`) ensures disjoint windows between PreCompact and Stop hooks. (b) Stop hook made marker-aware — reads only lines since last PreCompact extraction, clears marker at end. (c) SessionStart wiki enrichment — `session-load.sh` queries BM25 search based on PROJECT.md keywords (Goal, State, decisions, blockers, cross-refs) and injects relevant wiki pages into new context. (d) SessionStart persona signal injection — surfaces recent (≤30 days), non-graduated signals with count ≥ 2 as observed behavioral patterns. (e) BM25 min-score threshold — results below 15% of top score filtered out, preventing low-relevance noise from being injected. (f) Wiki stub downranking — auto-extracted stubs and pages with body < 100 chars get 0.5x score penalty. PreCompact timeout increased 30s → 45s. New `sb_get_extraction_marker`, `sb_set_extraction_marker`, `sb_clear_extraction_marker` helpers in `lib.sh`. No state migration — marker files created lazily. | No precondition. Bumping the marker is sufficient. |
| **1.7.0** | Auto-graduation for persona signals. `merge-persona-signals.sh` now auto-graduates high-confidence signals after 3+ observations — pins them to USER.md and sets `graduated: true` without requiring manual `/second-brain:improve`. Medium-confidence signals still require manual review. New `sb_pin_to_user()` helper in `lib.sh` (byte-capped at 2200 to align with hot-tier budget). No state migration — existing persona-signals.jsonl compatible. | No precondition. Bumping the marker is sufficient. |
| **1.6.0** | Persona signal extraction. Stop hook now extracts implicit and explicit behavioral signals (`persona_signals` key in extract-prompt.txt schema) and accumulates them in `~/.second-brain/persona-signals.jsonl` via new `scripts/merge-persona-signals.sh`. Signals track category, evidence, count, and graduation status. After 3+ observations across sessions, `/second-brain:improve` proposes graduated signals as USER.md pins. 90-day retention with automatic pruning. No state migration — JSONL file created lazily on first extraction. | No precondition. Bumping the marker is sufficient. |
| **1.5.2** | Knowledge-maintainer agent rewrite. 5-phase consolidation cycle (Audit → Deduplicate → Relate → Enrich → Reindex) with category-specific content quality rules for all 6 wiki categories, systematic bidirectional relation building, BM25 field-weight-aware frontmatter optimization, and change cap raised 20 → 50. No state migration. | No precondition. Bumping the marker is sufficient. |
| **1.5.1** | Fix slug resolution and transcript content format. (a) `stop-extract.sh` and `session-load.sh` now use `basename "$CWD"` instead of `git rev-parse --show-toplevel` for project slug — subdirectories within a monorepo (e.g. `boilerplate/`, `frontend/`) get their own PROJECT.md instead of all mapping to the git root. (b) Transcript preprocessor handles both string and array formats for user message `content` field — fixes extraction failure on older/compacted transcripts. New `batch-extract.sh` utility for retroactive extraction of historical sessions. | No precondition. Bumping the marker is sufficient. |
| **1.5.0** | Knowledge extraction pipeline fix + hybrid search. (a) `stop-extract.sh` preprocesses JSONL transcript via jq (300KB raw → 15-20KB signal) before LLM extraction — drops tool_result content, attachment entries, permission metadata; keeps user text, assistant reasoning, tool call metadata, truncated thinking. Default extractor model upgraded from Haiku 4.5 to Sonnet 4.6 (`SB_EXTRACTOR_MODEL`), timeout bumped 25s → 45s. LLM extraction failures now logged to error-log.jsonl. (b) `merge-project-update.sh` decision cap raised 3 → 5, decisions date-prefixed (`[YYYY-MM-DD]`), evicted decisions auto-archived to `wiki/decisions/project-decisions-log.md`. Dedup strips date/status prefixes before comparison. "files this session" fallback lines filtered from decisions. (c) `knowledge-search.ts` gains graph boost (0.3x score bump from `related:` frontmatter edges) and optional ONNX hybrid ranking — BM25 + cosine similarity via all-MiniLM-L6-v2 embeddings, fused with RRF (k=60). Embedding cache at `wiki/.embeddings-cache.json`. Graceful fallback to BM25-only if `@huggingface/transformers` not installed. esbuild bundles mark `@huggingface/transformers` as external. All scripts and tests `chmod +x`. **Cleanup**: existing `PROJECT.md` files may contain "files this session" noise in Recent decisions — safe to remove manually. | No precondition. Bumping the marker is sufficient. |
| **1.3.0** | Knowledge architecture overhaul + self-healing maintenance. **Migration**: (a) Add YAML frontmatter to all existing wiki pages. (b) Rename date-prefixed files to topic-only names (date in frontmatter). (c) Fold `sessions/` into `entities/`. (d) Remove empty wiki dirs. (e) Clean stale root files + legacy `~/.second-brain/wiki/` dir + root orphans in knowledge dir. (f) Auto-scaffold missing PROJECT.md for all registered projects. (g) Generate `wiki/index.md` catalog. (h) Rename `index.txt` → `projects.jsonl`. **New capabilities**: BM25-scored full-content search (field-weighted: title 3x, description 2x, tags 2x, body 1x), dynamic wiki scope discovery, `knowledge_reindex` tool (runs validation automatically), `knowledge_validate` tool (detects orphans, broken links, duplicates, session-narrative pages, empty pages — auto-fixes safe issues). **Self-healing**: `ensure-dirs.sh` runs validation on every session start, `merge-project-update.sh` rejects MR/session-style slugs and session-narrative content at write time, duplicate slug detection routes updates to existing pages. **Extract prompt**: enriched with `wiki_updates[]`, explicitly bans MR/ticket/session slugs. Backups: `~/.second-brain/.1.3.0-backup/`. | If `cat ~/.second-brain/.installed-version` returns `1.3.*`, no-op. Otherwise run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/migrate-to-1.3.0.sh`. |

| **2.0.0** | Dreaming feature — async knowledge base consolidation. (a) Session transcript archive: Stop and PreCompact hooks now save preprocessed transcripts to `~/.second-brain/transcripts/` (100-file / 5MB cap, auto-pruned). (b) Dream lifecycle: new `~/.second-brain/dreams/` directory stores dream state (status.json, staging wiki snapshot, transcript symlinks, diff.md). Max 5 dreams retained. (c) 6 new MCP tools: `dream_create`, `dream_status`, `dream_list`, `dream_accept`, `dream_discard`, `dream_cancel`. (d) New `/second-brain:dream` skill with inline (default) and background (`--background`) execution modes. (e) New `agents/dream-runner.md` agent for background dream execution. (f) SessionStart nudge when a completed dream awaits review. (g) `verify.sh` checks for stale/unreviewed dreams. (h) `/second-brain:status` shows dream state. No breaking changes to existing data. | `mkdir -p ~/.second-brain/{transcripts,dreams}`. Bumping the marker is sufficient. |

### 4. Apply migrations

For each applicable migration:
1. State what it will do
2. Run the idempotent check
3. If safe, apply it (with backup if it touches user data)
4. Report success/failure

### 5. Update marker

```bash
echo "$CURRENT" > ~/.second-brain/.installed-version
echo "Upgraded $INSTALLED -> $CURRENT"
```

### 6. Re-run validation

After migrations, re-run the plugin validator if available:
```bash
test -x "${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh" \
  && bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh"
```

## Notes

- Migrations are intentionally minimal: most schema changes in this plugin are *additive* (new optional fields), so old data continues to work.
- Never delete or rewrite user data without explicit confirmation. The migration table is "what changed and how" — execution stays cautious.
- If a migration would be destructive, gate it behind `auto_improve: true` in `~/.second-brain/config.json` or explicit user confirmation.
- Future major versions (1.0.0+) may require interactive migrations. This skill is the place to add them.
