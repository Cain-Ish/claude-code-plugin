# Changelog

## [1.2.0] - 2026-05-03

Persona-as-first-thought injection. Restores the brainstorm-before-answering protocol the v1.0 redesign dropped, but this time wired into the live hot tier and re-injected mid-session via a `UserPromptSubmit` hook. Lays the groundwork for v1.3's Stop-hook transcript reader (auto-write to PROJECT.md / wiki).

### Added

- `scripts/intent-gate.sh` — `UserPromptSubmit` hook that classifies prompts as substantive vs trivial (≥7 words, leading action verb, or any non-ack pattern → substantive) and emits a JSON `additionalContext` envelope with the Intent Analysis cue: extract keywords → run `second-brain:query` → generate self-followups → answer from retrieved context → surface only genuinely ambiguous high-cost questions to the user. Fail-soft (always exits 0) so a hook crash never blocks user input.
- `tests/test-intent-gate.sh` — 10-case suite covering substantive prompts, exact-match acks (yes/lgtm/ship it/...), sentence-shaped acks (`thanks, ...`), short prompts with action-verb prefix, empty prompts, malformed JSON input.
- `scripts/migrate-to-1.2.0.sh` — idempotent migration that appends a `## Intent` section to `~/.second-brain/USER.md` (5-step protocol) with backup to `~/.second-brain/.1.2.0-backup/<UTC-ISO>/USER.md`. No-op if the section is already present.

### Changed

- `hooks/hooks.json` — new `UserPromptSubmit` entry wires `intent-gate.sh` (timeout 5s).
- `scripts/verify.sh` — Check 1 now also asserts that `USER.md` contains a `^## Intent$` heading. New failure line: `verify: FAIL: USER.md — missing '## Intent' section (run migrate-to-1.2.0.sh or /second-brain:upgrade)`.
- `tests/test-verify.sh` — `seed_clean()` fixture now includes `## Intent`; new Subtest 10 covers a USER.md that lacks the section.
- `skills/setup/SKILL.md` — Step 2 (USER.md scaffold) now ensures the `## Intent` section is present, idempotent on re-runs.
- `skills/upgrade/SKILL.md` — new migration table row for `1.2.0` pointing at `migrate-to-1.2.0.sh`.

### Notes

- Background: the v1.0 redesign deleted the reflection→critic→learnings pipeline in favor of explicit pin/archive MCP tools, but those tools require Claude to choose to call them. In practice nothing did, so PROJECT.md and the wiki sat empty across sessions. Step 2 of the staged plan (a `Stop`-hook subagent that reads the conversation transcript and auto-writes deltas to PROJECT.md / wiki) lands in v1.3. This release fixes the read side: persona behavior actually fires before substantive responses, and the hot tier instructs Claude to query the wiki first.

## [1.1.0] - 2026-05-02

Hardening release derived from `ruvnet/ruflo` research. Adds a runtime smoke check (`scripts/verify.sh`) surfaced via `/second-brain:status`, locks in SessionStart-on-compact behavior with a regression test, and makes `allowed-tools:` mandatory in skill frontmatter. See `docs/specs/2026-05-02-ruflo-derived-hardening-design.md` and `docs/plans/2026-05-02-ruflo-derived-hardening-implementation.md`.

### Added

- `scripts/verify.sh` — runtime smoke check with 5 assertions: USER.md exists+non-empty, active project's PROJECT.md exists, combined hot-tier line count ≤ 66, `mcp/dist/server.js` present, `error-log.jsonl` has no entries newer than `.last-verify`. Fails loud on malformed JSONL. Accumulates failures and exits non-zero with one `verify: FAIL: <check> — <detail>` line per fault, or `verify: ok` on the clean path. Surfaced as Step 6 of `/second-brain:status`; remediation is delegated to `/second-brain:setup` and `/second-brain:improve` rather than auto-applied.
- `~/.second-brain/.last-verify` — ISO-8601 UTC timestamp written on every successful `verify.sh` run. Created lazily on first run; absent on first install.
- `tests/test-session-load-compact.sh` — regression test locking in SessionStart-on-compact hot-tier re-emit. Documents that PreCompact reload (a pattern observed in `ruvnet/ruflo`) is unnecessary because SessionStart's `compact` matcher already covers it.
- `tests/test-validate-plugin-allowed-tools.sh` — regression test for the new validator rule (mirrors the repo to a tmpdir, drops `allowed-tools:` from one skill, asserts the validator fails with the expected message).
- `tests/test-verify.sh` — 9-subtest suite covering verify.sh failure modes (clean state, missing/empty USER.md, oversized hot tier, missing MCP dist, fresh error-log entries, old-only entries, first-run, malformed JSONL).

