# SB_* flag catalog — every environment variable, by subsystem

Verified against the 0.33.31 working tree on 2026-07-05 (uncommitted release batch; plugin.json
already says 0.33.31). Every `file:line` below was confirmed either by reading the file or by the
bulk extraction greps in SKILL.md §10. Census: ~187 distinct `SB_*` names across
`scripts tests mcp/src hooks skills agents bin cost-router`, of which 17 are test-infrastructure-only
(§10 below).

**Kind legend:**

| Kind | Meaning |
|---|---|
| KS | Kill switch (default on; only the literal string `off` — or `0` for `:-0` flags — disables). Default-on KS/TUNE/PATH/MODE rows with no other marker are the PRODUCTION tier. |
| KS(opt-in) / EXPERIMENTAL | Opt-in / experimental tier: OFF by default, does nothing until explicitly enabled (e.g. `SB_GRAPH_RANKING_BOOST`, `SB_QUALITY_GATE_LLM`, `SB_CONFLICT_MULTIPARENT`) — SKILL.md §8 lists them all |
| TUNE | Numeric/string tuning knob |
| PATH | Path or file override |
| MODE | Enum/mode selector |
| INT | Internal variable set by the plugin itself — NOT a user axis; do not document as a flag |
| TESTDBL | Test double/override; production runs never set it |
| ADVISORY | Read only by LLM prompt text in skills/agents markdown — enforcement depends on the model following the prompt, not on code |
| DEBUG | Escape hatch, never set in prod |
| DEPRECATED | Documented dead; zero live consumers |

**Tests column:** `bash` = the name appears in `tests/*.sh`; `vitest` = appears in
`mcp/src/**/*.test.ts`; `none` = neither (verified by set-diff, commands in SKILL.md §10). Where
the default path is tested, the env-OVERRIDE branch typically is not — the house rule (pinned
feedback: test fallback/default branches) says treat "bash" as necessary, not sufficient.

---

## 1. Directory & identity plumbing

| Var | Default | Effect | Kind | Site | Tests |
|---|---|---|---|---|---|
| `SB_BRAIN_DIR` | `$HOME/.second-brain` (chain: `SB_BRAIN_DIR` → `BRAIN_DIR` → homedir) | Root of brain state (transcripts, raw, config.json, audit log). TS: `mcp/src/brain-paths.ts:30` (CRLF-stripped via `cleanEnvPath`). Shell: `scripts/cost-router-capture.sh:22` etc. | PATH | brain-paths.ts:27-33 | bash+vitest |
| `SB_KNOWLEDGE_DIR` | `~/knowledge` | Wiki-root override in the cost-router capture path ONLY (chain there: `SB_KNOWLEDGE_DIR` → `KNOWLEDGE_DIR` → `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` → `$HOME/knowledge`). The main chain elsewhere starts at `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` (SKILL.md §2). | PATH | cost-router-capture.sh:26 | bash |
| `SB_ACTIVE_SLUG` | (unset) | Cross-process handoff of the resolved active-project slug into node CLI shims so per-process slug resolution can't misroute. Set: `persona-context.sh:205,215,219`, `session-load.sh:575`. Read: `knowledge-search-cli.ts:18`, `raw-capture-cli.ts:12`, `raw-scan-cli.ts:12,23`, `context-serve-cli.ts:25`, `episodic-search-cli.ts:11`. | INT (settable) | persona-context.sh:205 | bash+vitest |
| `SB_ACTIVE_SLUG_VAL` | `$(sb_resolve_slug)` | Shell-local holder of the resolved slug pre-export. | INT | persona-context.sh:190 | none |
| `SB_NESTED_SPAWN` | `0` | Set to `1` by every plugin-spawned headless `claude` so hook entrypoints no-op inside nested spawns — 13 scripts under `scripts/` carry the `[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0` early exit (e.g. `ensure-dirs.sh:3`). The 3 SETTERS (lib.sh, maintain-llm-drain.sh, extraction-quality-gate.sh) export `SB_NESTED_SPAWN=1` into spawns and do NOT no-op; a grep of all mentions counts 17 files (13 readers + 3 setters + a comment-only hit in hook-timer.sh:16) — don't audit guard coverage against 17. TS guard: `mcp/src/nested-spawn-guard.ts:16` (`=== '1'`). | INT/guard | nested-spawn-guard.ts:16 | bash+vitest |
| `SB_VECTOR_DEPS_DIR` | `$HOME/.second-brain/vector-deps` | Shared embeddings node_modules location (junction-linked per plugin version; `ln -s` deep-copies on MSYS — fixed 0.33.7). | PATH | bin/install-vector-deps.sh:34 | bash |
| `SB_KB_SCHEMA` | `<plugin>/kb-schema.json` (computed relative to kb-schema.sh) | Path override for the KB schema JSON. | PATH/TESTDBL | scripts/kb-schema.sh:7 | bash |
| `SB_DIR` | `${BRAIN_DIR:-$HOME/.second-brain}` | Local var inside the timer installer. | INT | scripts/install-extract-timer.sh | none |

