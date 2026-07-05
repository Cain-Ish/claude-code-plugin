# State-file map — BRAIN_DIR vs KNOWLEDGE_DIR (full inventory)

Companion to `sb-architecture-contract/SKILL.md` §"Data geography". Definitions of BRAIN_DIR and
KNOWLEDGE_DIR live in the SKILL.md. Every row below was verified against the working tree as of
0.33.31 (2026-07-05); evidence column names the writer/reader that proves the row.

Re-verify any row: `grep -rn '<filename>' scripts/ mcp/src/ | head -5`

## `$BRAIN_DIR` — default `~/.second-brain` (private runtime state, per-machine)

| Path | Purpose | Evidence |
|---|---|---|
| `USER.md` | pinned user preferences (2200-byte cap, dated dedupe); hot tier, force-injected first | `lib.sh` (sb_pin_to_user area), `session-load.sh` |
| `persona-card.md` | persona identity; its `## Charter` section is force-injected (≤500 B reserve) | `session-load.sh:105-110` |
| `projects.jsonl` | project registry — ONE compact JSON object per line, deduped by slug | `lib.sh:571` (`sb_harden_projects_jsonl`), `session-load.sh` |
| `projects/<slug>/PROJECT.md` | per-project hot tier (Goal/State/Plan/Conventions/Recent decisions/Open blockers/Cross-references) | `session-load.sh:40-79` |
| `projects/<slug>/pending-extraction.log` | degraded-capture sidecar when the LLM extractor is unavailable (deduped/day, bounded 50 lines) | `stop-extract.sh:176-212` |
| `projects/<slug>/raw/` | raw inbox — captured items awaiting the raw-drainer | `mcp/src/tools/raw-inbox.ts:41-43` |
| `transcripts/<sid>_<slug>_<date>.txt` | preprocessed session archives, dream-minable + episodic-searchable; caps 100 files / 5 MB | `lib.sh` (`sb_archive_transcript`, `sb_prune_transcripts`) |
| `transcripts/sub-<aid>_<slug>_<date>.txt` | subagent FINAL results; own cap `SB_SUBAGENT_ARCHIVE_CAP` (default 50) pruned before the shared cap | `lib.sh` (`sb_archive_subagent`) |
| `dreams/drm_*/` | dream state: `status.json`, `staging/wiki/`, `transcripts/`, `diff.md`, `forget-manifest.tsv` | `dream-snapshot.sh`, `agents/dream-runner.md:33-36` |
| `wiki-archive/` + `wiki-archive-log.jsonl` | reversible FORGET store + append-only event log | `scripts/wiki-restore.sh:8`, `skills/dream/SKILL.md:242` |
| `wiki-backup-pre-accept-<stamp>.tgz` | fail-closed live-wiki backup taken before every dream accept | `dream-accept.sh:140-152` |
| `config.json` | autonomy + retention config, seeded once, never clobbered | `ensure-dirs.sh:19-41` |
| `error-log.jsonl` | fail-loud error channel; rotates >512 KB → newest 1000 lines | `lib.sh:171-232` |
| `audit-log.jsonl` | guard-verdict trajectory channel `{ts,hook,verdict,rule,target,reason,session_id,extra}`; rotates 5000 lines / 5 MiB, oldest half dropped | `lib.sh:234-306` (`sb_log_audit`) |
| `episodic-index.json` | episodic transcript search index (rebuilt incrementally after each Stop) | `stop-extract.sh:265-269`, `mcp/src/tools/episodic-search.ts` |
| `regressions/` | created at ensure-dirs (regression fixture drop zone) | `ensure-dirs.sh:9` |
| `.active-session-slug` | shared last-session pin — the LOWEST-precedence slug-resolver input | `session-load.sh:37`, `project-dir.ts:58-61` |
| `.session-baseline-<slug>.md` | PROJECT.md copy taken at SessionStart, diffed at Stop, then deleted | `session-load.sh:81`, `stop-extract.sh:271` |
| `.last-extracted-line-<slug>--<sid>` | extraction window markers (disjoint Stop/PreCompact windows); GC `-mtime +30` | `lib.sh:687+`, `extract-drain.sh:301` |
| `.extraction-state.jsonl` | out-of-band drainer per-transcript ledger (`outcome: ok\|retry\|error`) | `extract-drain.sh:196` |
| `.extract-drain.lock` / `.extract-drain.lock.d` | drainer single-flight: `flock`, else mkdir-lock with `SB_DRAIN_LOCK_STALE` (7200 s) staleness steal | `extract-drain.sh:200-227` |
| `.drain-defer-count` / `.last-drain-escape` | drainer starvation-escape state (defer counter + escape cooldown stamp) | `extract-drain.sh:86-87, 134-139` |
| `.extractor-health.json` | extractor backend health, surfaced by the next SessionStart banner | `lib.sh` (extractor area), `extract-drain.sh:311+` |
| `.injected/` | per-session injection dedup memos; GC 7 days | `ensure-dirs.sh:44-49` |
| `.llm-maintain-quarantine` / `.llm-maintain-fails` | headless-maintainer 3-strike quarantine (self-clearing); bannered at SessionStart | `maintain-llm-drain.sh:37-74`, `dream-autostage.sh` |
| `.pin-candidates.jsonl` | high-confidence persona-signal pin suggestions | `stop-extract.sh:253-259` |
| `bin/sb-extract-drain.sh` + `.extract-timer-env` | upgrade-stable scheduler shim (resolves latest installed plugin version) + captured env (chmod 600) | `install-extract-timer.sh:25-32, 82-122` |
| `scratch/` | nested-extractor cwd; its Claude Code transcripts GC'd +3 days | `extract-drain.sh:302-309` |
| `.persona-dismissals.jsonl` | persona dismissal log driving injection backoff | `persona_dismiss` MCP tool (server.ts:509) |
| `vector-deps/` | shared optional embedding deps (~490 MB), junction/symlinked per plugin version | `bin/install-vector-deps.sh` |