### Changed

- `scripts/validate-plugin.sh` — `allowed-tools:` joins `name` and `description` as a required field in SKILL.md frontmatter (line 92). All 8 shipped skills already declare it.
- `tests/test-validate-plugin.sh` — the synthetic SKILL.md skeletons used by the validator's smoke test now include `allowed-tools: Read Bash(echo *)` so the suite still validates after the new rule lands.
- `hooks/hooks.json` — added `_comment` key on the SessionStart entry documenting why the `compact` matcher makes a PreCompact reload unnecessary.
- `skills/status/SKILL.md` — gained Step 6 ("Runtime smoke check") that invokes `verify.sh`. Existing dashboard step renumbered to Step 7. Bottom note updated to reflect verify.sh's role with `error-log.jsonl`. `allowed-tools` line gained `Bash(bash *)` so the skill can invoke the script.

### Notes

- No state migration required. `.last-verify` is created lazily; the `allowed-tools:` requirement is universal in shipped skills so existing installs do not need remediation. The migration table in `skills/upgrade/SKILL.md` carries a no-op row for 1.1.0 to bump the installed-version marker.
- 2 pre-existing FAILs in `tests/test-validate-plugin.sh` (about `improve-protocol.md` being declared a required runtime file but not enforced by the validator) predate this release and are not addressed here. Tracked as a separate cleanup.

## [1.0.0] - 2026-05-01

Major redesign — reflection→critic→learnings pipeline removed; replaced with hot-tier (USER.md + PROJECT.md) auto-load and explicit pin/archive MCP tools. See `docs/specs/2026-05-01-second-brain-v1-redesign.md` and `docs/plans/2026-05-01-second-brain-v1.0-implementation.md`.

### Removed
- 11 scripts: `extract-learnings.sh`, `log-friction.sh`, `smart-context.sh`, `drift-detect.sh`, `post-compact.sh`, `post-maintainer.sh`, `pre-clear.sh`, `budget-context.sh`, `decay-learnings.sh`, `compile-graph.sh`, `validate-proposal.sh`
- 6 skills: `browse`, `drift-check`, `graph`, `ingest`, `regress`, `review`
- 2 MCP tools: `knowledge_index`, `knowledge_feedback`
- 3 hook events: `UserPromptSubmit`, `PostCompact`, `SubagentStop`

### Added
- 1 new script: `stop-hook-predicate.sh` (4-condition boolean diff)
- 1 new wrapper: `run-stop-predicate.sh`
- 3 new MCP tools: `pin_to_user`, `pin_to_project`, `archive_to_wiki`
- New hot-tier files: `USER.md`, `projects/<slug>/PROJECT.md`, `index.txt`
- Migration script: `migrate-to-1.0.0.sh`

### Changed
- `knowledge_search` rebuilt with a Node filesystem walk + token-overlap scoring backend (no embeddings, no sqlite-vec, no external binary). The 1.0 plan documents originally proposed ripgrep; the shipped implementation uses `fs.readdir` + a `tokenize`/Set-intersection scorer because it's cross-platform and dependency-free.
- `session-load.sh` rewritten as hot-tier reader with SessionStart baseline capture.
- 7 skills retained but simplified: `setup`, `status`, `query`, `lint`, `improve` (rebuilt), `import-host`, `upgrade` (added 1.0.0 row).

## 0.6.6 (2026-04-29)

