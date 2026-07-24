# P1 — Loop Observability Implementation Plan (liveness → value → utilization → compounding)

**Status: SHIPPED (0.33.36–0.33.37).** Tasks 1–4 shipped in 0.33.37 (`19c07f6`); Task 5 (the firewall lock) shipped in 0.33.36 (`4df214b`). Two deviations from the plan as written — see the notes on Tasks 3 and 4.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task. Checkbox (`- [ ]`) tasks; respect dependency order (Task 1 ships alone; Tasks 2+4 share a pass; Task 3 is independent).

**Goal:** Close the measurement gap named by the loop-engineering research (`docs/specs/2026-07-08-loop-engineering-research-and-plugin-improvement.md` Phase 1): the plugin's autonomous loops fail SILENTLY (a drainer dead on the maintainer's own OS produced zero errors), and nothing measures whether the memory the loops maintain actually HELPS (injected slugs Read? skills ever invoked? prior-session knowledge reused?). Four telemetry slices, strictly observation-only.

**Architecture:** No new subsystems — consolidation plus two small correlation passes over surfaces that already exist. LIVENESS reads the state files the loops already stamp (`.extractor-health.json` — stamped at the end of EVERY drainer run; `.extraction-state.jsonl` done-set; dream `status.json` mtime heartbeats; `sb_timer_health`; raw-inbox depth) and renders them in `sb status` + `/second-brain:status`. VALUE and COMPOUNDING share one deterministic Stop-time jq pass: `session-load.sh` writes an injection manifest per session (wiki slugs, code-map spine paths, graph nodes it actually emitted); `stop-extract.sh` correlates the manifest against the transcript's Read/knowledge_fetch tool_use records and appends `gate=`-style TRACE rows (`kind:"value"`, `kind:"compound"`) to the audit-log via the existing R6b routing. UTILIZATION is a drain-time jq count of `Skill`/`Task` tool_use per archived transcript into `$BRAIN_DIR/utilization-counts.json`, rendered as a dormant-capability report. Everything lands in the two existing log channels or `sb status` — no new banners except one: loop-dead (timer installed but last drain older than threshold).

**Tech Stack:** bash + jq only (no awk for JSON); TS only in `mcp/src/cli/sb.ts` (status rendering). Tests: bash harnesses under `tests/`, vitest for the CLI section. No new dependency, no native code.

This plan implements spec Phase 1 (P1.1–P1.4) and gates Phase 4 (P4.1 routing may ship only when P1.2 shows injected hints are actually Read).

---

## Constitution compliance

- **Fully autonomous.** All four slices run inside existing autonomous paths (SessionStart, Stop, drainer tick). No manual step; `sb status` is a read surface, not a required action.
- **Cross-platform.** bash-3.2/BSD floor; jq with `-c` and `tr -d '\r'` after every `jq -r` capture (jq-CRLF discipline); no GNU-only constructs. Portability + macOS CI gates apply.
- **Reversible / observation-only — THE FIREWALL.** Telemetry is write-only from the loops' perspective: **no ranking, forgetting, graph, or dedup code may ever read `utilization-counts.json`, the injection manifests, or the value/compound TRACE rows** (undo rows 16-18: usage-frequency feedback = rich-get-richer bias; the shipped precedent is `access-counts.json`, whose `acc` is deliberately excluded from the forget score). Machine lock: a source-scan test greps `mcp/src/tools/{knowledge-search,codemap/*}.ts` + `scripts/wiki-forget-*.sh` for the telemetry filenames and FAILS on any reference.
- **Untrusted-content isolation.** The correlation passes read transcripts as DATA (jq field extraction only, no LLM, no execution). Manifest/count files live in `$BRAIN_DIR` (runtime state, never under plugin root).

## Global Constraints

- **Version lockstep** per release; recompute target versions at implementation time.
- **Surface budget:** no new `scripts/*.sh` (liveness folds into `sb.ts` + `session-load.sh`; correlation folds into `stop-extract.sh`; utilization folds into `extract-drain.sh`). New tests: ~3 bash files + vitest cases → bump `tests` in the same commits.
- **Fail loud:** correlation/count failures route through `sb_log_error` (ec≥1) or `gate=` TRACE (ec=0); no new `2>/dev/null` exits. The passes themselves must never fail the hook (fail-soft boundary like the codemap CLI — errors reported, hook exit 0).
- **Test the fallback branches:** no manifest, empty transcript, missing state files, CRLF store, kill-switch off.
- **Flags (register in the dev flag catalog):** `SB_TELEMETRY` (master, default on — kills value/utilization/compound passes), `SB_LOOP_DEAD_BANNER` (default on), `SB_LOOP_DEAD_HOURS` (default 48).

---

### Task 1: P1.1 liveness — one queryable surface + the loop-dead banner

