# Deep audit — second-brain 0.48.0 (HEAD 1d9d70a), 2026-09-04/05

Method: 15 subsystem readers (full-file reads, claim checks, repro commands) → dedup (244 → 221) → adversarial verification
(critical/high: reproducer + skeptic, both reproduced by running under a throwaway HOME; medium/low: one skeptic) → 10-sample
spot-check (10/10 held) → completeness critic. Gates at the same HEAD on Windows: tsc 0 · vitest 780/9 skip · bundle-current ·
run-all 159/0/3 · validate OK. Live measurement: capture working; injection→read 2/117; audit-log torn (4 lines); SAR silent since 08-23.

Line numbers are the readers' citations and drift; verify behaviour, not anchors. Status legend: open · fixed(<commit>) · wontfix(<why>) · known.


## critical (2)

| id | title | where | status |
|---|---|---|---|
| D057 | knowledge_search `scope` is unvalidated (knowledge-search.ts:184): traversal yields arbitrary-file read — path enumeration plus the first 200 chars of any .md outside the wiki, bypassing the default-on resource_scope Read guard | `mcp/src/tools/knowledge-search.ts:184` | fixed |
| D120 | Concurrent native-jq `>>` appends silently lose and tear audit-log.jsonl rows (scripts/lib.sh:470); every whole-file jq reader then aborts at the first fragment, hiding 98% of guard verdicts — Windows/git-bash | `scripts/lib.sh:469` | open |

## high (23)