Hardens the jq dependency surface so missing-jq stops being a silent failure mode. Diagnoses the `grep -c || echo 0` regression that was producing `"0\n0"` and breaking every `jq --argjson` call. Adds a printf-based fallback in `sb_log_error` so missing-jq itself can still be logged.

### Fixed

- **`sb_count_drift` silent corruption (`scripts/lib.sh`)** — `grep -cF ... || echo 0` produced multiline `"0\n0"` when the session ID had no matches, breaking `jq --argjson dc "$SB_DRIFT_COUNT"` with `parse error: Invalid numeric literal`. This silently failed every reflection write since drift detection landed in 0.6.4. Replaced with `grep -cF ... || true` so grep's stdout `"0"` is the only output. Verified: every session that didn't have drift signals was emitting nothing to `.pending-reflections.jsonl` — explains why the learnings tier hadn't grown in two days.

### Changed

- **New `sb_require_jq()` helper (`scripts/lib.sh`)** — checks once per process (cached via `SB_JQ_OK`), logs to `error-log.jsonl` when jq is missing, returns nonzero so the caller can early-exit cleanly. Wired into `sb_collect_session_data`, `log-friction.sh`, `pre-compact.sh`, `drift-detect.sh`. The previous silent-exit pattern (`command -v jq >/dev/null 2>&1 || exit 0`) is replaced — missing-jq is now visible at the next SessionStart via the existing error-nudge banner instead of being invisible.
- **`sb_log_error` printf fallback (`scripts/lib.sh`)** — when jq is missing, the function used to fail silently because it built JSON via jq itself. Added a printf path that sed-escapes `"` and `\` and emits the same `{timestamp, script, message, exit_code}` shape. Means missing-jq can still be logged and surfaced to the user. Verified round-trip: printf-emitted lines parse cleanly with `jq -c '.'`.
- **Platform-aware preflight (`scripts/session-load.sh`)** — the SessionStart preflight now runs `uname -s` and surfaces the right install command first (`brew install jq` / `sudo apt install jq` / `winget install jqlang.jq`), with the other platforms listed as reference. One paste, no scrolling. The other-platforms list keeps users on a borrowed/SSH'd machine from being stranded.
- **Control-char strip in printf JSON fallback (`scripts/lib.sh`)** — the printf path now runs `tr -d '\000-\037'` before sed-escaping `"` and `\`. Without this, a multi-line `error_msg` (e.g. captured command output) would embed raw newlines inside the JSON string, fragmenting the JSONL record into two malformed lines. Surfaced by `/second-brain:doubt` after the printf path landed.
- **`sb_safe_json_array` helper guards `sb_write_reflection` (`scripts/lib.sh`)** — handoff vars (`SB_GOALS`, `SB_COMPLETED`, `SB_IN_PROGRESS`, `SB_BLOCKERS`) are now validated as JSON arrays before being passed to `--argjson`. A caller setting `SB_GOALS="some text"` (non-JSON) used to crash the jq call and lose the entire reflection; now falls back to `[]`. No current caller sets these — defensive guardrail for future code.
- **Precondition comment on `sb_log_error` (`scripts/lib.sh`)** — documents that callers must `mkdir -p "$BRAIN_DIR"` before invoking, since the function's `2>/dev/null` would otherwise swallow the "no such file" error and lose the log entry. All current callers honor this; the comment locks the contract for future hooks.

### Notes

- `error-log.jsonl` schema unchanged — the printf fallback emits the same field shape and order. Existing readers (`session-load.sh` error-nudge banner, `/second-brain:status`) work without modification.
- Bundling jq binaries was considered and rejected: 5 platform binaries × 5 MB each = 25 MB of git bloat, plus a maintenance burden for jq CVEs and signing. The actual user pain ("silent fails") is fixed by failing loud, which costs ~50 lines instead.
- This release does not change behavior when jq IS installed — every code path here is conditional on missing-jq or runs only on the first session start.

## 0.6.5 (2026-04-28)