**kb-schema-derived exports** — all set by `scripts/kb-schema.sh:9-21` from `kb-schema.json`
(env-first overridable, sourced via lib.sh, guarded by `tests/test-kb-schema.sh`; fail-soft: if jq
or the manifest is absent the vars stay UNSET, no hardcoded fallback):
`SB_STRUCTURED_TYPES` (learnings decisions entities issues concepts security),
`SB_UNSTRUCTURED_TYPES` (state sources), `SB_GENERATED_DIRS` (projects themes),
`SB_CONTENT_CATEGORIES` (structured+unstructured; also defaulted inline at `ensure-dirs.sh:15`),
`SB_ALL_CATEGORIES` (union), `SB_EDGE_TYPES` (requires affects relates part_of supersedes),
`SB_FORGET_PROTECTED` / `SB_FORGET_DISCOUNTED` (shell fallbacks `wiki-forget-score.sh:22-23`),
`SB_RAW_DIR` (`raw`), `SB_RAW_STATUSES` (unprocessed processed discarded).

## 2. Hook guards & nudges (hooks.json-wired)

Every var below is read by a hooks.json-wired script. The converse does NOT hold: the wired
PostToolUse `quality-gate.sh` (Write|Edit self-review nudge) reads NO flag at all — it is a 3-line
unconditional `echo`. `SB_QUALITY_GATE` gates the pipeline-invoked `extraction-quality-gate.sh`
(§4), not it.

| Var | Default | Effect | Kind | Site | Tests |
|---|---|---|---|---|---|
| `SB_PERSONA_GATE` | `on` | MASTER gate: persona context injection + persona tool guard + wiki write guard all exit early when `off`. | KS | persona-context.sh:18; persona-tool-guard.sh:15; wiki-write-guard.sh:12 | bash |
| `SB_TOOL_SCOPE` | `on` | PreToolUse tool-allowlist "ask" guard. Only active when `tool_scope.enabled=true` in persona-rules.json — the SHIPPED default is `false`, so this guard is INERT out of the box (SKILL.md §4). | KS | persona-tool-guard.sh:70 | bash |
| `SB_TOOL_SCOPE_EXTRA` | empty | Colon-separated extra allowed tools (session-scoped). | TUNE | persona-tool-guard.sh:79 | bash |
| `SB_RESOURCE_SCOPE` | `on` | PreToolUse path-allowlist "ask" guard for Edit/Write/MultiEdit/Read. `resource_scope.enabled=true` IS the shipped default — LIVE out of the box (SKILL.md §4). | KS | persona-tool-guard.sh:102 | bash |
| `SB_RESOURCE_SCOPE_EXTRA` | empty | Colon-separated extra allowed path prefixes. | TUNE | persona-tool-guard.sh:133 | bash |
| `SB_SYMLINK_GUARD` | `on` | Denies writes whose symlink-resolved path lands in `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/claude`, `~/.config/gh`, `~/.password-store`, `/etc`, `~/.netrc`. | KS | symlink-guard.sh:32 | bash |
| `SB_FLOW_GUARD` | `on` | "Ask" when an egress tool call (Bash w/ network tool, WebFetch/WebSearch) carries credential-shaped content. | KS | flow-guard.sh:29 | bash |
| `SB_INJECTION_SCAN` | `on` | PostToolUse scan of Read/WebFetch/Bash/Grep/Glob output for prompt-injection patterns; flags via additionalContext, never blocks. | KS | tool-return-scanner.sh:20 | bash |
| `SB_CONFIG_CHANGE_AUDIT` | `on` | Records every ConfigChange event to audit-log.jsonl (audit-only). | KS | config-change-guard.sh:26 | bash |
| `SB_SIMPLICITY_GATE` | `on` | PostToolUse advisory nudge on a single large Write/Edit. | KS | simplicity-gate.sh:7 | bash |
| `SB_SIMPLICITY_GATE_LINES` | `150` | Line threshold for the simplicity nudge. | TUNE | simplicity-gate.sh:11 | bash |
| `SB_PLAN_FIRST_NUDGE` | `on` | P5 (0.33.30): soft once-per-session PreToolUse advisory when the session makes substantive edits to its Nth distinct code file. additionalContext + allow — never blocks. | KS | plan-first-nudge.sh:16 | bash |
| `SB_PLAN_FIRST_FILES` | `2` | Distinct-code-file count that triggers the plan nudge. | TUNE | plan-first-nudge.sh:45 | bash |
| `SB_PLAN_FIRST_MIN_LINES` | `3` | Edits below this line count never count a file toward the threshold. | TUNE | plan-first-nudge.sh:42 | none |
| `SB_VERIFY_GATE` | `on` | Stop-hook verification gate. | KS | stop-verify-gate.sh:13 | bash |
| `SB_HOOK_PROFILE` | unset | `minimal` collapses the hook surface to essentials in one lever: defaults SAR banner, plan-first nudge, dream autostage, critic offer, loop-dead banner, codemap orient, injection scan, and config-change audit to off (individually-set values always win). Guards, extraction, and session-load stay on. | profile | lib.sh (profile block) | bash |
| `SB_SAR_SUMMARY` | `on` | Stop-hook Safety-Adherence-Rate one-line banner from audit-log verdicts. | KS | sar-summary.sh:22 | bash |
| `SB_SUBAGENT_CAPTURE` | `on` | SubagentStop: archive substantive, non-self subagent FINAL results into `~/.second-brain/transcripts/`. | KS | subagent-capture.sh:22 | bash |
| `SB_SUBAGENT_MIN_RESULT` | `80` | Min result size (bytes) to count as substantive. | TUNE | subagent-capture.sh:56 | none |
| `SB_SUBAGENT_ARCHIVE_CAP` | `50` | Max `sub-*.txt` archives kept (pruned oldest-first). | TUNE | lib.sh:840 | bash |
| `SB_PRINCIPLES_INJECT` | `on` | Persona principles block in the UserPromptSubmit ambient context. | KS | persona-context.sh:249 | bash |