| id | title | where | status |
|---|---|---|---|
| D017 | Hybrid RRF/embeddings path never executes in CI (ci.yml:42-44 pins embeddings off; 3 real-model vitest blocks skip) — covered only by the local pre-push run and an arithmetic ceiling lock | `.github/workflows/ci.yml:197` | open |
| D025 | persona-tool-guard's ask/deny is emitted only at script end and 14/2267 live Windows runs exceeded the 5 s hooks.json timeout — nothing in-plugin enforces or detects the overrun | `hooks/hooks.json:88` | open |
| D037 | Absolute in-repo imports (Python PEP8 style, TS path aliases) are classified external → zero-edge graph, uniform PageRank injected as "highest-connectivity spine" and code_neighbors reports 0 importers, with no degeneracy signal | `mcp/src/tools/codemap/extract.ts:474` | fixed |
| D039 | codemap accepts any registered root: nogit glob walk of HOME/Temp yields a junk map and re-walks the whole tree on every staleness probe (71 s measured) | `mcp/src/tools/codemap/scan-sources.ts:191` | fixed |
| D054 | UTF-8 BOM page reported as missing_frontmatter; autofix prepends a second block, permanently losing project:/tags: and re-dating created/updated to today | `mcp/src/tools/frontmatter.ts:13` | fixed |
| D058 | anchors=0 project scoping is not inert: all project-tagged pages (51% of the live wiki) are ranked below every global page and dropped once 3 globals pass the floor | `mcp/src/tools/knowledge-search.ts:436` | fixed |
| D084 | dream-accept.sh applies staging with unchecked cp/rsync exit codes, then stamps archived_at, rm -rf's staging and reports "accepted" — a partial apply silently destroys the dream's only copy of its output | `scripts/dream-accept.sh:345` | open |
| D088 | dream-autostage.sh ignores archived_at: a discarded failed dream re-banners at every SessionStart until retention evicts it (scripts/dream-autostage.sh:108-111,167) | `scripts/dream-autostage.sh:112` | open |
| D095 | dream-snapshot.sh:148 selects transcripts by lexical filename sort (session-UUID/`sub-` prefix leads), not date, so the autonomous consolidation lane re-mines the same lexically-highest 50 forever and never consolidates 17 of 19 dates | `scripts/dream-snapshot.sh:148` | open |
| D107 | kb-drain-reconcile.sh:60 joins an unvalidated `(raw <id>)` back-ref into a file path — traversal silently rewrites live wiki ai-blocks and marks other projects' raw items processed | `scripts/kb-drain-reconcile.sh:50` | open |
| D108 | Backend 2 (API-key curl) posts CLI alias 'sonnet' as the Messages API model, and cannot demote — in-session capture in the recommended API-key config fails permanently | `scripts/lib.sh:2019` | open |
| D109 | sb_pin_to_user (lib.sh:631) and its TS twin pin-to-user.ts:22 splice untrusted-derived text into USER.md unflattened — forged markdown headings/directives inject into every SessionStart | `scripts/lib.sh:631` | open |
| D115 | sb_timeout's bash-watchdog fallback backgrounds the command, so bash replaces its stdin with /dev/null — claude -p gets an empty transcript on hosts lacking timeout(1)/gtimeout (stock macOS/BSD drainer path) | `scripts/lib.sh:1780` | open |
| D121 | Drainer sb_sanitize_slug's the project slug every other funnel keeps verbatim — split-brain PROJECT.md + wrong wiki project: facet, counters and session-count for any slug with uppercase, '_' or '.' (incl. the shipped monorepo `root__leaf` form) | `scripts/lib.sh:2190` | open |
| D122 | sb_call_extractor greps its own stdout for auth keywords before the JSON check (lib.sh:1913-1919), discarding valid extractions whose prose contains "unauthorized"/"invalid api key"/"not logged in" and reporting a false auth failure | `scripts/lib.sh:1916` | open |
| D139 | merge-persona-signals.sh:40 — `jq -s` aborts on one unparseable line, silently collapsing all accumulated persona signals to [] and rewriting the file with only the new signals | `scripts/merge-persona-signals.sh:40` | open |
| D154 | Invalid/unreadable user persona-rules.json disables every PreToolUse guard silently — no validity check, no fallback to persona-rules.default.json, no sb_log_error (scripts/persona-tool-guard.sh:58-63, 182, 297) | `scripts/persona-tool-guard.sh:297` | open |
| D159 | Plain-jq readers of audit-log.jsonl (sar-summary.sh:49,75; sb-health-snapshot.sh:102; skills/audit) abort at the first torn line — SAR banner silently vanishes or reports a falsely clean sar=1.00, and verdict counts under-report by ~20x | `scripts/sar-summary.sh:52` | open |
| D177 | stop-extract.sh:239 cleanup EXIT trap replaces the :41 gate-logging trap — merge-failed (:322) and persona-merge-failed (:343) are set but never written to any log | `scripts/stop-extract.sh:239` | open |
| D182 | symlink-guard fails open on Windows for `\\.\` device-namespace paths and NTFS 8.3 short names (shared sb_normalize_path gap, so wiki-write-guard/persona-tool-guard inherit it) | `scripts/symlink-guard.sh:101` | open |
| D183 | symlink-guard's BSD/macOS fallback fails OPEN whenever any intermediate directory is missing — `cd` fails at scripts/symlink-guard.sh:87 and line 96 hands back the raw lexical path, so both `..` traversal AND a symlinked ancestor with a not-yet-created subdir write into ~/.ssh, ~/.aws, /etc undenied | `scripts/symlink-guard.sh:96` | open |
| D201 | Setup consent ladder (skills/setup/SKILL.md:314-316) falsely tells macOS/Windows users the token-spending, OAuth-using auto_maintain lane is a bwrap-gated no-op; bwrap is additive-only and the lane runs on every OS (repeated in sb-run-and-operate:110-111,184) | `skills/setup/SKILL.md:314` | open |
| D206 | run-all.sh:110 SKIP detection is whole-file + column-0 only: indented partial skips in 8 tests are invisible, and column-0 partial skips discard the file's real passes (forcing manifest pins that mask future skips) | `tests/run-all.sh:110` | open |

## medium (64)

| id | title | where | status |
|---|---|---|---|
| D005 | sb-change-control SKILL.md §5 wrongly claims current policy is direct-to-main / zero merge commits since f4856e5, contradicting RELEASING.md and 15 actual PR merges through HEAD | `.claude/skills/sb-change-control/SKILL.md:154` | open |
| D007 | Flag catalog (sb-config-and-flags SKILL.md + flag-catalog.md) omits real, user-facing SB_* kill switches (SB_WIKI_GIT, SB_OBSERVATION_LEDGER, SB_BRAIN_OS_NO_LLM, SB_SCOPE_CROSS_SLOTS, SB_GROUNDING_DF_SHARE, and others) — doc has drifted stale since its 2026-07-05 census | `.claude/skills/sb-config-and-flags/SKILL.md:5` | open |
| D008 | sb-config-and-flags SKILL.md misattributes auto_codemap's file/line/test to the pre-0.41.0 extract-drain.sh location (now brain-os-run.sh), misstates discover-*.sh count as three (actually two), and flag-catalog.md documents only 1 of 6 SB_CODEMAP_* env vars (SB_CODEMAP_NEIGHBORS_MAX undocumented anywhere) | `.claude/skills/sb-config-and-flags/SKILL.md:116` | open |
| D011 | sb-run-and-operate §8 (and sb-change-control/sb-validation-and-qa) cite stale skill/test surface counts and list the removed `improve` skill as shipping; the stale-surface DENY regex has no entry for it | `.claude/skills/sb-run-and-operate/SKILL.md:262` | open |
| D015 | pre-push git hook is not auto-installed; docs describe it as the enforced local release gate but nothing wires core.hooksPath on setup | `.githooks/pre-push:2` | open |
| D016 | ci.yml:48-50 runs run-all.sh on ubuntu with the expected-skips guard unarmed (run-all.sh:205 Linux arm = __unset__), so whole-file SKIPs are warn-only and the only full-suite lane stays green | `.github/workflows/ci.yml:202` | open |
| D018 | Dream skill and dream-runner hard-code ~/.second-brain, ignoring the SB_BRAIN_DIR/BRAIN_DIR override the MCP honours | `agents/dream-runner.md:33` | open |
| D023 | hooks.json comments wrongly assume ordered/sequential hook execution within one event; races in registration-gate (SessionStart) and audit-log rotation (Stop) follow from the same false assumption | `hooks/hooks.json:51` | open |
| D029 | sb CLI's access-count telemetry write is raced by process.exit(): 0-byte .tmp litter, counts never persisted | `mcp/src/cli/sb-entry.ts:11` | fixed |
| D031 | knowledge_reindex tool description omits that it unconditionally runs knowledge_validate with autofix:true (deletes empty pages, rewrites frontmatter), bypassing the Phase 3b safe-default that knowledge_validate itself enforces | `mcp/src/server.ts:207` | fixed |
| D035 | Fact sanitizer leaves U+2028/U+2029; JS multiline-regex frontmatter parsing and first-match extraction let a forged type:/project:/related: embedded in the title win over the writer's real values, applied unattended under auto_accept=all | `mcp/src/tools/candidate-facts.ts:158` | fixed |
| D041 | codemap scanner has no test/spec exclusion — *.test.ts files consume graph nodes and map.md token budget alongside production code | `mcp/src/tools/codemap/scan-sources.ts:129` | fixed |
| D059 | Thin-scope auto-broaden buries a strictly stronger other-project page behind weak in-scope pages, contradicting the 'placed FIRST' reservation contract | `mcp/src/tools/knowledge-search.ts:439` | fixed |
| D060 | Search snippet fallback for description-less pages slices raw frontmatter-included file content instead of doc.body, injecting YAML into model context | `mcp/src/tools/knowledge-search.ts:248` | fixed |
| D066 | Empty-page autofix unlinks whitespace-only pages with no re-check, racing non-atomic writers | `mcp/src/tools/knowledge-validate.ts:257` | fixed |
| D076 | README:7-8 (and sb-memory-systems-reference SKILL.md:377) claim unattended consolidation/auto-accept is Linux-only; bwrap gates nothing and the lane auto-accepts on Windows/macOS at the shipped default | `README.md:7` | open |
| D077 | README promises every guard/pipeline has an SB_* kill switch; quality-gate PostToolUse nudge, stop-extract/pre-compact LLM extraction, and the always-included PROJECT.md hot-tier injection have none | `README.md:57` | open |
| D078 | README's "only network calls are Anthropic API calls" is contradicted by the vector-tier HuggingFace model fetch (and npm install in install-vector-deps.sh) | `README.md:110` | open |
| D079 | README and sb-architecture-contract SKILL.md call plan-first a soft/never-blocking nudge; with SB_INTENT_SPINE defaulting to on, it hard-denies PreToolUse (Gate A and Gate B) | `README.md:46` | open |
| D091 | dream-snapshot's cp -rp of the wiki is unchecked; a partial staging copy can pass dream-accept's 50% floor and trigger deletion of missing live pages via rsync --delete | `scripts/dream-snapshot.sh:136` | open |
| D096 | ensure-dirs.sh runs mutating wiki autofix (deletes empty pages via fs.unlink) at SessionStart without a wiki-history snapshot, contradicting the wiki_git reversibility promise it seeds in config.json | `scripts/ensure-dirs.sh:104` | open |
| D097 | ensure-dirs.sh comment wrongly claims SB_MAINTAINER_AUTO=off disables the token-spending maintainer; it only silences the suggestion banner (session-load.sh:205/249), while the real spend gates (maintain-llm-drain.sh:27, brain-os-run.sh:76) check only config.json auto_maintain | `scripts/ensure-dirs.sh:21` | open |
| D102 | Backend 2 (Anthropic API-key curl) uses a bare `timeout` binary with no gtimeout fallback and no --max-time — silently dead on stock macOS; extract-drain.sh and sb_timeout's docblock both describe a safety contract the code no longer implements | `scripts/lib.sh:2034` | open |
| D103 | flow-guard's Bash-egress keyword list misses git/gh/python/node/aws/openssl channels and file-based (@path) secret exfiltration | `scripts/flow-guard.sh:86` | open |
| D105 | Windows scheduled task uses schtasks power-management defaults (no start / stop on battery) with no detection or documentation — drainer silently stalls on battery | `scripts/install-extract-timer.sh:312` | open |
| D110 | sb_pin_to_user (scripts/lib.sh:644) dedupes via grep -qiF substring/multi-pattern match over the entire USER.md instead of exact pin-line match — silently drops legitimate pins/graduated signals, diverging from its TS twin | `scripts/lib.sh:644` | open |
| D111 | Scratch-path filter in sb_extract_deterministic / sb_extract_archived_deterministic is POSIX-only; Windows AppData\Local\Temp and macOS $TMPDIR paths pass through and pollute PROJECT.md as auto-captured decisions | `scripts/lib.sh:134` | open |
| D116 | Lock-staleness budget proof (lib.sh:2203) ignores unbounded nested brain-os passes (embed warm pass, codemap regen) that run inside the same mkdir-lock by default, and the lock's mtime is never refreshed — a long-but-live run gets stolen at 7200s and the steal cascades via an unconditional EXIT trap | `scripts/lib.sh:2203` | open |
| D118 | HOME directory and Temp root get registered as projects; brain-os code-maps the entire home dir and injects browser-extension paths as "architectural spine" | `scripts/lib.sh:723` | open |
| D123 | sb_auto_memory_state derives the Claude Code project key from the POSIX-normalized (not Windows-drive-dashed) git root on Windows, so the native auto-memory store is never found | `scripts/lib.sh:2411` | open |
| D128 | maintain-deterministic.sh:28 inverts KNOWLEDGE_DIR precedence vs sb_knowledge_dir() (lib.sh:79-86), causing validate/reindex/prune/quarantine-redrain to operate on a stale/wrong wiki tree when KNOWLEDGE_DIR env and the plugin option diverge | `scripts/maintain-deterministic.sh:28` | open |
| D131 | Auto-accept backup tars wiki only, skipping dream-accept's own wiki+graph backup — appended graph edges have no undo trail | `scripts/maintain-llm-drain.sh:486` | open |
| D132 | 3-strike quarantine self-clears on version-only preflight regardless of actual failure cause, so non-version failure classes (auth, model retirement, attestation, Stage B) retry forever instead of staying quarantined | `scripts/maintain-llm-drain.sh:65` | open |
| D133 | A dream-snapshot refusal (pending/running dream not yet stale, or other transient staging error) silently burns the full weekly auto_maintain slot — stderr discarded, no error-log entry, no failure-strike counted | `scripts/maintain-llm-drain.sh:143` | open |
| D134 | Stage B bwrap jail ro-binds the whole filesystem (transcripts + credentials readable) and never clears env, contradicting the 'transcripts NOT bound' / 'no creds in its env' documentation and prose-only test lock | `scripts/maintain-llm-drain.sh:402` | open |
| D142 | merge-project-update: recent_decisions/open_blockers/plan/cross_refs accept non-string and multi-line elements and write junk bullets into PROJECT.md | `scripts/merge-project-update.sh:84` | open |
| D143 | wiki_updates content dedup grep uses a multi-line 60-byte prefix as a pattern set — real updates are silently dropped whenever any one line of the prefix already appears in the page | `scripts/merge-project-update.sh:725` | open |
| D145 | persona-context.sh `/?` prefix silently spawns a paid Opus call while its own header comment and README.md:47 claim UserPromptSubmit makes "no LLM call" | `scripts/persona-context.sh:10` | open |
| D151 | Self-edit ask rules regex doesn't match installed plugin cache path layout (version dir breaks the pattern), leaving live hook scripts unprotected when resource_scope is off/widened | `scripts/persona-rules.default.json:57` | open |
| D155 | Resource-scope allowlist prefix match is bypassed by unnormalized `..` traversal (sb_normalize_path never lexically collapses path segments) | `scripts/persona-tool-guard.sh:237` | open |
| D156 | Rewrite rule fails open to allow+empty-command when the sed replacement itself is malformed (only SOH-in-operand is guarded) | `scripts/persona-tool-guard.sh:363` | open |
| D157 | PreCompact and the drainer skip quality-gate/merge-edges/pin-candidate stages that Stop runs — relations[] silently dropped outside stop-extract.sh | `scripts/pre-compact.sh:176` | open |
| D158 | quality-gate.sh emits plain PostToolUse stdout instead of hookSpecificOutput.additionalContext, so the self-review instruction never reaches model context (dead gate, wasted spawn) | `scripts/quality-gate.sh:3` | open |
| D161 | A project whose PROJECT.md exists but is missing from projects.jsonl is never re-registered; with an empty registry it also logs a false 'corrupt line?' error every session | `scripts/session-load.sh:92` | open |
| D162 | Over-cap PROJECT.md render silently drops any non-canonical section without a breadcrumb | `scripts/session-load.sh:776` | open |
| D173 | session-load.sh's non-gate= trace messages (maintainer-suggested, drain-health, drain-deadman, maintainer-auto-*, loop-dead) bypass the R6b gate=-only trace-routing rule and pollute error-log.jsonl | `scripts/session-load.sh:252` | open |
| D179 | Background episodic-index node process (stop-extract.sh:369, pre-compact.sh:213) inherits hook stdout, so Stop/PreCompact can't be confirmed closed until the index build finishes; hook-timer.sh latency telemetry structurally excludes that time | `scripts/stop-extract.sh:370` | open |
| D181 | stop-verify-gate.sh accepts unordered, exit-code-blind Bash text as verification evidence — a stray `cat build.log` or pre-edit test run silently approves any later unverified edits | `scripts/stop-verify-gate.sh:86` | open |
| D184 | Unicode tag-block detector's fixed 3-byte prefix (F3 A0 80) misses tag LETTERS U+E0041–U+E007A (3rd byte 0x81); comment at line 136 also cites the wrong byte range | `scripts/tool-return-scanner.sh:142` | open |
| D185 | Surface-budget ratchet silently disabled by a missing or non-numeric budget key | `scripts/validate-plugin.sh:202` | open |
| D188 | verify.sh's 66-line hot-tier cap is stale vs session-load.sh's byte-budget design and, combined with .last-verify only advancing on full pass, causes a permanent, worsening FAIL | `scripts/verify.sh:22` | open |
| D190 | wiki-forget-score.sh's *session* glob strips FORGET category-protection from any protected-category slug containing 'session', not just auto-generated session-narrative noise | `scripts/wiki-forget-score.sh:87` | open |
| D191 | wiki-history.sh restore ignores pre-restore safety-snapshot failure and proceeds, then falsely claims an undo point exists | `scripts/wiki-history.sh:205` | open |
| D193 | wiki-restore.sh silently overwrites a live page that now occupies the restored slug (and destroys the archived copy too, since it's a move not a copy) | `scripts/wiki-restore.sh:38` | open |
| D196 | Inline dream step 2f calls knowledge_reindex (autofix:true) against the LIVE wiki mid-dream, violating the skill's own "never touch live wiki during execution" constraint and breaking dream_discard's rollback guarantee | `skills/dream/SKILL.md:177` | open |
| D199 | Eight skills invoke external binaries/MCP tools not declared in their own allowed-tools, and the repo's own guard test only spot-checks a subset | `skills/review/SKILL.md:106` | open |
| D202 | Setup consent ladder mis-describes auto_improve's effect and omits half the seeded automation knobs (shows "three tiers", six are seeded) | `skills/setup/SKILL.md:310` | open |
| D204 | upgrade/SKILL.md and lint/SKILL.md use bare `sort -V` (BSD/macOS-incompatible) with no fallback, while sibling scripts in the same repo hand-roll BSD-safe alternatives for this exact reason | `skills/upgrade/SKILL.md:33` | open |
| D207 | run-all.sh sandboxes HOME only: parent BRAIN_DIR/KNOWLEDGE_DIR/SB_*/CLAUDECODE pass through to every test | `tests/run-all.sh:78` | open |
| D210 | tests/test-bundle-current.sh's sed 's/ && /\n/g' relies on a GNU-only \n-as-newline extension, spuriously failing the bundle-current gate under BSD sed on macOS, and the class is unguarded (macOS CI lane skips this test; portability guard deliberately excludes tests/) | `tests/test-bundle-current.sh:28` | open |
| D212 | SB_FORGET_MIN_AGE_DAYS pinned to 0 in every accept-time FORGET test — no positive-case lock on the 30-day reversibility floor | `tests/test-dream-accept-guards.sh:225` | open |
| D215 | SB_INTERACTIVE_OVERRIDE pins the interactive-defer decision in every drainer test; the POSIX pgrep branch is never behaviorally exercised | `tests/test-extract-drain.sh:22` | open |
| D218 | test-persona-tool-guard.sh tests 3, 7, and the persona-rules self-edit check are tautological — they pass via the resource-scope ask, not the hot-tier/self-edit rules they claim to lock | `tests/test-persona-tool-guard.sh:44` | open |
| D219 | test-persona-tool-guard.sh Tests 2-7 and the case-variant block pollute the maintainer's live ~/.second-brain/audit-log.jsonl (missing BRAIN_DIR isolation, unlike every other test in the file) | `tests/test-persona-tool-guard.sh:38` | open |

## low (84)

| id | title | where | status |
|---|---|---|---|
| D001 | sb-architecture-contract hook table stale: fork matcher missing, hook-timer/timeout counts, MCP line numbers wrong | `.claude/skills/sb-architecture-contract/SKILL.md:68` | open |
| D002 | Stale file:line citations pervasive across CONSTITUTION, daily-prompt, and every sb-* skill | `.claude/skills/sb-architecture-contract/SKILL.md:19` | open |
| D004 | Architecture contract §7 overstates write-time frontmatter enforcement and carries stale skill/agent/script/test counts | `.claude/skills/sb-architecture-contract/SKILL.md:309` | open |
| D012 | validation-and-qa/change-control cite portability guard count as 11; actual is 12 | `.claude/skills/sb-validation-and-qa/SKILL.md:203` | open |
| D013 | validation-and-qa describes macOS CI lane as running 4 tests against an mcp/test tree; actually 5 tests and mcp/test folded into src | `.claude/skills/sb-validation-and-qa/SKILL.md:181` | open |
| D014 | validation-and-qa claims RELEASING.md still hardcodes a stale check count; that was already fixed | `.claude/skills/sb-validation-and-qa/SKILL.md:62` | open |
| D019 | Interactive dream-runner finalize/heartbeat can overwrite a concurrent dream_cancel with status=completed (unguarded terminal-state race) | `agents/dream-runner.md:216` | open |
| D020 | Untrusted-content agents (knowledge-maintainer, raw-drainer) retain unrestricted rm/mv/cp/scripts-glob Bash grants with no test lock | `agents/knowledge-maintainer.md:19` | open |
| D022 | CONSTITUTION claims hot tier is delegated to native memory/proven-read retrieval; session-load force-injects ~5.7KB every SessionStart regardless | `CONSTITUTION.md:66` | open |
| D024 | hooks.json symlink-guard comment lists 8 protected prefixes, omitting the actual additional guard on ~/.claude/.credentials.json | `hooks/hooks.json:108` | open |
| D026 | daily-prompt/plan doc claims validate-plugin.sh emits a known WARN about an undocumented fork matcher; it emits none (fork already included) | `docs/daily-prompt.md:519` | open |
| D027 | Makefile claims release-check is equivalent to the pre-push gate, but pre-push omits the vector-deps import smoke test | `Makefile:25` | open |
| D028 | agent-grants.test.ts denylist doesn't forbid network/exfil-capable tool grants (WebFetch/curl/wget) on untrusted-content consolidation agents | `mcp/src/agent-grants.test.ts:24` | open |
| D030 | sb help documents only BRAIN_DIR/KNOWLEDGE_DIR; resolver actually prioritizes SB_BRAIN_DIR/CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR first | `mcp/src/cli/sb.ts:34` | open |
| D036 | codemap isDirty counts untracked files, making stores permanently dirty/stale and forcing needless regen every tick | `mcp/src/tools/codemap/drift.ts:409` | open |
| D038 | codemap RE_PLAIN_FN regex admits zero whitespace after 'function', yielding bogus symbol names from unrelated statements | `mcp/src/tools/codemap/extract.ts:382` | open |
| D042 | codemap IGNORE_DIRS (build/out/vendor) matched as path segments at any depth, silently dropping legitimate source dirs | `mcp/src/tools/codemap/scan-sources.ts:127` | open |
| D043 | codemap serialize aborts at first oversized line instead of skipping it, can empty the map at small token budgets | `mcp/src/tools/codemap/serialize.ts:294` | open |
| D044 | codemap store.ts leaves orphaned graph.json.tmp/map.md.tmp files when the CLI process is killed mid-write | `mcp/src/tools/codemap/store.ts:330` | open |
| D045 | Stale 'local BM25 reconcile' doc comments and vestigial hermeticity env pins in consolidate-writer-cli/harness/docs | `mcp/src/tools/consolidate-writer-cli.ts:6` | open |
| D047 | dream_* MCP tools accept an unvalidated dream_id joined into filesystem paths and shell script arguments | `mcp/src/tools/dream.ts:98` | fixed |
| D048 | Wiki embeddings cache never evicts entries for deleted/renamed pages, growing unboundedly and re-serialized on every hit | `mcp/src/tools/embeddings.ts:116` | open |
| D055 | frontmatter parseDoc splits file paths on '/' only, breaking type derivation on Windows backslash paths | `mcp/src/tools/frontmatter.ts:127` | open |
| D061 | aiBlockSnippet yields an empty snippet with no description fallback when a page's ai-block fields mismatch its declared type | `mcp/src/tools/knowledge-search.ts:244` | open |
| D062 | Hybrid search silently swallows per-inference embedding errors, degrading to bm25-only with the cause discarded | `mcp/src/tools/knowledge-search.ts:368` | open |
| D064 | No stemming in BM25 tokenization: singular/plural/inflection variants miss or reorder results wholesale | `mcp/src/tools/knowledge-search.ts:616` | open |
| D067 | addFrontmatter vs patchFrontmatter derive related: differently for aliased [[target|alias]] links (knowledge-validate.ts:405) | `mcp/src/tools/knowledge-validate.ts:405` | open |
| D074 | CONSTITUTION's 'injection-gate satisfiability lock' test asserts a retired constant, not the live grounded-gate default duplicated across two CLIs | `mcp/src/tools/retrieval-guards.test.ts:159` | open |
| D075 | walk-wiki.ts dot-directory skip is gated per-caller (skipHidden flag), so stats/search/validate/reindex diverge on dot-dirs | `mcp/src/tools/walk-wiki.ts:25` | open |
| D080 | README data-locations table omits ~/knowledge/graph and irreplaceable ~/.second-brain dirs (wiki-archive, dreams, wiki-history.git, backups) | `README.md:104` | open |
| D081 | README claims the capture skill is model-invoked; its frontmatter disables both user- and model-invocation | `README.md:79` | open |
| D082 | config-change-guard's fallback error-log write uses a different JSON schema than sb_log_error, invisible to verify.sh's freshness check | `scripts/config-change-guard.sh:43` | open |
| D086 | dream-accept's edge-count delta on an empty edges.jsonl produces '0\n0', an arithmetic syntax error that silently skips edge accounting | `scripts/dream-accept.sh:426` | open |
| D087 | dream status.json rewrites via mktemp(/tmp)+mv are non-atomic when TMPDIR is a different filesystem than BRAIN_DIR | `scripts/dream-accept.sh:444` | open |
| D089 | dream-autostage watermark jumps forward on accept (anchors to deleted transcripts dir), silently un-counting transcripts arriving before acceptance | `scripts/dream-autostage.sh:119` | open |
| D090 | dream-diff.sh 'Removed Pages' lists live pages created after the snapshot as removals, though accept's PROTECT logic never deletes them | `scripts/dream-diff.sh:79` | open |
| D092 | dream-snapshot's one-active-dream guard is check-then-act with no lock, and second-resolution dream IDs let concurrent creators collide on one staging dir | `scripts/dream-snapshot.sh:55` | open |
| D093 | The 4.4MB embeddings cache is staged into every dream and rolled back onto live at accept, wasting disk and forcing re-embedding | `scripts/dream-snapshot.sh:136` | open |
| D094 | Stale comments/contract text describe an obsolete mtime-based FORGET age gate and skill-prose archive step no longer used | `scripts/dream-snapshot.sh:130` | open |
| D098 | With ANTHROPIC_API_KEY, every transcript is extracted twice (in-session Stop + drainer) — in-session success never recorded in extraction-state | `scripts/extract-drain.sh:362` | open |
| D099 | Interactive-session probe (claude.exe / pgrep -x claude) misses npm-installed CLIs (node.exe wrapper) — fail-open despite comment claiming coverage | `scripts/extract-drain.sh:39` | open |
| D100 | sb_drain_escape_safe is dead logic (every branch returns 0) wrapped in a misleading safety-narrative comment inviting reintroduction of a starvation bug | `scripts/extract-drain.sh:162` | open |
| D101 | 3-strike deterministic floor marks failed LLM extraction as terminal outcome:ok, making transcripts silently evictable with no re-queue on backend recovery | `scripts/extract-drain.sh:375` | open |
| D106 | write_vbs_shim's fail-loud refusal return value is discarded at the only call site — install proceeds and reports 'applied' with a missing launcher | `scripts/install-extract-timer.sh:308` | open |
| D113 | Raw hook-payload session_id used unsanitized in archive/marker file paths (sb_archive_transcript) while sibling code sanitizes the same payload class | `scripts/lib.sh:1135` | open |
| D114 | Archive session-meta line_count/tool_count is stamped only at file creation (never updated) and uses local date while all other stamps use UTC | `scripts/lib.sh:1144` | open |
| D117 | sb_timer_installed only checks the .sh shim, not the .vbs launcher the Windows task actually runs — missing launcher reads as 'installed', never self-heals | `scripts/lib.sh:2470` | open |
| D124 | sb_project_identity's path normalizer uses GNU-only sed `\L` case-fold replacement — produces a literal 'L' on BSD/macOS sed, an unguarded GNU-ism | `scripts/lib.sh:956` | open |
| D125 | sb_validate_wiki duplicates the plugin-root resolver inline instead of calling sb_plugin_root, violating the single-locator/no-per-call-site-copy rule | `scripts/lib.sh:569` | open |
| D126 | pty retry gate only checks `command -v script`; BSD/macOS script(1) lacks the util-linux -qfc syntax used, so the retry always fails and misdirects diagnosis to 'recursive-claude' | `scripts/lib.sh:1955` | open |
| D127 | sb_preprocess_transcript aborts silently at the first malformed JSONL line (jq stream parse error swallowed), truncating the archived transcript window | `scripts/lib.sh:1126` | open |
| D130 | maintain-deterministic.sh header comment describes stale pre-0.4x call wiring (extract-drain.sh, not brain-os-run.sh+brain_os gate) | `scripts/maintain-deterministic.sh:5` | open |
| D135 | maintain-llm-drain.sh writes successful auto-accept breadcrumbs (exit 0) into error-log.jsonl instead of audit-log | `scripts/maintain-llm-drain.sh:498` | open |
| D137 | merge-edges.sh writes LLM-supplied valid_from/confidence into edges unvalidated (format/type) | `scripts/merge-edges.sh:115` | open |
| D140 | merge-persona-signals.sh: a single malformed signal element aborts the jq reduce, silently dropping the whole batch with exit 0 | `scripts/merge-persona-signals.sh:43` | open |
| D141 | merge-persona-signals.sh learned-rule arming has never fired — cksum keys never re-match due to per-session paraphrasing | `scripts/merge-persona-signals.sh:266` | open |
| D152 | persona-rules.default.json warn-rm-rf regex misses split/long-option forms (`rm -r -f`, `rm --recursive --force`) | `scripts/persona-rules.default.json:50` | open |
| D153 | persona-rules.default.json hot-tier protection rule is Write-only, letting Edit/MultiEdit bypass it | `scripts/persona-rules.default.json:42` | open |
| D160 | sar-summary.sh header claims it never rotates the audit log; it is in fact the sole routine caller of sb_rotate_audit_log | `scripts/sar-summary.sh:6` | open |
| D163 | session-load.sh has no degenerate-slug guard — CLAUDE_PROJECT_DIR=/ scaffolds a project at the projects root with slug '/' | `scripts/session-load.sh:52` | open |
| D165 | session-load.sh held-untrusted count uses the `grep -c . || echo 0` double-zero anti-pattern, emitting bash integer-expression errors | `scripts/session-load.sh:1080` | open |
| D167 | session-load.sh runs install-extract-timer.sh --ensure synchronously with no timeout inside the 15s hook, despite being documented 'bounded' | `scripts/session-load.sh:480` | open |
| D168 | session-load.sh comment claims byte-budget skip is loud in error-log.jsonl; gate=* messages actually route to audit-log.jsonl | `scripts/session-load.sh:643` | open |
| D169 | session-load.sh injects repo-controlled code-map file paths verbatim into the trusted SessionStart block with no sanitisation | `scripts/session-load.sh:668` | open |
| D174 | session-load.sh SessionStart banners are glued together via command-substitution newline stripping and truncated mid-sentence by the byte cap | `scripts/session-load.sh:251` | open |
| D175 | session-load.sh reconcile-trend grep does unscoped substring matching over audit-log.jsonl, picking up unrelated guard rows | `scripts/session-load.sh:515` | open |
| D176 | session-load.sh never prunes stale/orphaned project registry entries or unregistered projects/ dirs, desyncing registry from disk | `scripts/session-load.sh:87` | open |
| D186 | validate-plugin.sh checks frontmatter field presence only; invalid boolean values (e.g. 'maybe') pass silently | `scripts/validate-plugin.sh:167` | open |
| D187 | validate-plugin.sh never verifies a hooks.json command path points at an existing script | `scripts/validate-plugin.sh:60` | open |
| D189 | verify.sh resolves active project via git-toplevel basename instead of sb_resolve_slug, misreporting PROJECT.md as missing | `scripts/verify.sh:23` | open |
| D192 | wiki-history.sh's reindex-failure log branch is dead code because sb_reindex_wiki always returns 0 | `scripts/wiki-history.sh:233` | open |
| D194 | wiki-write-guard.sh allows an empty-content Write to create a frontmatter-less wiki page | `scripts/wiki-write-guard.sh:137` | open |
| D195 | capture/SKILL.md documents an automatic hook capture path (raw-capture CLI) that no caller invokes; dead surface | `skills/capture/SKILL.md:3` | open |
| D197 | dream/SKILL.md theme-page step instructs the 'related: [[member]]' form that the same file and dream-runner.md call invalid YAML | `skills/dream/SKILL.md:135` | open |
| D198 | import-host/SKILL.md misstates pin_to_user's cap as a 15-line USER.md file limit; it's a 15-pin-line cap only | `skills/import-host/SKILL.md:323` | open |
| D200 | review/SKILL.md claims the release checklist runs liveness-check.sh --strict; no release gate actually invokes it | `skills/review/SKILL.md:111` | open |
| D203 | Multiple stale state artifacts (tool-registry.json, persona-budget.json, .graph, .embeddings) have no writer and mislead readers | `skills/status/SKILL.md:295` | open |
| D208 | run-all.sh reports ALL GREEN/exit 0 when the test glob resolves to zero tests | `tests/run-all.sh:236` | open |
| D209 | run-all.sh exports SB_SUITE_REAL_HOME_PATH but no test consumes it; dead plumbing misleads real-HOME-access audits | `tests/run-all.sh:39` | open |
| D211 | test-doc-sources-hook.sh isn't hermetic to CLAUDE_PROJECT_DIR and fails only when run inside a Claude Code session | `tests/test-doc-sources-hook.sh:12` | open |
| D214 | test-dream-lifecycle.sh uses fixed /tmp/ds.json shared across concurrent runs, racy under parallel sessions | `tests/test-dream-lifecycle.sh:173` | open |
| D216 | test-guard-wiring.sh only checks PreToolUse guard registration; PostToolUse scanner, Stop gate, ConfigChange hook can be unwired undetected | `tests/test-guard-wiring.sh:25` | open |
| D220 | Drainer/extract test gaps: claude stub ignores stdin, flock test auto-passes when flock absent, sb_timeout watchdog branch has zero coverage | `tests/test-stop-extract.sh:106` | open |
| D221 | wiki-forget-score.sh's created: frontmatter age path (99% of live wiki) is untested; fixtures only exercise the 2%-case mtime fallback | `tests/test-wiki-forget-score.sh:117` | open |

## already-known weak points (45) — not re-verified

| id | title | where |
|---|---|---|
| D003 | Docs wrongly describe drainer's in-session exit (0 vs actual 3) and invert the OAuth-starvation escape-safe gate logic | `.claude/skills/sb-architecture-contract/SKILL.md:134` |
| D009 | diagnostics/architecture skills cite stale numeric facts (persona-context 10s vs 25s timeout, hot-tier cap, per-turn bytes, marker sweep threshold) | `.claude/skills/sb-diagnostics-and-tooling/SKILL.md:149` |
| D010 | graph/project-registry.jsonl has no writer in the repo despite docs describing a 'setup step 4b' writer | `.claude/skills/sb-run-and-operate/references/data-geography.md:77` |
| D021 | CONSTITUTION overstates cross-platform CI verification; macOS lane runs 5 tests and BSD-only gaps leave forgetting/KB-isolation untested | `CONSTITUTION.md:96` |
| D032 | persona_think unguarded: nested/headless spawn can loop billed opus calls with no rate limit, audit, or cost signal | `mcp/src/server.ts:379` |
| D033 | archive_to_wiki overwrites an earlier archived page on date+40-char-slug collision, corrupting back-references | `mcp/src/tools/archive-to-wiki.ts:309` |
| D034 | atomic-write tmp files (.tmp.<pid>) orphaned when process is killed/exits before rename; unlink only runs in catch | `mcp/src/tools/atomic-write.ts:18` |
| D040 | codemap regen fails on merge conflicts: git ls-files -z emits each conflicted path per stage, buildGraph throws duplicate id | `mcp/src/tools/codemap/scan-sources.ts:186` |
| D046 | doc-sources filterIgnored fails open when git is absent/errors, indexing gitignored docs into the registry | `mcp/src/tools/doc-sources.ts:53` |
| D049 | Missing vector deps cause per-process 'model load failed' log flood since the load-error dedupe cannot span processes | `mcp/src/tools/embeddings.ts:59` |
| D050 | Episodic-index 'real model' tests guard load-bearing assertions behind conditionals, masking a regression to no-op | `mcp/src/tools/episodic-index.test.ts:399` |
| D051 | Symlink-escape path-guard defenses have zero behavioral test coverage on the Windows dev platform (all skipped) | `mcp/src/tools/episodic-read-guard.test.ts:16` |
| D052 | Episodic index is ~38% noise: task-notification/slash-command envelopes indexed and embedded as real user exchanges | `mcp/src/tools/episodic-search.ts:154` |
| D053 | episodic_read with startLine 0 (or negative) returns an empty slice instead of the file start, with no validation | `mcp/src/tools/episodic-search.ts:526` |
| D056 | Bi-temporal graph fold loses history on re-assert after invalidate: as_of queries miss the earlier valid interval | `mcp/src/tools/graph-store.ts:100` |
| D063 | Recency and stub multipliers still applied after RRF fusion, bulldozing rank order on a compressed score scale (known) | `mcp/src/tools/knowledge-search.ts:390` |
| D065 | access-counts.json records search candidacy (not actual injection/reads); a test fixture also leaked into the live file on Windows | `mcp/src/tools/knowledge-search.ts:489` |
| D068 | persona-think.ts unconditionally passes --bare, dead under OAuth-only auth (no ANTHROPIC_API_KEY) | `mcp/src/tools/persona-think.ts:42` |
| D069 | persona-think.ts internal timeout (30s) exceeds hook's hard ceiling (25s); harness kills hook before CLI error path runs | `mcp/src/tools/persona-think.ts:27` |
| D070 | persona-think.ts: malformed SB_PERSONA_TIMEOUT_MS becomes NaN (immediate timeout); SIGKILL escalation is dead code (checks .killed wrong) | `mcp/src/tools/persona-think.ts:27` |
| D071 | pin-to-project.ts bulletCore regex can't match CRLF line endings, so re-pins duplicate dated decisions on Windows-edited PROJECT.md | `mcp/src/tools/pin-to-project.ts:121` |
| D072 | pin_to_user (TS and bash twin) lacks newline/backtick flattening, letting text forge '## Section' headers into auto-injected USER.md | `mcp/src/tools/pin-to-user.ts:22` |
| D073 | resolveSlugByPath case-sensitive comparison on Windows paths mints a ghost project slug for case-variant CLAUDE_PROJECT_DIR | `mcp/src/tools/project-registry.ts:241` |
| D085 | Windows no-rsync dream-accept path copies with cp -r (no -p), resetting every live page's mtime on each accept | `scripts/dream-accept.sh:345` |
| D104 | graph-migrate.sh writes CRLF-terminated jsonl records on Windows (jq stdout piped straight to log instead of captured first) | `scripts/graph-migrate.sh:116` |
| D112 | sb_call_extractor's documented return-value contract is false for the in-session OAuth 'queued' path, and its docblock is misplaced/detached from the function | `scripts/lib.sh:1853` |
| D119 | audit-log.jsonl has mixed CRLF/LF line endings from native jq's text-mode stdout append mixed with LF-writing bash printf callers | `scripts/lib.sh:469` |
| D129 | maintain-deterministic.sh carries raw embedded CR bytes in a `tr -d` set — latent CRLF-poisoning risk on re-edit | `scripts/maintain-deterministic.sh:54` |
| D136 | maintain-llm-drain.sh error-log dominated by 541 stale 'bwrap absent' rows from a removed gating condition | `scripts/maintain-llm-drain.sh:1` |
| D138 | merge-edges.sh conflict-detection snapshot (`jq -s`) aborts silently on one torn edges.jsonl line, disabling checks forever | `scripts/merge-edges.sh:228` |
| D146 | persona-context.sh `/?` route failures are fully silent — stderr discarded, no error-log row, no user-facing signal | `scripts/persona-context.sh:40` |
| D147 | persona-context.sh per-prompt injections are never recorded to the manifest, so the injection→read metric can't measure them | `scripts/persona-context.sh:393` |
| D148 | persona-context.sh relink guard re-spawns install-vector-deps every prompt for bm25-only users, logging false 'relink failed' errors | `scripts/persona-context.sh:217` |
| D149 | persona-context.sh decision-ritual trailer is unconditionally ~558B, contradicting the '~150B action-prompts-only' comment | `scripts/persona-context.sh:462` |
| D150 | persona-context.sh swallows lib.sh source failure then calls sb_resolve_slug unconditionally, risking silent unscoped injection | `scripts/persona-context.sh:200` |
| D164 | session-load.sh graph-neighbourhood condition contains a literal `\n` token, working only by `command -v` multi-name accident | `scripts/session-load.sh:984` |
| D166 | session-load.sh scaffold-time projects.jsonl append is not CR-stripped, relying on a rewrite pass that can be skipped | `scripts/session-load.sh:95` |
| D170 | session-load.sh injection manifest is codemap-dominated — wiki-enrichment is usually byte-budget-skipped, invalidating the read-rate metric | `scripts/session-load.sh:942` |
| D171 | session-load.sh manifest is appended without dedup across repeated SessionStart events of one session, inflating injected/read counts | `scripts/session-load.sh:37` |
| D172 | session-load.sh registers the home directory as a project, causing the codemap to glob-scan all of $HOME and slug-hijack unregistered dirs under it | `scripts/session-load.sh:99` |
| D178 | stop-extract.sh:226 strips \n not \r from jq output — CR embedded in tool-count-zero audit rows | `scripts/stop-extract.sh:226` |
| D180 | value-loop telemetry only measures the first Stop window per session; later-turn injected-id reads are never counted | `scripts/stop-extract.sh:131` |
| D205 | using-second-brain/SKILL.md and README describe per-prompt persona-card/catalog injection removed since 0.32.0 | `skills/using-second-brain/SKILL.md:32` |
| D213 | test-dream-accept-guards.sh/test-symlink-guard.sh log skipped subtests as 'pass (skipped)', inflating apparent PASS counts | `tests/test-dream-accept-guards.sh:121` |
| D217 | test-jq-crlf-windows.sh stub only taints -r/-j/-rs/-rc; real Windows jq CRLFs every stdout mode, leaving most lib.sh jq call sites unlocked | `tests/test-jq-crlf-windows.sh:17` |

## refuted (3)

| id | title | note |
|---|---|---|
| D006 | sb-config-and-flags SKILL.md documents a resolveKnowledgeDir split/reversed-precedence bug that was already fixed (single funnel via brain-paths.ts); doc-drift only, downgrade from medium to low since the underlying resolver is correctly single-sourced and machine-behavior is unaffected | critic flags D083/D144 refutations as thin — re-check if the class recurs |
| D083 | discover-installed.sh prints the full 259 KB plugin catalog to stdout on both paths at SessionStart (~65K tokens injected, or it eats the ~10K hook ceiling ahead of session-load.sh); no consumer reads stdout | critic flags D083/D144 refutations as thin — re-check if the class recurs |
| D144 | Refuted: merge-project-update.sh's raw unescaped printf is real, but sb_reindex_wiki (called unconditionally at line 785-788 whenever a wiki write happens) runs knowledgeValidate autofix in the same script invocation and rewrites the frontmatter to valid escaped YAML before the run completes | critic flags D083/D144 refutations as thin — re-check if the class recurs |

## Completeness critic — not covered by this audit

**Uncited but load-bearing files:** mcp/src/tools/consolidate-writer.ts (P6 writer), mcp/src/path-guard.ts, sanitize.ts, minhash.ts,
egress-budget.ts, nested-spawn-guard.ts, raw-inbox.ts; scripts/hook-timer.sh, brain-os-run.sh, sb-prune-archives.sh, plan-first-nudge.sh,
extraction-quality-gate.sh; bin/install-vector-deps.sh, bin/sb; skills/doubt, lint, audit.

**Sibling sites of confirmed classes (unverified):**
- torn `>>` appends (D120 class): scripts/hook-timer.sh:58, wiki-write-guard.sh:128, merge-project-update.sh:566/685, extract-drain.sh:334-382
- `jq -s` abort-on-one-bad-line (D139/D159 class): lib.sh:852/902/920 and session-load.sh:96 (projects.jsonl), session-load.sh:714, persona-context.sh:156, sb-prune-archives.sh:32 (gates deletion)
- bare `timeout` with no gtimeout fallback (D102 class): extraction-quality-gate.sh:104/107
- inline resolver copy (D128 class): graph-cluster.sh:17
- unvalidated MCP path arg (D057 class): mcp/src/tools/dream.ts:348-352 (`dream_id` → recursive fs.rm)

**Unlocked CONSTITUTION promises:** single-source resolution scanned for mcp/src only (bash unlocked); least-privilege agents (3 of 4 hold
unscoped Write/Edit + rm/mv); "tests must not disable the thing they test" has no gate; surface budget has no key for mcp/src, bin/, .claude/skills;
cache-stable injection order untested; README "brain_os:false disables the whole lane" unverified per pass.

Full evidence (verdict votes, repro output): session scratchpad `ledger.json` / `defects-compact.json` (2026-09-05, session 4ea1f126).