Tree of Thoughts (ToT) reasoning patterns embedded into the three skills where deliberation actually matters: persona Intent Analysis, doubt drilling, improve critic gate. Pure protocol upgrade — no new files, no schema breaks.

### Changed

- **Persona Intent Analysis (`scripts/ensure-dirs.sh` seeded template + your local `~/.second-brain/persona.md`)** now generates 2–3 candidate interpretations of substantive requests, scores them against session context / learnings / style, picks the most consistent. Interpretation is **kept internal** — surfaces only via the existing focused-question channel when confidence is low — so the new step does not violate the persona's own "no narration" anti-pattern. Added an operational substantive-vs-simple test (verb-on-noun heuristic, default-to-simple) to keep ToT ceremony off small edits.
- **`skills/doubt/SKILL.md` step 3.4 (drilling protocol)** branches into 2–3 attack vectors at each level, evaluates each as `sure / maybe / impossible`, drills the highest-scoring branch first, backtracks to the next branch on VALIDATED rather than forcing depth, and adds a 3-level lookahead to pivot away from theoretical chains. Anti-self-deception rule: labelling a vector `impossible` requires a file:line citation that defends against it. Every branch (drilled or abandoned) is logged to a per-run scratchpad.
- **`skills/doubt/SKILL.md` step 4 (critic validation)** now receives the full branch log, not just findings. The quality-reviewer can flag SYSTEMATIC OVER-PRUNING when more than one abandoned branch has weak `impossible` justification — closes the ICRH gap at branch-selection time.
- **`skills/doubt/SKILL.md` step 6 (history schema)** appends four new fields to `~/.second-brain/doubt-history.jsonl`: `branches_generated`, `branches_drilled`, `branches_abandoned`, `over_pruned`. Backward-compat: old log entries lacking these fields are valid; readers default missing branch fields to 0.
- **`skills/improve/SKILL.md` step 5.5 (adversarial critic gate)** now requires the author to draft 2–3 candidate framings of each proposed learning (varying scope / phrasing / trigger specificity). Critic votes A / B / C / NONE, then ACCEPT / REVISE / REJECT on the winner only. Tiebreak rule: identical yes/no profiles → narrowest scope wins (decay-friendly). Strengthens the existing ICRH defense by separating framing-quality judgment from accept/reject judgment.

### Notes

- All changes are protocol upgrades to existing skills; no new files, no new dependencies, no breaking schema changes.
- The four new `branches_*` / `over_pruned` fields in `doubt-history.jsonl` are additive — `decay-learnings.sh` and `session-load.sh` are unaffected since neither reads doubt history.
- `critic-log.jsonl` schema unchanged — multi-framing flows through the same `proposal_title / destination / verdict / reason` fields. After a few reflection cycles, vote distribution in this log will tell you whether multi-framing is paying for itself or should be scaled back.
- ToT was applied selectively: `persona`, `doubt`, `improve` only. Skipped `query`, `regress`, `lint`, `drift-check`, `ingest`, `graph`, `import-host`, `upgrade`, `setup`, `status`, `browse` — those are mechanical / yes-no / ETL operations where multi-branch reasoning is overkill.

## 0.5.0 (2026-04-27)

Tier 2 + Tier 3 from the self-evolution audit. Same audit pass, no new research — just executing the punch list. Five new skills, four new scripts, schema additions to learnings.md and wiki source pages, and a hot-tier context budget on SessionStart.

### Added (Tier 2 — close the learning loop)

