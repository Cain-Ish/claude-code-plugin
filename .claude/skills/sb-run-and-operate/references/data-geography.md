# Data geography — full state-file map (writers, readers, deletion safety)

Companion to `sb-run-and-operate/SKILL.md` §6. As of 0.33.31 (2026-07-05), verified against the
working tree. Evidence column = defining/consuming site in this repo.

Two roots (definitions in SKILL.md):

- **BRAIN_DIR** — default `~/.second-brain`. Bash: `BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"`
  (`scripts/lib.sh:5-12`). TS: `resolveBrainDir()` = `SB_BRAIN_DIR` → `BRAIN_DIR` →
  `join(homedir(), '.second-brain')` (`mcp/src/brain-paths.ts`) — deliberately `os.homedir()`,
  never `process.env.HOME` (Windows stray-folder bug class; guarded by a source-scan test).
- **KNOWLEDGE_DIR** — default `~/knowledge`. Resolution: `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR`
  (the plugin.json `knowledge_dir` userConfig) → `KNOWLEDGE_DIR` → `~/knowledge`
  (`mcp/src/brain-paths.ts`; bash pattern `"${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"`).

The skeleton is created by the SessionStart hook `scripts/ensure-dirs.sh`: `projects/ regressions/
transcripts/ dreams/ wiki-archive/` under BRAIN_DIR, plus the wiki content categories under
KNOWLEDGE_DIR (`ensure-dirs.sh:8-17`).

Deletion-safety legend: **NEVER** = user data with no other copy; **KEEP** = loses configuration
or history if removed; **REGEN** = regenerable, safe to delete; **AUTO** = pruned automatically.

## `~/.second-brain/` (BRAIN_DIR) — private machine state