- [x] `sb status` gains a `## Loop liveness` section: extractor health (`status`, `reason`, `checked_at` age), newest done-set entry age, backlog count (the §5 comm probe, CRLF-safe), scheduler state (`sb_timer_health`), newest dream (id, status, heartbeat age vs `SB_DREAM_RUN_TIMEOUT`), raw-inbox unprocessed depth. Every value from an EXISTING state file; missing file renders `never` — loud, not blank.
- [x] `session-load.sh` loop-dead banner: timer reports `installed` AND newest of (`.extractor-health.json` `checked_at`, newest done-set `ts`) older than `SB_LOOP_DEAD_HOURS` → one banner naming the last-run age and the probe command. This is the case today's banners MISS (self-install covers timer-absent; drain-health covers timeouts/dead-letters; nothing covers installed-but-never-ticks — the live Windows/macOS breakage).
- [x] Tests: bash — banner fires on stale marker + timer-installed fixture; silent when fresh, when timer absent (self-install banner owns that), and with `SB_LOOP_DEAD_BANNER=off`; vitest — status section renders with all files present / all absent.

### Task 2: P1.2 value — injection manifest + Stop-time Read correlation

- [x] `session-load.sh`: each injecting section (wiki-enrichment slugs, code-map spine, graph neighbourhood) appends `{kind, id}` lines to `$BRAIN_DIR/.injected-manifest-<session_id>.jsonl` as it emits (7-day GC alongside the existing `.injected/` memos).
- [x] `stop-extract.sh`: after extraction, one jq pass over the transcript collects Read file_paths + `knowledge_fetch`/`knowledge_search`-followed-by-Read slugs; intersect with the manifest; append TRACE `gate=value-loop injected=N read=M hits=<csv>` (ec=0 → audit-log via R6b). Delete the manifest.
- [x] Tests: manifest written; correlation counts a Read hit and a zero-hit session; no-manifest fallback silent; `SB_TELEMETRY=off` skips.

### Task 3: P1.3 utilization — invocation counts + dormant report

> **Deviation (shipped form):** the utilization fold landed in `scripts/stop-extract.sh` (the Stop pass, alongside the Task-2/4 correlation), not `extract-drain.sh` as planned below.

- [x] `extract-drain.sh` (inside the single-flight lock, after codemap regen): per newly-drained transcript, jq-count `tool_use` where `name=="Skill"` (`.input.skill`) or `name=="Task"` (`.input.subagent_type`), fold into `$BRAIN_DIR/utilization-counts.json` (`{name: {count, last_used}}`, atomic tmp+rename). *(Shipped in `stop-extract.sh` — see deviation note.)*
- [x] `sb status` `## Utilization` section: top-used + DORMANT list = this plugin's own installed surface (`skills/*/` user-invocable + `agents/*.md`) with zero count in the trailing 30 days. Cross-plugin names render as counts only (no dormancy claim — we can't enumerate other catalogs).
- [x] Tests: counts fold correctly across two drains; dormant list flags a never-invoked fixture agent; corrupt counts file → rebuilt loud, not crash.

### Task 4: P1.4 compounding — prior-session knowledge actually reused

> **Deviation (shipped form):** P1.4 landed as a `prior=` field inside the single `gate=value-loop` TRACE row — there is no separate `gate=compound-loop` row. The cumulative-ratio display in `sb status` was NOT built and remains open.

- [x] In the Task-2 Stop pass: for each manifest hit that is a wiki page, read its frontmatter `created` date; count hits where `created` < session start date → append TRACE `gate=compound-loop prior_pages_read=K of_total_hits=M`. *(Shipped as `prior=` inside the `gate=value-loop` row — see deviation note.)*
- [ ] `sb status` renders the cumulative ratio from the audit-log tail (last 200 value/compound rows): "prior-session knowledge reused in X of Y sessions with hits". **NOT built — still open** (see deviation note).
- [x] Tests: a fixture page created yesterday Read today counts; a same-session page does not; missing frontmatter date → excluded loud (TRACE note), not crash.

### Task 5: the firewall machine lock

- [x] Source-scan test (vitest or bash): `knowledge-search.ts`, `episodic-search.ts`, `codemap/*.ts`, `graph-store.ts`, `wiki-forget-score.sh`, `wiki-forget-candidates.sh` contain NO reference to `utilization-counts`, `.injected-manifest`, `value-loop`, `compound-loop`. This is the undo-rows-16-18 guarantee as a failing test, not a promise. *(Shipped early, in 0.33.36 `4df214b`, ahead of the telemetry it firewalls.)*

## Success criteria

1. `sb status` answers "did the loops run?" in one read on a machine where the drainer is dead (the live Windows case renders a red age, not silence).
2. After one week of normal use: value rows exist for every session with injections; the utilization report names ≥1 genuinely dormant capability (candidate: the `/improve` pipeline, dormant since 0.30.x).
3. P4.1's precondition is now MEASURABLE (hit-rate query documented in the spec).
4. The firewall test is green and would fail on a one-line boost patch.