- **Confidence-scored learnings + decay.** Every entry written to `~/.second-brain/learnings.md` now carries a meta line: `<!-- meta: confidence=0.X hits=N last_used=YYYY-MM-DD -->`. The `/improve` critic gate now asks for and uses this score (0.3 borderline, 0.5–0.69 suggestion, 0.7+ auto-apply, 0.9+ strong). New `scripts/decay-learnings.sh` runs at SessionStart and evicts entries that meet ALL three thresholds: age > 60d AND hits < 2 AND confidence < 0.5. Backs up before any deletion; logs to `~/.second-brain/decay-log.jsonl`. Replaces the binary keep/reject model that affaan-m and naimkatiman both moved away from.
- **Positive signal capture.** `log-friction.sh` now classifies prompts as `direction: positive | negative` instead of friction-only. Two new positive types: `praise` ("perfect", "thanks", "exactly") and `acceptance` ("ok", "yes", "lgtm"). Negative-pattern check still runs first so mixed prompts ("no wait that's perfect") classify as friction. `extract-learnings.sh` filters on `direction != "positive"` for the friction count, computes a separate `positive_signals` count, and emits a `first_try_success` boolean (true when `friction_count == 0` AND `user_turns >= 3`) into both session metadata and pending-reflection.
- **`/second-brain:regress` skill.** Replays one-line probes from `~/.second-brain/regressions/<learning-slug>.md` against fresh-context subagents, scores against `expected_pattern` / `forbidden_pattern` regexes, logs results to `.results.jsonl`, and reports 30-day pass-rate trend per probe. Catches "the model started doing X again" silently. Anthropic's eval-driven dev recommendation, finally implementable.
- **Wiki coverage + freshness tags.** Source pages get two new fields under `## Source`: `Coverage: high|medium|low` and `Freshness tier: live|7d|30d|90d|permanent`. `/second-brain:lint` gains step 7c (past-TTL freshness — flag pages where `today - Ingested > tier days`) and step 7d (low coverage stale stubs). Pages without these fields (legacy) are skipped.
- **Research-on-miss in `/query`.** When semantic + keyword search return nothing, the skill no longer just says "not found." It offers to web-research and ingest the result as a new wiki source. Gated on user confirmation (research costs tokens). Adds `WebSearch` and `WebFetch` to the skill's allowed-tools.

### Added (Tier 3 — strategic evolution)

- **Importance-triggered reflection.** `extract-learnings.sh` now writes a `priority: high | normal` flag and a `drift_count` field into `.pending-reflection.json`. Priority is `high` when `friction_count >= 5` OR `drift_count >= 3`. `session-load.sh` surfaces a `HIGH-PRIORITY REFLECTION QUEUED` banner at the top of its SessionStart output when this fires, telling Claude to process the reflection BEFORE responding to the user's first message. Mirrors the importance-sum trigger from Generative Agents (Park 2023).
- **Hot/warm/cold context budget.** New `scripts/budget-context.sh` scores each learning by `confidence × (1 - days_since_last_used / 180)` and emits only the top entries that fit `SECOND_BRAIN_HOT_BUDGET` chars (default 16000 ≈ 4k tokens). `session-load.sh` regenerates `~/.second-brain/.learnings-hot.md` at every SessionStart and points Claude there instead of the full file. Demoted entries stay in `learnings.md` and are retrievable via `/second-brain:query`. Stops the unbounded-injection trap.
- **`/second-brain:upgrade` skill.** Idempotent migration runner. Reads `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` vs `~/.second-brain/.installed-version`, applies only the migrations between them. Migration table is inline; current entries cover 0.4.0 (additive) and 0.5.0 (additive — meta lines, coverage/freshness fields, regressions/ dir).
- **`/second-brain:graph` skill + `scripts/compile-graph.sh`.** Compiles a typed link graph from inline `graph:` blocks (`{relation: depends_on, target: <slug>, evidence: "..."}`) and untyped `[[wiki-links]]` (relation `links_to`) into `~/knowledge/.graph/edges.jsonl` and `nodes.jsonl`. Skill supports `rebuild`, `neighbors <slug>`, `path <from> <to>`, `by-relation <relation>`. praneybehl's pattern.
- **`/second-brain:import-host` skill.** Bootstrap import from existing AI-context files: `~/CLAUDE.md`, `~/AGENTS.md`, `~/.cursorrules`, `~/.claude/CLAUDE.md`, `~/.claude/instructions.md`, plus repo-local equivalents under the current `git rev-parse --show-toplevel`. Three import paths per file: wiki source (default safe), persona merge (critic-gated), quality-rules merge (critic-gated). Logs to `~/.second-brain/import-log.jsonl`. Closes the "plugin installed but I already wrote my rules elsewhere" gap. strvmarv's host-importer pattern.