| Path | What it is | Writer(s) | Reader(s) | Delete? |
|---|---|---|---|---|
| `USER.md` | pinned user preferences (hot tier) | setup step 2; `pin_to_user` MCP tool | `session-load.sh` hot-tier injection | NEVER |
| `persona-card.md` | always-loaded identity card (user-owned after setup step 5; plugin never rewrites, only idempotent Charter fill) | setup step 5; the user | `persona-context.sh` each UserPromptSubmit | NEVER |
| `persona-rules.json` | user-owned HARD guard policy — when present it wins over the shipped `scripts/persona-rules.default.json` (`persona-tool-guard.sh:39`) | the user (no plugin writer) | `persona-tool-guard.sh` each PreToolUse | KEEP (deleting reverts to shipped defaults, loses your rules) |
| `projects.jsonl` (+ `.bak.*`) | project registry, one compact JSON object per line | setup step 4; `session-load.sh` auto-register; `lib.sh` hardener | slug resolution everywhere (`sb_project_identity`, `project-dir.ts`) | NEVER |
| `projects/<slug>/PROJECT.md` | per-project hot tier | setup step 3; extractor write-back; `pin_to_project` / `archive_to_wiki` MCP | `session-load.sh`; `/second-brain:review` | NEVER |
| `projects/<slug>/raw/` | the raw inbox (unprocessed captures, `.md` + `.bin` blobs) | `raw-capture-cli` / `raw-scan-cli` bundles (`mcp/src/tools/raw-inbox.ts:42`) | `raw-drainer` agent batches via `/second-brain:maintain` | NEVER until drained |
| `projects/<slug>/pending-extraction.log` | degraded-capture sidecar (bounded 50 lines) | `stop-extract.sh` LLM-unavailable fallback | operator review | safe after review |
| `projects/<slug>/doc-sources.config.json` | user-declared doc sources | `/second-brain:track` | `discover-doc-sources.sh` SessionStart hook | KEEP |
| `projects/<slug>/.maintainer-auto-disabled` | 3-strike marker: maintainer auto-dispatch off for this project (`SB_MAINTAINER_MAX_FAILS`) | `session-load.sh:155-175` | same | safe (deleting re-enables auto-dispatch) |
| `transcripts/<sid>_<slug>_<date>.txt`, `sub-<aid>_...` | archived session/subagent windows — the source for episodic search AND dream mining | `sb_archive_transcript` (`lib.sh:779-800`) from Stop/PreCompact/SubagentStop hooks | drainer batch loop; `episodic_search`; dream snapshot | NEVER manually (self-caps at 100 files / 5 MB; sub-archives own cap 50) |
| `transcripts/.embeddings-cache.json` | episodic exchange-vector cache (keys `episodic:<id>` + transient `concept-*`) | `embedTexts` during episodic search/index (`episodic-search.ts:254`) | `episodic_search`; GC'd by `sb-prune-archives.sh:22` when `retention.embeddings_cache_gc` | REGEN (missing vectors re-embed from transcripts on next search) |
| `dreams/drm_*/` | dream state: `status.json`, `staging/wiki/`, `transcripts/`, `diff.md`, `forget-manifest.tsv` | `dream_create` snapshot; `dream-runner` agent (staging only) | `dream_status`/`dream_list`; `dream-accept.sh` | AUTO (retention `dream_keep_count: 5`) |
| `wiki-archive/` + `wiki-archive-log.jsonl` | reversible FORGET store — **the only copy of forgotten wiki pages** | dream-skill accept phase (move, never delete) | `scripts/wiki-restore.sh` | NEVER (`wiki_archive_ttl_days: 0` = never expires by default) |
| `wiki-backup-pre-accept-<utc>.tgz` | pre-accept full-wiki tarball | every `dream_accept` (fail-closed; `dream-accept.sh:141`) | operator restore (`tar xzf <tgz> -C "$KNOWLEDGE_DIR"`) | AUTO (`retention.bak_ttl_days: 14`) |
| `wiki-backup-pre-autoaccept-<utc>.tgz` | same, written before the headless maintainer's `auto_accept` path | `maintain-llm-drain.sh:268` | operator restore (same `tar xzf`) | AUTO (same `*.tgz` TTL sweep) |
| `config.json` | autonomy + retention settings | seeded once by `ensure-dirs.sh:30-41` (never clobbered); `scripts/set-autonomy.mjs` | `sb_config_get`/`sb_config_bool` (`lib.sh`) | KEEP (reseeds with defaults, loses your choices) |
| `.installed-version` | upgrade marker | `/second-brain:upgrade` finish | upgrade step 1 | KEEP (deleting replays all migrations — they are idempotent, but noisy) |
| `error-log.jsonl` | fail-loud error channel (rotates >512 KB) | `sb_log_error` (`lib.sh:196`) | SessionStart banners; diagnostics | safe |
| `audit-log.jsonl` | guard-verdict trail (rotates 5000 lines / 5 MiB) | PreToolUse guards, scanners, `hook-timer.sh` | `/second-brain:audit`; `sar-summary.sh` | safe (loses audit history) |
| `.extractor-health.json` | last extractor backend + ok/fail/queued | `sb_write_extractor_health` (`lib.sh`) | `session-load.sh` health banner | REGEN |
| `.extraction-state.jsonl` | drainer per-transcript ledger (`ok\|retry\|error`) | `extract-drain.sh` | drainer resume; dead-letter banner | KEEP (deleting re-drains everything) |
| `.rejected-extractions.jsonl` | extraction-quality-gate rejection log | `extraction-quality-gate.sh:24` | operator review | safe (loses reject history) |
| `.extract-drain.lock` / `.extract-drain.lock.d/` | drainer single-flight lock | `extract-drain.sh:199-227` | same | REGEN (only if no drain running) |
| `.drain-defer-count` / `.last-drain-escape` | starvation-escape state | `extract-drain.sh:86-87` | same | REGEN |
| `bin/sb-extract-drain.sh` + `.extract-timer-env` (chmod 600) | upgrade-stable scheduler shim + captured env | `install-extract-timer.sh` | the scheduled job each tick | via `--uninstall` only |
| `.active-session-slug` | last-session project pin (lowest-precedence slug input) | `session-load.sh:37` | `project-dir.ts` / `sb_resolve_slug` | REGEN |
| `.session-baseline-<slug>.md` | Stop-diff baseline | `session-load.sh` | `stop-extract.sh` (deletes on use) | REGEN |
| `.last-extracted-line-<slug>--<sid>` | disjoint extraction-window markers | `lib.sh` | Stop/PreCompact extractors | AUTO (GC `-mtime +30`) |
| `episodic-index.json` | episodic vector/text index | `episodic-index-cli.bundle.js` | `episodic_search` | REGEN (`node "$CLAUDE_PLUGIN_ROOT/mcp/dist/tools/episodic-index-cli.bundle.js"`) |
| `access-counts.json` | wiki access telemetry — recorded, **never folded into ranking** (the P4b 0.33.30 cut removed the search boost; `knowledge-search.ts:83-85`, `:380`) | `knowledge_search` fire-and-forget record | `scripts/wiki-forget-score.sh` `acc=` display field only | safe (loses `acc=` display telemetry; zero ranking effect) |
| `vector-deps/` (+ `.deps-key`) | shared ~490 MB embeddings node_modules, junction-linked per plugin version | `bin/install-vector-deps.sh` | every bundle importing `@huggingface/transformers` | REGEN (~70 MB re-download) |
| `tool-registry.json` | discovered MCP server-name index | `discover-tools.sh` SessionStart hook | skills needing server names | REGEN |
| `.installed-catalog.json` | installed plugin/skill/agent catalog | `discover-installed.sh` SessionStart hook | `persona_stats` (`persona-stats.ts:49`) | REGEN |
| `cost-router-events.jsonl` | routing-event ledger of the cost-router subplugin, removed 0.35.x — appears only on old installs; nothing writes or reads it since | none (writers removed) | none | safe (stale artifact — delete freely) |
| `.last-maintain` / `.last-llm-maintain` / `.last-verify` / `.plan-nudge*` / `.verify-gate-blocks-<sid>` | interval + once-per-session markers (maintenance cadence, verify freshness, plan-first nudge, verify-gate block count) | their namesake scripts (`maintain-deterministic.sh`, `maintain-llm-drain.sh`, `verify.sh:106`, `plan-first-nudge.sh:50`, `stop-verify-gate.sh:23`) | same | REGEN (deleting just re-arms the timer/nudge) |
| `.injected/*.json` | per-session persona-injection memos | `persona-context.sh` | GC'd by `ensure-dirs.sh` at 7 days | AUTO |
| `persona-signals.jsonl`, `.pin-candidates.jsonl`, `persona-budget.json`, `.persona-dismissals.jsonl` | persona learning state | extraction pipeline; `persona_think`/`persona_dismiss` MCP | `persona-context.sh`; `persona_stats` | KEEP |
| `.llm-maintain-quarantine` / `.llm-maintain-fails` | headless-maintainer 3-strike quarantine | `maintain-llm-drain.sh` | dream-autostage banner; self-clears on healthy preflight | safe (clears quarantine) |
| `scratch/` | cwd for nested extractor spawns | drainer | GC'd (+3d) by drainer | AUTO |
| `regressions/` | quality-gate regression capture | quality gates | review flows | KEEP |