## 3. SessionStart banners & auto-dispatch (session-load.sh and friends)

| Var | Default | Effect | Kind | Site | Tests |
|---|---|---|---|---|---|
| `SB_AUTH_LINE` | `on` | Auth-mode banner (api-key vs OAuth vs none). | KS | session-load.sh:335 | bash |
| `SB_CAPTURE_HEALTH_BANNER` | `on` | Banner when extraction is failing/queued (offers api-key / drainer / local remedies). | KS | session-load.sh:354 | bash |
| `SB_DRAIN_HEALTH_BANNER` | `on` | Drainer-health banner. | KS | session-load.sh:295 | bash |
| `SB_DRAIN_DEADLETTER_THRESHOLD` | `5` | Error-marked transcripts before the dead-letter banner. | TUNE | session-load.sh:297 | none |
| `SB_DRAIN_TIMEOUT_BANNER_THRESHOLD` | `3` | Timeout outcomes before the timeout banner. | TUNE | session-load.sh:296 | none |
| `SB_EMBED_PENDING_BANNER` | `on` | Banner when embeddings backlog or `@huggingface/transformers` unlinked. | KS | session-load.sh:443 | bash |
| `SB_SCOPE_BANNER` | `on` | One-line "which project scope loaded" banner (catches wrong cwd→slug resolution). | KS | session-load.sh:525 | bash |
| `SB_CODEMAP_ORIENT` | `on` | Code-map orientation: inject the architectural spine (top-ranked source files from `codemap/map.md`) + code_map/code_neighbors pointer at SessionStart. No-op when the store is absent/empty. | KS | session-load.sh:479 | bash |
| `SB_VERIFY_ANTIGAME` | `on` | Anti-gaming slice of the Stop verify gate: verification evidence co-occurring with an rm/git-rm of a test-shaped path → one pointed block via the existing 2-block valve. TDD test edits never flagged. | KS | stop-verify-gate.sh:87 | bash |
| `SB_LOOP_DEAD_BANNER` | `on` | Loop-dead banner: scheduler registered but the drainer stamped nothing in `SB_LOOP_DEAD_HOURS` → one banner (the installed-but-never-ticks case the timeout/dead-letter banners can't see). | KS | session-load.sh (0a-quinquies) | bash |
| `SB_LOOP_DEAD_HOURS` | `48` | Hours without a drainer stamp before the loop-dead banner fires. | TUNE | session-load.sh (0a-quinquies) | bash |
| `SB_TELEMETRY` | `on` | P1 loop telemetry master switch: session-load injection manifest + stop-extract value/compound correlation + utilization counts. Observation-only (firewall-locked from ranking). | KS | session-load.sh (sb_manifest_add) + stop-extract.sh | bash |
| `SB_CRITIC_OFFER` | `on` | P2.2: on a substantive VERIFIED diff, one non-blocking systemMessage per session offering the quality-reviewer/persona_think fresh-context critique. | KS | stop-verify-gate.sh | bash |
| `SB_CRITIC_OFFER_MIN_FILES` | `3` | Distinct changed source files before the critic offer fires. | TUNE | stop-verify-gate.sh | bash |
| `SB_RULES_GAP_BANNER` | `on` | Banner when USER.md is newer than persona-rules JSON (soft-vs-hard rules drift). | KS | session-load.sh:215 | none |
| `SB_RAW_INBOX` | `on` | Raw-inbox backlog banner. | KS | session-load.sh:584 | bash |
| `SB_AUTOCONSOLIDATE_NUDGE` | `on` | Self-install nudge when raw ≥ threshold AND config `auto_improve` is off. | KS | session-load.sh:599 | bash |
| `SB_NUDGE_RAW_THRESHOLD` | `20` | Raw-item count for that nudge. | TUNE | session-load.sh:598 | bash |
| `SB_DISABLE_AUTO_TIMER` | `0` | `1` disables the SessionStart self-heal install of the drainer timer. | KS | session-load.sh:390 | bash |
| `SB_MAINTAINER_AUTO` | `on` | Auto-dispatch of knowledge-maintainer after N wiki writes. | KS | session-load.sh:151 | bash |
| `SB_MAINTAINER_THRESHOLD` | `3` | Wiki writes since last consolidation before dispatch. | TUNE | session-load.sh:150 | bash |
| `SB_MAINTAINER_MAX_FAILS` | `3` | Consecutive maintainer failures before auto-disable (`.maintainer-auto-disabled` marker). | TUNE | session-load.sh:158 | bash |
| `SB_DREAM_AUTOSTAGE` | `on` | dream-autostage banner logic (suggests `/second-brain:dream`, reclaims stale pendings, banners quarantine). `off` re-enables the legacy session-count nag. | KS | dream-autostage.sh:23; session-load.sh:145 | bash |
| `SB_DREAM_NEW_THRESHOLD` | `10` | New transcripts since last terminal dream before the suggest-banner. | TUNE | dream-autostage.sh:25 | bash |
| `SB_DREAM_CADENCE` | `15` | Legacy session-count threshold (only when autostage off). | TUNE | session-load.sh:141 | none |
| `SB_DREAM_STALE_DAYS` | `7` | Banner when the last dream is older than N days. | TUNE | session-load.sh:649 | none |
| `SB_PERSONA_SIGNAL_WINDOW_DAYS` | `30` | Signal window for persona stats in session context. | TUNE | session-load.sh:482 | none |

## 4. Extractor / drainer pipeline

| Var | Default | Effect | Kind | Site | Tests |
|---|---|---|---|---|---|
| `SB_EXTRACTOR_ENGINE` | `auto` | Backend pin: `auto` (local→cli→api fallback), `local` (pin, no fallback), `cli`, `bare`. | MODE | lib.sh:1267 | bash |
| `SB_EXTRACTOR_LOCAL_URL` | empty | OpenAI-compatible `/v1` endpoint (e.g. ollama). When set (and engine not `cli`/`bare`) the local backend is tried FIRST — no recursive-claude lock, no Anthropic creds, works in-session and offline (lib.sh:1263-1276). | PATH | lib.sh:1268 | bash |
| `SB_EXTRACTOR_LOCAL_MODEL` | `qwen2.5:3b` | Local model name. | TUNE | lib.sh:1273 | none |
| `SB_EXTRACTOR_LOCAL_TIMEOUT` | `90` (s) | Local-backend timeout before auto-fallback. | TUNE | lib.sh:1274 | none |
| `SB_EXTRACTOR_LOCAL_MAX_BYTES` | `6000` | Input cap for local extraction. | TUNE | lib.sh:1207 | bash |
| `SB_EXTRACTOR_MODEL` | `claude-sonnet-4-6` | Remote extractor model. | TUNE | lib.sh:1610 | none |
| `SB_EXTRACT_TIMEOUT` | `25` (stop-extract.sh:42) / `30` (pre-compact.sh:32) s | IN-HOOK extraction timeouts (inside 45s hook budgets). Deliberately NOT shared with the drainer (next row). | TUNE | stop-extract.sh:42 | none |
| `SB_DRAIN_EXTRACT_TIMEOUT` | `240` (s) | Drainer per-attempt extraction budget. BUDGET PROOF (comment lib.sh:1612-1625): worst case 5 (BATCH) × 3 (retry paths) × 240 = 3600s = HALF of the 7200s lock steal-threshold — "do NOT raise further without also raising SB_DRAIN_LOCK_STALE". | TUNE | lib.sh:1625 | bash |
| `SB_EXTRACT_MAX_BYTES` | `200000` | Transcript tail cap fed to the extractor. | TUNE | lib.sh:1669 | bash |
| `SB_QUALITY_GATE` | `on` | Extraction quality filter `extraction-quality-gate.sh` (passthrough `cat` when off). Invoked from the extraction pipeline (lib.sh:165, lib.sh:1679, stop-extract.sh:221) — NOT hooks.json-wired, and NOT the PostToolUse `quality-gate.sh` nudge, which has no switch (§2 note). | KS | extraction-quality-gate.sh:18 | bash |
| `SB_QUALITY_GATE_STRICTNESS` | `conservative` | Strictness mode of the extraction quality filter. | MODE | extraction-quality-gate.sh:25 | bash |
| `SB_QUALITY_GATE_LLM` | `off` | OPT-IN LLM (haiku) second-pass on the quality filter, spawned with `SB_NESTED_SPAWN=1`. | KS(opt-in) | extraction-quality-gate.sh:26 | none |
| `SB_QUALITY_GATE_MODEL` | `claude-haiku-4-5-20251001` | Model for the LLM quality pass. | TUNE | extraction-quality-gate.sh:27 | none |
| `SB_FORCE_CLI` | `0` | Escape hatch: force the legacy `claude -p` path even in-session ("debugging only", lib.sh:1293). | DEBUG | lib.sh:1295 | none |
| `SB_USE_BARE` | `0` | Use `claude -p --bare`. | MODE | extraction-quality-gate.sh:90 | none |
| `SB_USE_BWRAP` | `0` | Wrap the spawn in bubblewrap. | MODE | lib.sh:1323 | none |
| `SB_PTY_RETRY` | `on` | Retry empty CLI output under a pty (`script -qfc`). | KS | lib.sh:1386 | none |
| `SB_DRAIN_BATCH` | `5` | Transcripts per drain cycle. | TUNE | extract-drain.sh:190 | bash |
| `SB_DRAIN_MAX_FAILS` | `3` | Failures before a transcript is terminally marked `error` (or floored). | TUNE | extract-drain.sh:192 | bash |
| `SB_DRAIN_FLOOR` | `on` | P1 deterministic floor: after MAX_FAILS, write the files-changed baseline (no LLM) and mark processed instead of losing the session. | KS | extract-drain.sh:279 | none |
| `SB_DRAIN_MIN_BYTES` | `1024` | Skip transcripts smaller than this. | TUNE | extract-drain.sh:244 | bash |
| `SB_DRAIN_LOCK_STALE` | `7200` (s) | Steal a drain lock older than this. | TUNE | extract-drain.sh:211 | bash |
| `SB_DRAIN_FORCE_MKDIR_LOCK` | `0` | Force mkdir-based locking (portability/test). | TESTDBL | extract-drain.sh:202 | bash |
| `SB_DRAIN_DEFER_MAX` | `6` | Consecutive defers (live interactive session present) before ONE drain escapes. | TUNE | extract-drain.sh:138 | bash |
| `SB_DRAIN_STALE_MAX` | `86400` (s) | Oldest-pending age that triggers an age-based escape. | TUNE | extract-drain.sh:139 | bash |
| `SB_DRAIN_ESCAPE_COOLDOWN` | `= SB_DRAIN_STALE_MAX` | Rate limit between age-driven escapes. | TUNE | extract-drain.sh:147 | none |
| `SB_DRAIN_DEFER_PMODE_ONLY` | `0` | `1`: only defer when a `claude -p` (print-mode) process is present, not any interactive session. | MODE | extract-drain.sh:128 | bash |
| `SB_INTERACTIVE_OVERRIDE` | empty | Force the defer decision: `active` = always defer, `inactive` = never (bypasses pgrep/ps detection). | TESTDBL | extract-drain.sh:33 | bash |
| `SB_EXTRACT_STUB` | empty | Test stub replacing the real extractor. | TESTDBL | extract-drain.sh:230 | bash |
| `SB_MAINTAIN_INTERVAL` | `3600` (s) | Min interval between deterministic maintenance runs. | TUNE | maintain-deterministic.sh:17 | none |
| `SB_MAINTAIN_FORCE` | `0` | Bypass the deterministic-maintenance interval. | DEBUG | maintain-deterministic.sh:18 | bash |
| `SB_MAINTAIN_LLM_FORCE` | `0` | Bypass interval/quarantine guards on the headless LLM maintainer. | DEBUG | maintain-llm-drain.sh:30 | bash |
| `SB_MAINTAIN_LLM_INTERVAL` | `604800` (s = 7d) | Headless-maintainer cadence. | TUNE | maintain-llm-drain.sh:58 | none |
| `SB_MAINTAIN_LLM_RETRY` | `86400` (s) | Retry interval after a failed run. | TUNE | maintain-llm-drain.sh:44 | none |
| `SB_MAINTAIN_LLM_MODEL` | `claude-sonnet-4-6` | Maintainer model. | TUNE | maintain-llm-drain.sh:119 | none |
| `SB_MAINTAIN_LLM_TIMEOUT` | `1800` (s) | Maintainer run timeout. | TUNE | maintain-llm-drain.sh:120 | bash |
| `SB_MAINTAIN_LLM_DRYRUN` | `0` | Dry-run (no spawn). | TESTDBL | maintain-llm-drain.sh:140 | bash |
| `SB_RAW_PRUNE_AFTER_DRAIN` | unset (off) | Truthy (`1/true/yes/on`) = drainer deletes processed+discarded raw items after each batch. ADVISORY — the case statement lives in agent prompt text `agents/raw-drainer.md:~182`. | KS(opt-in), ADVISORY | raw-drainer.md | bash |

## 5. Dream lifecycle

| Var | Default | Effect | Kind | Site | Tests |
|---|---|---|---|---|---|
| `SB_DREAM_RUN_TIMEOUT` | `21600` (s = 6h) | A pending/running dream whose status file is older than this is judged dead/reclaimable. | TUNE | lib.sh:1113 | bash |
| `SB_DREAM_KEEP_COUNT` | `5` (via config.json `.retention.dream_keep_count`) | Dream snapshots retained. The ONLY env-over-config layered knob (SKILL.md §1). | TUNE | dream-snapshot.sh:77 | none |
| `SB_DREAM_ACCEPT_MIN_RATIO` | `50` (%) | dream-accept refuses when staging wiki < N% of live page count; empty staging + non-empty live = hard error ("a broken dream must not --delete the live wiki"). `0` disables (not advised). | guard | dream-accept.sh:104 | bash |
| `SB_DREAM_ACCEPT_NO_DELETE` | `0` | `1` (set by `auto_accept=safe`, comment dream-accept.sh:117) refuses accepts that remove live pages. | guard | dream-accept.sh:121 | bash |
| `SB_DREAM_ACCEPT_SKIP_BACKUP` | `0` | Skip the pre-accept backup. | DEBUG | dream-accept.sh:140 | bash |
| `SB_DREAM_SUMMARIZE` | `on` | Dream SUMMARIZE op (theme MOCs from graph clusters); `off` → graph-cluster.sh emits `[]` (byte-identical fail-safe skip). | KS | graph-cluster.sh:25 | bash |
| `SB_DREAM_REFLECT` | `on` | 0.33.28 reflection op (grounded cross-cutting practices from clusters); gates independently of SUMMARIZE. | KS | graph-cluster.sh:24 | bash |
| `SB_SUMMARIZE_MIN_CLUSTER` | `4` | Min cluster size to summarize. | TUNE | graph-cluster-cli.ts:59 | bash |
| `SB_SUMMARIZE_MAX_PAGES` | `8` | Max theme pages per run. | TUNE | graph-cluster-cli.ts:81 | bash |
| `SB_WIKI_FORGET` | `on` | Dream FORGET phase (reversible archive of low-value pages to `~/.second-brain/wiki-archive/`, applied only on accept). ADVISORY — the gate lives in skill/agent markdown (`skills/dream/SKILL.md:187`, `agents/dream-runner.md:189`); candidate scripts + wiring are code. | KS, ADVISORY | dream-runner.md:189 | bash |
| `SB_DREAM_AI_BLOCKS` | `on` | Dream ai-block count step — explicitly "advisory, not machine-enforced" in both files (dream-runner.md:110; dream/SKILL.md:109). | KS, ADVISORY | dream-runner.md:110 | bash (parity test) |
| `SB_FORGET_FLOOR` | `0.15` | Score floor for FORGET candidates. | TUNE | wiki-forget-candidates.sh:9 | bash |
| `SB_FORGET_MAX_PER_DREAM` | `5` | Max pages archived per dream. | TUNE | wiki-forget-candidates.sh:9 | none |
| `SB_FORGET_PROBE_MIN_SCORE` | `0.1` | Recall-probe min score guard. | TUNE | wiki-forget-candidates.sh:10 | none |
| `SB_FORGET_REDUNDANCY_THRESHOLD` | `0.8` | 0.33.27: MinHash redundancy cross-check gates archiving (prevents false-forgets). | TUNE | wiki-forget-candidates.sh:35 | none |
| `SB_FORGET_MIN_AGE_DAYS` | `30` | Pages younger than this are never FORGET-scored. | TUNE | wiki-forget-score.sh:26 | none |
| `SB_FORGET_W_CONNECTIVITY` | `0.25` | Importance weight (connectivity). v4 scoring = connectivity + category ONLY — access & recency terms dropped (comment wiki-forget-score.sh:27-32); access counts survive as `acc=` telemetry only (0.33.30 P4b). | TUNE | wiki-forget-score.sh:33 | none |
| `SB_FORGET_W_CATEGORY` | `0.20` | Importance weight (category; PROTECT list forces 1.0, discounted 0.5). | TUNE | wiki-forget-score.sh:33 | none |
| `SB_REDUNDANCY` | `on` | MinHash near-dup redundancy engine (0.33.26). | KS | wiki-redundancy.sh:22; wiki-forget-candidates.sh:37 | bash |
| `SB_REDUNDANCY_THRESHOLD` | `0.7` (clamped 0.01–1 via `envFloat`) | Near-dup similarity threshold. | TUNE | wiki-redundancy-cli.ts:42 | none |
| `SB_REDUNDANCY_MAX_PAIRS` | `50` (NaN→50; explicit small values honoured, min 1) | Max reported pairs. | TUNE | wiki-redundancy-cli.ts:43-44 | none |
| `SB_CONFLICT_DETECT` | `on` | Edge-merge conflict detection. | KS | merge-edges.sh:93 | bash |
| `SB_CONFLICT_MULTIPARENT` | `off` | OPT-IN: treat multi-parent `part_of` as a conflict. | KS(opt-in) | merge-edges.sh:68 | bash |

## 6. Search / retrieval / MCP server

TS reads use `process.env.SB_*` directly OR the helpers `clampEnvInt(...)`/`envFloat(...)` — a
grep for `process.env.SB_` alone MISSES the helper-mediated ones (grep for the bare name instead).

| Var | Default | Effect | Kind | Site | Tests |
|---|---|---|---|---|---|
| `SB_PROJECT_SCOPE` | on (`!== 'off'`) | Project-scoped tiering of knowledge_search results (skipped when `scope==='all'`). | KS | knowledge-search.ts:323 | bash+vitest |
| `SB_SCOPE_HOPS` | `2` (clamped 0–4) | Graph-neighbourhood hops for scoping anchors. | TUNE | knowledge-search.ts:337 | none |
| `SB_SCOPE_MIN_HITS` | `3` (clamped 0–100) | Min in-scope hits passing the floor before hard-scoping applies; else fall back to unscoped. | TUNE | knowledge-search.ts:365 | vitest |
| `SB_GRAPH_RANKING_BOOST` | off (`'1'`/`'true'` enables) | DEMOTED off-by-default (P7, 2026-06-28) — measured net-zero on the real corpus (6 improved / 6 degraded / 80 unchanged of 92) while displacing exact title-matches (comment knowledge-search.ts:194-197). Project-scoping neighbourhood + bi-temporal supersedes unaffected. | KS(opt-in), EXPERIMENTAL | knowledge-search.ts:198 | vitest |
| `SB_EPISODIC_SCOPE_MIN_HITS` | `1` (≥1) | Min in-scope episodic hits before hard-dropping other-project results; below it, broaden to all. | TUNE | episodic-search.ts:502 | none (env branch) |
| `SB_EGRESS_BUDGET_TOKENS` | constant in egress-budget.ts (env accepted when parseInt > 0) | Token cap on knowledge_fetch full-page egress. | TUNE | egress-budget.ts:21 | none (env branch) |
| `SB_MOC_MIN_MEMBERS` | `3` (NaN/0/negative → 3) | Min members for a project MOC page at reindex. | TUNE | knowledge-reindex.ts:64 | vitest |
| `SB_KB_MOC` | on (`'off'` disables) | Project-MOC generation at reindex (off → stale MOCs pruned). | KS | knowledge-reindex.ts:66 | none |
| `SB_AI_BLOCK_MIN_PROSE` | `200` | Min prose bytes before a page is flagged blockless. | TUNE | knowledge-validate.ts:16; kb-ai-block-candidates.sh:9 | none |
| `SB_SCAN_MAX` | `50` (≥0 honoured, incl. 0) | Max items captured per raw-scan. | TUNE | raw-scan.ts:40 | vitest |
| `SB_SCAN_SKIP` | `0` | `1` skips the setup skill's repo doc scan. ADVISORY (skill markdown only). | KS, ADVISORY | skills/setup/SKILL.md:261 | none |
| `SB_CAPTURE_DEDUP` | `on` | 0.33.29 write-path NOOP/UPDATE: a MinHash near-dup of an existing UNPROCESSED inbox item is collapsed (keep longer body). Scoped to the inbox, never the wiki. | KS | raw-inbox.ts:295 | vitest |
| `SB_CAPTURE_DEDUP_THRESHOLD` | `0.9` (0<t≤1) | Similarity threshold for capture dedup. | TUNE | raw-inbox.ts:296 | none |
| `SB_AUTH_PROBE_TIMEOUT_MS` | `3000` (clamped 100–30000) | `claude auth status` probe timeout (SIGKILL delivery). | TUNE | cli/sb.ts:83 | none |

## 7. Persona subsystem

| Var | Default | Effect | Kind | Site | Tests |
|---|---|---|---|---|---|
| `SB_PERSONA_DISMISS_MAX` | `3` | Dismissals in the window → ambient injection self-suppresses (explicit briefs unaffected). | TUNE | persona-context.sh:150 | bash |
| `SB_PERSONA_DISMISS_WINDOW_DAYS` | `7` | Trailing dismissal window. | TUNE | persona-context.sh:151 | none |
| `SB_PERSONA_WIKI_MIN_SCORE` | `0.045` | Min search score for wiki snippets in ambient context. | TUNE | persona-context.sh:182 | none |
| `SB_PERSONA_MODEL` | `claude-opus-4-7` | persona_think brief model. | TUNE | persona-think.ts:110 | none |
| `SB_PERSONA_COST_PER_CALL` | — | REMOVED — spend is not tracked anywhere; the persona ledger and all cost logging were deleted. | removed | none | none |
| `SB_PERSONA_TIMEOUT_MS` | `30000` | persona_think spawn timeout. | TUNE | persona-think.ts:112 | none |
| `SB_PERSONA_DAILY_BUDGET` | — | DEPRECATED: "no longer gate anything" — `skills/upgrade/migrations/0.24.45.md:11,22`. Zero live consumers in scripts/ or mcp/src (verified by grep 2026-07-05). | DEPRECATED | migrations/0.24.45.md:11 | — |

## 8. Eval / project-merge / misc

| Var | Default | Effect | Kind | Site | Tests |
|---|---|---|---|---|---|
| `SB_EVAL_MIN_RECALL` | `0.8` | recall@2 gate in wiki-recall-check (release gate test-knowledge-eval.sh). | TUNE | wiki-recall-check.sh:81 | bash |
| `SB_EVAL_MAX_TOKENS` | `8000` | Token-budget gate in the same. | TUNE | wiki-recall-check.sh:81 | none |
| `SB_EVAL_TITLE_SAMPLE` | `0` (= all) | Sample cap for live-title recall probes. | TUNE | wiki-recall-check.sh:38 | bash |
| `SB_SKIP_SUPERSEDE` | `0` | `1` disables decision-supersede detection in project merge. | KS | merge-project-update.sh:247 | none |
| `SB_PROJECT_STALE_DAYS` | `30` | Age at which decisions/blockers are marked `[stale]`. | TUNE | merge-project-update.sh:376 | none |
| `SB_INSTALL_OS_OVERRIDE` | empty | Force the OS branch in the timer installer (linux/mac/windows). | TESTDBL | install-extract-timer.sh:139 | bash |
| `SB_LIVENESS_MARKETPLACE` | `$PLUGIN_ROOT/.claude-plugin/marketplace.json` | Liveness-check input override. | TESTDBL/PATH | liveness-check.sh:17 | bash |
| `SB_LIVENESS_INSTALLED` | `$HOME/.claude/plugins/installed_plugins.json` | Ditto. | TESTDBL/PATH | liveness-check.sh:18 | bash |
| `SB_RECONCILE` / `SB_RECONCILE_TOPK` / `SB_RECONCILE_MAX` | on / `5` / `20` | Maintainer retrieval-grounded reconciliation (Mem0-style dedup grounding). ADVISORY — agent prompt text only: `agents/knowledge-maintainer.md:74,79,88`. | KS+TUNE, ADVISORY | knowledge-maintainer.md:74-88 | none |
| `SB_FORGET_RECENCY_DAYS` | — | DEPRECATED — v4 forget scoring dropped the recency term (wiki-forget-score.sh:27-32 comment; `skills/upgrade/migrations/0.24.47.md:19`). Zero live consumers (verified by grep 2026-07-05). | DEPRECATED | migrations/0.24.47.md:19 | — |

## 9. Internal variables (set by the plugin — NOT user axes; do not document as flags)

`SB_INPUT`, `SB_SESSION_ID`, `SB_TRANSCRIPT_PATH`, `SB_TIMESTAMP` — populated by the stdin-parse
helper in lib.sh. `SB_AUDIT_FILE` (= `$BRAIN_DIR/audit-log.jsonl`, lib.sh:247) with rotation
constants `SB_AUDIT_MAX_LINES=5000` / `SB_AUDIT_MAX_BYTES=5242880` (lib.sh:248-249 — hard-coded
assignments, NOT env-overridable). `SB_HEALTH_FILE` (= `$BRAIN_DIR/.extractor-health.json`,
lib.sh:1128). `SB_EPI_INDEX` (episodic index path, session-load.sh). `SB_GATE` (gate-reason
accumulator, pre-compact.sh / stop-extract.sh). `SB_SKIP_CLI` (local, lib.sh:1294). `SB_JQ_OK`
(per-process jq-availability cache, lib.sh:1554). `SB_SCRIPT_NAME` (lib.sh:1247). `SB_BUNDLE` /
`SB_KDIR` (env-passing into `node -e` reindex/validate shims). `_SB_CTX_SEP` (output separator
sentinel, persona-context.sh). `SB_REVIEW_SKILL` (shell-local flag inside
`cost-router/scripts/classify-prompt.sh:108-113`). `SB_FOO` at lib.sh:1709 is a DOCUMENTATION
EXAMPLE in the precedence comment, not a real flag.

## 10. Test-infrastructure vars (defined and consumed only under tests/)

Verified test-only by set-diff on 2026-07-05 (17 names): `SB_RUN_ALL_TESTS_DIR` (run-all.sh:21,
overrides the shell-test dir), `SB_RUN_ALL_QUIET` (default 0), `SB_RUN_ALL_VITEST` (default 1;
`0` skips the vitest lane), `SB_RUN_ALL_TIMEOUT` (default 120s/test), `SB_SUITE_REAL_HOME_PATH`
(the real HOME handed into the HOME-sandboxed suite), `SB_RELEASE_BASE_REF` (base ref for the
version-bump tripwire; falls back to `origin/main`, else SKIP), `SB_SCHTASKS_STATE` (fake Windows
scheduled-task marker), `SB_THINK_SENTINEL_42` (CLI-shim invocation sentinel), and stub doubles
`SB_TEST_PROBE_RC`, `SB_TEST_RUN_RC`, `SB_TEST_RUN_STDERR`, `SB_TEST_RELINK_RC`,
`SB_TEST_WINHOME`, `SB_TEST_RUN_NOADVANCE`, `SB_TEST_RUN_SENTINEL`, `SB_TEST_RUN_TRUNCATE_STATUS`,
`SB_TEST_RUN_DELETE_STATUS`. See sb-validation-and-qa for the runner mechanics.

## Coverage summary (as of 0.33.31, 2026-07-05)

- Bash-test-referenced: 92 vars (includes every hook kill switch in §2).
- Vitest-referenced: 9 — `SB_ACTIVE_SLUG SB_BRAIN_DIR SB_CAPTURE_DEDUP SB_GRAPH_RANKING_BOOST
  SB_MOC_MIN_MEMBERS SB_NESTED_SPAWN SB_PROJECT_SCOPE SB_SCAN_MAX SB_SCOPE_MIN_HITS`.
- Referenced in NO test (notable real knobs; internals/deprecated excluded): the "none" rows above
  — concentrated in per-model/timeout tuning (`SB_EXTRACTOR_MODEL`, `SB_EXTRACT_TIMEOUT`,
  `SB_MAINTAIN_LLM_{INTERVAL,RETRY,MODEL}`), FORGET weights/thresholds, persona tuning, and the
  env-override branches of TS knobs. House rule: where the default path IS tested, the
  env-override branch typically is not — adding that branch test is a standing improvement.

Re-verification commands live in SKILL.md §10. Regenerate this file's raw inputs with the
"master census" and "shell defaults" greps there, then diff against these tables.