### Changed

- **`session-load.sh` SessionStart output** now references `~/.second-brain/.learnings-hot.md` instead of `~/.second-brain/learnings.md` directly, with an inline note that the full file is retrievable via `/second-brain:query`. Falls back to the full file when budget-context.sh isn't available.
- **`improve/SKILL.md` step 5.5 (critic gate)** now asks the critic for a confidence score (0.3–0.9), not just ACCEPT/REVISE/REJECT. Score is written into the meta line in step 6.

### Notes

- All new files (`drift-log.jsonl`, `critic-log.jsonl`, `decay-log.jsonl`, `import-log.jsonl`, `regressions/`, `.graph/`, `.installed-version`, `.learnings-hot.md`) are created on first write — no migration needed. Run `/second-brain:upgrade` to record the version marker and verify everything is in place.
- Schema changes to `learnings.md` and wiki source pages are **purely additive**. Old entries continue to work; new fields are populated as you write new entries.
- `decay-learnings.sh`, `budget-context.sh`, and `compile-graph.sh` use POSIX-only awk constructs (`match()` + `RSTART/RLENGTH` + `substr()`) so they work on macOS BSD awk, Linux mawk/gawk, and Git Bash for Windows.
- Tier 0 (ICRH critic gate) and Tier 1 (schema fixes, drift detector) shipped in 0.4.0. This release closes the audit punch list end-to-end.

### Post-review fixes (still 0.5.0, pre-release)

A full code review surfaced gaps that were silently breaking the new features. All fixed before release:

- **CRITICAL — Stop hook order:** swapped `drift-detect.sh` and `extract-learnings.sh` in `hooks/hooks.json`. extract-learnings now reads `drift-log.jsonl` AFTER drift-detect writes to it; the importance-trigger `priority: high` flag actually fires on current-session data.
- **CRITICAL — gawk-only awk patterns:** `match($0, /re/, m)` (3-arg) is gawk-only and silently fails on macOS BSD awk and mawk. Rewrote all four occurrences (`extract-learnings.sh:97`, `decay-learnings.sh`, `budget-context.sh`, `compile-graph.sh`) to use POSIX `match() + RSTART/RLENGTH + substr()`. Without this, decay never fired on macOS, budget scoring used defaults, typed graph edges were never extracted.
- **CRITICAL — `Agent` missing from `allowed-tools`:** `improve`, `drift-check`, `regress`, `import-host` all dispatch subagents (the critic gate, probe runner, etc.) but their frontmatter didn't allow it. The Tier 0 critic gate from 0.4.0 was blocked at runtime. Added `Agent` to all four.
- **CRITICAL — `/regress` was decorative:** `improve/SKILL.md` step 6 never instructed creating probe files. Now it does — emits `~/.second-brain/regressions/<slug>.md` with `expected_pattern` / `forbidden_pattern` frontmatter when the learning is probe-amenable.
- **CRITICAL — JSON injection in extract-learnings.sh:** both `.last-session-meta.json` and `.pending-reflection.json` were built with heredoc + raw `$SESSION_ID`/`$TIMESTAMP` interpolation. Replaced with `jq -n --arg/--argjson` so tampered hook input can't malform the JSON files that session-load.sh subsequently parses.
- **CRITICAL — CRLF line endings:** added `.gitattributes` with `*.sh text eol=lf`. Without this, Windows clones with default `core.autocrlf=true` commit CRLF and break bash shebangs on Linux/macOS.
- **WARNING — decay backup retention:** `decay-learnings.sh` now caps `learnings.md.bak.*` retention at 5 (configurable via `SECOND_BRAIN_DECAY_BACKUPS_KEEP`). Previously unbounded, disk-fill path on busy installs.
- **WARNING — decay no-jq fallback removed:** the `printf` fallback was a JSON-injection hole; jq is already a hard dependency surfaced by `session-load.sh` preflight.
- **WARNING — decay CUTOFF empty-guard:** `set -u` plus double `date` failure could produce `CUTOFF=""`, making `last_used < ""` always-true, mass-deleting all entries with metadata. Now exits 1 on empty cutoff.
- **WARNING — decay malformed-meta defensive default:** non-numeric `confidence=` values default to 1 (keep-safe) instead of being coerced to 0 (drop-aggressive).
- **WARNING — `\x01` placeholder in budget-context.sh:** mawk treats `\x01` as the literal 4-char string. Replaced with `\034` (POSIX octal escape) and updated `tr` decoder to match.
- **WARNING — budget byte/char mismatch:** `wc -c` returns bytes, `${#STRING}` counts characters in shell. With Unicode the budget calc drifted. Set `LC_ALL=C` so both agree on bytes.
- **WARNING — compile-graph.sh slug/tgt unescaped:** the no-jq fallback printf injected raw values into JSONL. Now jq is required (matches the rest of the plugin) and all fields route through `jq -nc --arg`.
- **WARNING — drift-detect ReDoS:** user-supplied regex from `persona.signals.json` is now wrapped in `timeout 1 grep` so a malicious nested-quantifier pattern can't hang the Stop hook.
- **WARNING — `/upgrade` had no auto-invocation:** `session-load.sh` now compares `~/.second-brain/.installed-version` to `plugin.json` and emits a one-line nudge when they diverge.
- **WARNING — drift signals never surfaced:** `session-load.sh` now emits a one-line banner when `drift-log.jsonl` has 5+ hits in the last 7 days, pointing at `/second-brain:drift-check`.
- **WARNING — `.last-maintainer-run` was a dead pipeline:** `session-load.sh` now reads it and suggests `/second-brain:graph rebuild` when the maintainer ran more recently than the graph was compiled.
- **INFO — magic numbers as env vars:** `SECOND_BRAIN_FRICTION_TRIGGER` (default 5) and `SECOND_BRAIN_DRIFT_TRIGGER` (default 3) for the importance-trigger thresholds.
- **INFO — `session-load.sh` weird `-x OR -f` test:** simplified to `-f` only (bash scripts don't need execute bit).

## 0.4.0 (2026-04-27)

Self-evolution audit response. Three independent research passes (leaked Anthropic internals, top public Claude Code plugins, self-evolution literature) converged on one critical correctness bug and a clear gap list. This release fixes the bug and lands the highest-payoff additions.

### Added

- **Adversarial critic gate in the learning loop (Tier 0 correctness fix).** The `improve` skill and the `session-load.sh` inline-reflection instruction both ran the same Claude as author, balance-test scorer, *and* judge — Iterative Self-Refinement Reward Hacking ([Pan 2024, arxiv 2407.04549](https://arxiv.org/html/2407.04549v1)). New step 5.5 in `skills/improve/SKILL.md` requires every candidate learning to pass a fresh-context critic (`second-brain:quality-reviewer` or `general-purpose`) before any write to `learnings.md` / `quality-rules.md` / `persona.md`. Critic gets only the proposal text + destination + one anonymized friction example — no transcript. Verdicts (ACCEPT/REVISE/REJECT) are logged to `~/.second-brain/critic-log.jsonl` for acceptance-rate auditing.
- **Persona drift detector.** New `scripts/drift-detect.sh` runs on every Stop and greps the last 20 assistant turns for high-precision phrases that `persona.md` explicitly forbids (filler "Certainly!"/"Great question", AI attribution "Co-Authored-By:", narration "Let me explain"). Hits land in `~/.second-brain/drift-log.jsonl` as `{timestamp, session_id, signal_id, claim, excerpt}`. Built-in 8-signal default list; users can override via `~/.second-brain/persona.signals.json`. One entry per signal per run to avoid log spam; rotates at 5000 lines.
- **`/second-brain:drift-check` skill.** Diagnostic skill that reads the drift log, aggregates by signal_id over a configurable window (`--days N` / `--since YYYY-MM-DD`), distinguishes "single bad turn" from "real drift across sessions", and proposes persona.md strengthenings. All persona.md writes go through the same critic gate as `improve` — no silent mutation.
- **`SubagentStop` hook for `knowledge-maintainer`.** Writes `~/knowledge/.last-maintainer-run` (ISO8601 UTC timestamp) so subsequent sessions can detect bulk-modified wiki state and decide whether to reindex. New script: `scripts/post-maintainer.sh`.

### Changed

- **Agent frontmatter aligned with Anthropic reference plugins.** `knowledge-maintainer` and `quality-reviewer` now use YAML block-scalar `description:` with embedded `<example>` blocks (improves auto-delegation reliability per `anthropics/claude-code/plugins/pr-review-toolkit`). Added `color:` field on both. `knowledge-maintainer` gets an explicit `tools: Read, Write, Edit, Glob, Grep, Bash` allowlist that actually enforces the "no web tools" claim its description has been making since 0.1. Removed `maxTurns` (Anthropic's reference agents don't set it; was artificially truncating bulk wiki work).
- **`lint` skill is now auto-invocable** (`disable-model-invocation: false`). Was blocking Claude from auto-running it when the user asked about wiki health. User-invocability via `/second-brain:lint` is unchanged.

### Notes

- `~/.second-brain/critic-log.jsonl` and `~/.second-brain/drift-log.jsonl` are created on first write — no migration needed.
- The drift detector's signal list is intentionally short and high-precision. False positives erode trust faster than missed signals; the override file is the right place to add domain-specific patterns.
- `persona.signals.json` schema: `{"forbidden_phrases":[{"id":"...","claim":"...","pattern":"<extended-regex>"}, ...]}`.
- Tier 2/3 items from the audit (confidence-scored learnings, decay/forgetting, hot/warm/cold context budget, eval framework, graph layer, freshness tags) are tracked but not in this release — file follow-ups before shipping.

## 0.3.10 (2026-04-27)

Two bugs that together produced the worst failure mode: a healthy-looking install where every persistent pipeline silently does nothing.

### Fixed

- **Silent jq-missing failure surfaced as a loud preflight error.** Every hook script (`log-friction.sh`, `extract-learnings.sh`, `pre-compact.sh`, `discover-tools.sh`) parses hook stdin with `jq`. When `jq` isn't on PATH (common on Windows), each script's first jq call returned an empty string and the script exited gracefully — friction-log stayed empty, no `.pending-reflection.json` was ever written, no learnings extracted. `session-load.sh` now does a `command -v jq` preflight at the top of its SessionStart output and emits a clear `SECOND BRAIN PREFLIGHT FAILURE` banner with per-OS install commands when jq is missing. The remaining load instructions still emit so in-session behavior is unaffected, but the user knows immediately why the persistent pipeline isn't working.
- **`extract-learnings.sh` and `pre-compact.sh` user-turn counter always returned 0.** Both used `select(.role=="user")` against the transcript JSONL, but Claude Code's transcript schema puts the role at `.message.role` and the record kind at top-level `.type`. With 0 user turns, `extract-learnings.sh` would short-circuit at `[ "$USER_TURNS" -lt 3 ]` and never write `.pending-reflection.json` — meaning the SessionStart "process pending reflection" branch never fired and no wiki sessions/learnings pages were ever created, regardless of how much real work happened. Both scripts now use `select(.type=="user" and (.message.content | type == "string"))` which counts actual user prompts (string content) and excludes tool-result messages (array content).

### Notes

- 0.3.9 and earlier appear healthy: `~/.second-brain/` is populated with persona/quality-rules/learnings, `~/knowledge/wiki/` has the right subdirectories, and SessionStart instructions inject correctly. But on systems without `jq`, *or* on any system at all because of the user-turn filter bug, the reflection→learning→wiki pipeline silently produces nothing. Update to 0.3.10 to surface the dependency error and fix the filter.
- Existing seed files are not touched on upgrade. Past sessions are not retroactively reflected on (the transcripts are still on disk; running `extract-learnings.sh` manually with the right input would extract them, but the plugin doesn't do that automatically).

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