## `~/knowledge/` (KNOWLEDGE_DIR) — the knowledge tier

| Path | What it is | Writer(s) | Reader(s) | Delete? |
|---|---|---|---|---|
| `wiki/{learnings,decisions,entities,issues,concepts,security,state,sources}/` | content categories (from `kb-schema.json`; live installs may also show generated `projects/` and `themes/`) | knowledge-maintainer + raw-drainer agents; dream accept; `archive_to_wiki`; extractor write-back; direct writes policed by `wiki-write-guard.sh` | `knowledge_search`/`knowledge_fetch`/`knowledge_validate`; session-load enrichment | **NEVER — this is the knowledge base** |
| `wiki/index.md` | regenerated catalog (never counted as a page) | `knowledge_reindex` MCP / `sb_reindex_wiki` | model + human | REGEN |
| `wiki/.embeddings-cache.json` | page-vector cache, keyed page path + content hash (`embeddings.ts:78-91`) | `knowledge_search` hybrid path (write-through on cache miss) | same | REGEN (rebuilt on next embedded search; audit-noted: written non-atomically, never pruned) |
| `wiki/themes/theme-<id>.md`, `wiki/projects/<key>.md` | dream SUMMARIZE theme pages; project MOCs (MOC = Map of Content, a generated hub page linking a cluster) | dream accept; reindex | search | regenerated by next dream/reindex |
| `graph/edges.jsonl` | bi-temporal typed edge log, **append-only** (assert/invalidate ops; history never rewritten) | `knowledge_relate` MCP; setup step 4b; `merge-edges.sh` | `knowledge_neighbors`; graph CLIs | NEVER (unrecoverable history) |
| `graph/project-registry.jsonl` | project facet anchors | setup step 4b | maintainer reconciliation | KEEP |
| `graph/edges-quarantine.jsonl` / `graph/conflicts.jsonl` | edges with bad endpoints / open conflicts | `merge-edges.sh` | maintainer drain | KEEP until drained |

Split rules worth memorizing: `graph/` is a **sibling** of `wiki/` under KNOWLEDGE_DIR, not inside
it; the raw inbox lives under BRAIN_DIR (`projects/<slug>/raw/`), **not** under KNOWLEDGE_DIR.
A legacy `~/.second-brain/wiki/` is never a valid write target — the canonical wiki is
`$KNOWLEDGE_DIR/wiki` (misroute symptom → sb-debugging-playbook).

Re-verify this map: `sed -n '8,17p' scripts/ensure-dirs.sh` (skeleton),
`grep -n "archive_dir=" scripts/lib.sh` (transcripts), `grep -n "'raw'" mcp/src/tools/raw-inbox.ts`
(raw inbox), `grep -n "wiki-backup-pre-accept" scripts/dream-accept.sh` (backup tarball),
`sed -n '30,41p' scripts/ensure-dirs.sh` (config defaults).