## `$KNOWLEDGE_DIR` — default `~/knowledge` (the durable knowledge base, meant to outlive machines)

| Path | Purpose | Evidence |
|---|---|---|
| `wiki/{learnings,decisions,entities,issues,concepts,security,state,sources}/` | the 8 content categories from `kb-schema.json` (repo root — single source of truth) | `ensure-dirs.sh:13-17`, `kb-schema.json` |
| `wiki/index.md` | regenerated catalog; never counted as a page by the accept floor | `lib.sh` (`sb_reindex_wiki`), `dream-accept.sh:101` |
| `wiki/themes/theme-<id>.md` | dream SUMMARIZE cluster pages, idempotent via `member_hash` | `agents/dream-runner.md:117-142` |
| `wiki/projects/<key>.md` | deterministic per-project MOC ("Map of Content" — a generated overview page linking a project's pages) | `kb-schema.json` `generated_dirs` |
| `wiki/learnings/reflection-<id>.md`, `wiki/concepts/reflection-<id>.md` | dream REFLECT grounded-practice pages (in EXISTING categories, never a new dir) | `agents/dream-runner.md:144-176` |
| `graph/edges.jsonl` | bi-temporal, append-only typed edge log (`requires/affects/relates/part_of/supersedes`) | `scripts/merge-edges.sh`, `mcp/src/tools/graph-store.ts` |
| `graph/conflicts.jsonl` | open graph conflicts (maintainer-owned drain; dream reads it read-only) | `agents/dream-runner.md:98-100` |
| `graph/edges-quarantine.jsonl` | edges whose endpoints could not be resolved to wiki pages | `merge-edges.sh:25` |

## Legacy trap

`~/.second-brain/wiki/` is a LEGACY location. The canonical wiki is `$KNOWLEDGE_DIR/wiki`
(`~/knowledge/wiki`). Anything that writes pages under `~/.second-brain/wiki` is a bug even if it
"works" — those pages are invisible to `knowledge_search`. Check: `find ~/.second-brain/wiki -name '*.md' 2>/dev/null`.
(Operational history: the raw-drainer agent has misrouted there — see sb-debugging-playbook.)
