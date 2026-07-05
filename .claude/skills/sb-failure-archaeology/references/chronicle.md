# The Incident Chronicle — full settled-battle record

Companion table to `sb-failure-archaeology/SKILL.md` (read that first for the status legend,
term definitions, cross-cutting classes, and how-to-search commands). Every incident here is
symptom → root cause → evidence → fix → status. Evidence anchors are repo-verifiable:
CHANGELOG version headings (`grep -n "^## <ver>" CHANGELOG.md`), commit shas (`git show <sha>`),
and working-tree file:line comments.

Snapshot: as of 0.33.31 (2026-07-05). HEAD = `6fba312` (release 0.33.30); the 0.33.31 batch is
UNCOMMITTED in the working tree (`plugin.json` already says 0.33.31; `git show HEAD:CHANGELOG.md`
has no 0.33.31 entry). Line numbers cited from the working tree can drift — re-anchor by the
quoted comment text, not the number.

Status legend: **FIXED@ver** (released) · **FIXED-WT@0.33.31** (fixed in working tree, not yet
released at authoring time) · **MITIGATED** (partial/behavioral fix, residual documented) ·
**OPEN**.

---

## 1. Windows HOME→CWD stray-`.second-brain/` class

- **Symptom:** stray `.second-brain/` (sometimes `knowledge/`) folders appearing at the ROOT of
  unrelated repos on Windows.
- **Root cause:** ~16 MCP tool/CLI call sites resolved the brain dir as
  `join(process.env.HOME ?? '', '.second-brain')`. On native-Windows Node, `HOME` is unset
  (Windows uses `USERPROFILE`), so the fallback collapsed to a CWD-RELATIVE path and wrote
  runtime state wherever the MCP server happened to run. Bash hooks run under MSYS where `$HOME`
  IS set — only the Node side rotted (asymmetric platform premise).
- **Evidence:** CHANGELOG `## 0.33.17`; commit `aa43dcb`.
- **Fix:** single canonical resolver `mcp/src/brain-paths.ts` (`os.homedir()` + CR/LF strip);
  all call sites + `dream.ts` migrated onto it; contract tests + a SOURCE-SCAN guard that fails
  the build if any file reintroduces `process.env.HOME` for path resolution.
- **Status:** FIXED@0.33.17. The source-scan guard is the durable regression lock.
- **Early sibling (same class, one tool):** 0.33.2 (`01b64ef`) — `dream.ts` `brainDir()` fell
  back to relative `.second-brain` while the git-bash-spawned `dream-snapshot.sh` wrote to the
  real `~/.second-brain/dreams`; created dreams were invisible to `dream_list`/`dream_status`.
  FIXED@0.33.2; 0.33.17 closed the whole class.

## 2. Dream-on-Windows chain (five stacked root causes, 0.24.6 → 0.33.12)

One user journey ("run `/second-brain:dream` on Windows") broke five different ways over about
a month; each fix exposed the next layer. Chronological:

1. **0.24.6 — backslash paths eaten by bash.** `dream_create`/`dream_accept` built script paths
   with Node `path.join` (`C:\Users\…`) and passed them to `bash`, which ate the escapes
   (`C:Users…`) → "No such file or directory". Fix: `toBashPath()` → `/c/Users/…`.
   Evidence: CHANGELOG `## 0.24.6`. FIXED@0.24.6.
2. **0.30.0 — CRLF-tainted env vars.** A trailing `\r` on `CLAUDE_PLUGIN_ROOT`/`HOME`/
   `KNOWLEDGE_DIR`/`BRAIN_DIR` made both `bash <path>` and `fs.stat` fail with a misleading
   "No such file" (the confirmed `dream_create` failure signature). Fix: `cleanEnvPath` helper
   in `path-guard.ts` applied at every env-path read. Evidence: CHANGELOG `## 0.30.0`
   (sha `03a4cc7`). FIXED@0.30.0 (+0.30.1 closed 5 missed MCP handlers falling back to an
   uncleaned HOME — silent phantom `…\r/.second-brain` writes).
3. **0.33.1 — WSL bash shadow.** With WSL installed, `exec("bash")` resolved to
   `System32\bash.exe` (WSL) via Machine-PATH; WSL mounts drives at `/mnt/c`, so the `/c/...`
   MSYS script path didn't exist → "No such file." Fix: probe `Git\bin\bash.exe` explicitly on
   win32. Evidence: CHANGELOG `## 0.33.1`, sha `05eddfc`; same class re-guarded in
   `install-extract-timer.sh` `win_bash()` (CHANGELOG 0.33.13). FIXED@0.33.1.
4. **0.33.2 — Node HOME unset** (see §1 sibling). FIXED@0.33.2.
5. **0.33.10 — GNU tar/rsync parse `C:\` as a REMOTE `host:path`.** Every Windows
   `dream_accept` fail-closed at the pre-accept backup with "Cannot connect to C: resolve
   failed" — and the real tar stderr was swallowed by `2>/dev/null`, so the script GUESSED
   "disk full / unwritable", which hid this bug for several releases (CHANGELOG `## 0.33.10`,
   sha `00a1b5c`). Fix: `cygpath -u` normalize in `dream-accept.sh` + fail-loud (report tar's
   actual stderr); behavioral test B4 feeds a real Windows-form `BRAIN_DIR` (prior sandboxes
   only used MSYS-form temp paths, so they never reproduced it). FIXED@0.33.10.
6. **0.33.12 — class closed at the root.** The Node MCP injects `BRAIN_DIR` in Windows form;
   `lib.sh` now MSYS-normalizes it ONCE at the inheritance boundary every script sources
   (`scripts/lib.sh:5-12` — the comment narrates the whole story). Also fixed
   `dream-snapshot.sh`'s `ln -sf` silent deep-copy (explicit `cp -p` on Windows).
   Evidence: CHANGELOG `## 0.33.12`; behavioral guard `tests/test-lib-brain-dir-msys.sh`.
   FIXED@0.33.12 (safe-by-construction for future tar/rsync/ln sinks).

**Encoded lesson:** any path crossing the Node↔bash boundary on Windows must be normalized AT
THE BOUNDARY (`sb_normalize_path` / `cleanEnvPath` / `toBashPath` / the lib.sh BRAIN_DIR
block), never per-consumer.

## 3. `ln -s` MSYS deep-copy — ~490MB duplicated per plugin version (0.33.7)

- **Symptom:** plugin cache grew to multiple GB (3.1GB observed); each upgrade left a full
  ~490MB copy of the native vector deps (onnxruntime-node, sharp, @huggingface/transformers).
- **Root cause:** on git-bash/MSYS, `ln -s` silently DEEP-COPIES the target (winsymlinks
  default) instead of linking. `install-vector-deps.sh` "linked" each version's
  `mcp/node_modules` at the shared tree — actually copying it every time.
- **Why tests missed it:** the upgrade test's OS gate probed bare `ln -s`, found no real
  symlink, and silently SKIPPED the whole suite on Windows — the skip hid the bug (CHANGELOG
  `## 0.33.7`). Prototype of the "capability-gated test silently skips on exactly the platform
  with the bug" class.
- **Fix:** `link_version()` creates a Windows directory JUNCTION via
  `node fs.symlinkSync(target, link, "junction")` (no admin privilege needed); POSIX keeps
  `ln -s`. Test probes the real junction mechanism + a structural guard on Linux/macOS CI
  against reverting to a deep-copying `ln -s`.
- **Evidence:** CHANGELOG `## 0.33.7`; sha `83772c2`.
- **Status:** FIXED@0.33.7. Reclaiming existing duplication required manual pruning of stale
  cache versions.
- **Prehistory (why shared vector-deps exist):** 0.20.0 — per-version installs accumulated a
  4.7GB cache (~4.1GB dead dupes) on POSIX too; fixed with the shared
  `~/.second-brain/vector-deps` + symlink. 0.20.1 — the installer could DESTROY a working
  install on a failed/offline `npm install`; rewritten stage→validate→atomic-swap. 0.15.2 —
  embeddings silently vanished on EVERY plugin cache refresh (cache ships `dist/`, never
  `node_modules/`). 0.24.39 added `--relink-only` self-heal at SessionStart.

## 4. PreToolUse guard Windows fail-open class (G-HOOK-2 re-arm)

- **Symptom:** three PreToolUse security guards were silently INERT on Windows — the platform
  the plugin is developed on: `symlink-guard.sh` (credential-dir write denial),
  `persona-tool-guard.sh` (resource-scope allowlist + self-edit protection),
  `wiki-write-guard.sh` (frontmatter enforcement + tombstone auto-restore).
- **Root cause (three facets of one class — path-form mismatch):**
  - symlink-guard: `realpath` on git-bash returns `C:/Users/…` form while the credential
    prefixes derive from `$HOME` = `/c/Users/…` POSIX form → prefix compare never matches →
    allow.
  - persona-tool-guard: `case "$PATH_INPUT" in /*) …` — a `C:\…` payload matches neither `/*`
    nor `~/*`, so it was treated as CWD-RELATIVE → concatenated under the allowlisted CWD →
    silent allow (CHANGELOG 0.33.31: "a `C:\…` path used to fall through as CWD-relative →
    silent allow").
  - wiki-write-guard: the `/knowledge/wiki/` glob never matches backslash paths.
- **History:** the guards were BORN to close G-HOOK-2 of the 2026-05-28 hardening gap analysis
  (`scripts/symlink-guard.sh:4`: "Closes G-HOOK-2 …gap-analysis-2026-05-28"; shipped 0.21.0).
  The 2026-07-02 deep audit found them fail-open on Windows — the original closure never held
  on one OS. Prior partial fixes, different facets: 0.24.4 made symlink-guard fail-CLOSED when
  `realpath` is absent; 0.21.1 fixed a prefix check requiring a trailing slash that let a write
  to the exact `$HOME/.ssh` directory node pass.
- **Fix (FIXED-WT@0.33.31):** new `sb_normalize_path()` funnel in `scripts/lib.sh` (comment at
  ~line 14-29: "That form mismatch silently fail-OPENED symlink-guard / persona-tool-guard /
  wiki-write-guard"): backslash→`/`, `//?/` extended-length prefix strip, `C:/…`→`/c/…` via
  cygpath; idempotent, empty-in→empty-out. symlink-guard normalizes the payload BEFORE realpath
  and realpath's OUTPUT after (realpath re-emits `C:/` form on Windows — normalizing its OUTPUT
  is the G-HOOK-2 fix; see `scripts/symlink-guard.sh:69-71` comment). Each guard carries a
  minimal inline fallback so it stays armed even if lib.sh fails to source. Windows-form
  regression tests run on Linux/BSD CI via stubbed `cygpath`/`realpath`
  (`tests/test-normalize-path.sh`).
- **Evidence:** CHANGELOG `## 0.33.31` bullet 1; working-tree lib.sh comment (verified).
- **Status:** FIXED-WT@0.33.31. Residuals: symlink-guard's credential list
  (`$HOME/.ssh, $HOME/.gnupg, $HOME/.aws, $HOME/.config/claude` — `scripts/symlink-guard.sh:22`)
  omits `~/.claude` (the OAuth token dir) — audit medium, OPEN; other-host UNC paths pass
  through unnormalized (documented limit in the lib.sh comment).

## 5. R1 era — 169 unattended extraction timeouts / recursive-claude self-spawn (fixed 0.24.38)

The single largest operational failure. Counts verified in
`docs/specs/2026-06-10-plugin-deep-dive-findings-appendix.md` (each finding carries an
independent VERIFIER re-check paragraph).

- **Symptom:** OAuth out-of-band extraction had effectively never succeeded unattended:
  169 `ec=124` (timeout-kill) extractor spawns in `~/.second-brain/error-log.jsonl`, all from
  `extract-drain.sh`; 435MB / 557 junk `.jsonl` transcripts on an 8GB Raspberry Pi; 247 nested
  session-load log lines + 133 nested stop-extract gate lines (60%+ of error-log volume).
- **Root cause A (recursion):** the drainer's headless `claude -p` spawns re-entered the FULL
  plugin stack (SessionStart chain + MCP servers) — ~24s startup on the Pi against the 25s
  default `SB_EXTRACT_TIMEOUT` → nearly every spawn timed out; each failure burned a second
  pty-retry spawn, each leaving a 350KB–6MB junk transcript.
- **Root cause B (marker resets):** `stop-extract.sh` cleared the extraction marker on every
  Stop firing, so one session's window was re-archived 18 times into a 2.9MB, 95%-duplicate
  archive — which the drainer then fed WHOLE to the extractor, guaranteeing more timeouts.
- **Evidence:** appendix `docs/specs/2026-06-10-plugin-deep-dive-findings-appendix.md` ([HOOK-2]
  + VERIFIER: "exactly 169 'extractor-diag ec=124' lines"); plan
  `docs/plans/2026-06-10-r1-extraction-loop.md`.
- **Fix (0.24.38, sha `88df6df`):** (1) `SB_NESTED_SPAWN=1` circuit breaker — capture/context
  hooks no-op under it; exported by drainer/maintainer/quality-gate spawn sites; security
  guards deliberately do NOT honor it. (2) Session-keyed markers
  `.last-extracted-line-<slug>--<session_id>`, advancing not cleared, past-EOF clamp.
  (3) Drainer budget split: `SB_DRAIN_EXTRACT_TIMEOUT` 120s (raised to 240s in 0.31.0 after a
  Pi blew 120s → ec=124 → poison-pill) while in-hook stays 25/30s; 200KB input tail-cap
  (`SB_EXTRACT_MAX_BYTES`); sub-1KB bodies skip the LLM spawn. (4) `episodic_read` path guard
  (closed G-MCP-1, the entry point missed by 0.21.0 hardening).
- **Status:** FIXED@0.24.38 (+0.31.0 timeout raise). The recursive-claude lock ITSELF is
  inherent to in-session OAuth; 0.33.18 answered it with a deterministic capture floor rather
  than removing the lock. Observability follow-up: 0.24.46 `hook-timer.sh` latency telemetry —
  "the R1 ec=124 class becomes visible before it bites".

## 6. Automation "drifted to manual" — starvation + silent failure (0.31.0) + the ee8a74c poison-pill regression

- **Symptom:** the fully-built hands-off pipeline (extract → consolidate → auto-accept) had
  drifted to de-facto manual operation on the always-on Pi despite maxed config.
- **Root causes:** (1) `extract-drain.sh` deferred on ANY live interactive session — an
  always-on operator's 30-min timer almost always fired into a deferral (starvation); (2) the
  120s extract timeout was marginal on a Pi 5 → `ec=124` → 3 strikes → quarantine;
  (3) everything failed SOFT (`|| exit 0`, health written but never read) — the stall was
  invisible, so the operator reverted to manual.
- **Evidence:** `docs/specs/2026-06-17-restore-automation-phase1.md` ("operational starvation +
  silent failure", not missing features); CHANGELOG `## 0.31.0` (sha `fc1da08`).
- **Fix:** bounded staleness-escape (persisted defer counter `SB_DRAIN_DEFER_MAX`=6 /
  oldest-pending age `SB_DRAIN_STALE_MAX`=24h lets exactly ONE drain through); timeout
  120→240s; loud OS-aware SessionStart banner keyed on ACTUAL failure signatures; headless
  maintainer wall-clock-capped + self-heals silent deaths; ONE dream-staleness definition
  (`sb_dream_is_stale`) replacing four disagreeing ones.
- **The regression review that mattered:** the first un-starve implementation FORCED a
  `claude -p` under a held OAuth lock — which could poison-pill GOOD transcripts, the exact
  failure the original defer (commit `ee8a74c`) existed to prevent. A second, FP-aware review
  caught it after the first review missed it. The escape is GATED on `ANTHROPIC_API_KEY`
  (lock-immune curl backstop) or explicit `SB_DRAIN_DEFER_PMODE_ONLY`; pure OAuth keeps
  deferring + relies on the banner. Live comment: `scripts/extract-drain.sh:121`
  ("…POISON-PILLS good transcripts (the regression commit ee8a74c's defer…").
- **Status:** FIXED@0.31.0. Residual (audit medium, OPEN): the Backend-2 API fallback calls
  bare `timeout` — always fails on stock macOS (no `timeout` binary).

## 7. Dream lifecycle failures (0.24.22, 0.24.41)

- **0.24.22 — "the dream that nagged for 19 days" + hidden deadlock.** Ground truth: a BANNER
  bug, not lost knowledge — every dream on disk was completed AND `archived_at`-stamped, but
  `session-load.sh` keyed the nudge on `status=="completed"` alone, then `break`-ed on the
  oldest → re-fired every session. Separately, a crash mid-run stuck a dream at `running`
  FOREVER and deadlocked every future dream (the create-guard refuses while one is active).
  Fix: terminal-state guard, stale escalation (`SB_DREAM_STALE_DAYS`=7), iterate-all,
  running-reclaim after `SB_DREAM_RUN_TIMEOUT` (3h). Evidence: CHANGELOG `## 0.24.22`.
  FIXED@0.24.22.
- **0.24.41 — bwrap jail structurally impossible: 100% auto_maintain failure.** The OAuth
  systemd unit set `RestrictNamespaces=true`, which forbids bubblewrap's namespaces — the
  headless maintainer failed 100% of runs, leaving stuck-pending dreams, unnoticed for weeks
  because failures were silent. Fix: drop RestrictNamespaces (bwrap IS the containment there),
  bwrap PREFLIGHT before staging, 3-strike quarantine file
  (`~/.second-brain/.llm-maintain-quarantine`, self-clearing) surfaced at SessionStart,
  pending→failed transitions with captured stderr. Evidence: CHANGELOG `## 0.24.41`
  (sha `f43c6c3`). FIXED@0.24.41.
- **Still-OPEN dream-pipeline findings (2026-07-02 audit, medium):** FORGET archiving exists
  only as SKILL.md prose (auto_accept=all / direct MCP accept silently drop it); no retirement
  path for stale `theme-*`/`reflection-*` pages; `dream_create`'s 30s execFile timeout can kill
  snapshot mid-run leaving orphan `drm_*` dirs (no status.json); the failed-dream banner
  ignores `archived_at` and fires forever even after explicit discard;
  `graph-cluster.sh`/`wiki-redundancy.sh` swallow node crashes with `2>/dev/null + echo '[]'`;
  the FORGET MinHash gate conflates "engine available" with "engine succeeded". All OPEN.

## 8. Search-ranking corruption family (the "~10,000×" class)

- **Incident A — graph boost compounding ~10,000× (fixed 0.24.39 R2).**
  - Symptom: exact-title pages evicted below the relevance floor by hub-inflated scores;
    ranking corrupted corpus-wide.
  - Root cause: graph/related boosts computed from ALREADY-BOOSTED scores compounded
    geometrically through hub pages — "~10,000x observed live"
    (`docs/plans/2026-06-10-r2-search-serving.md`).
  - Fix: boosts computed from a FROZEN pre-boost base-score snapshot, capped at ≤1× each page's
    own base; zero-text-relevance pages can no longer ride the graph into results;
    hub-distractor eval fixture + strict recall=1.0 gate. Evidence: CHANGELOG `## 0.24.39`
    (sha `b6d2d12`).
  - Epilogue: 0.33.22 (sha `71df749`) MEASURED the surviving capped boost on the real wiki
    (96 pages / 170 edges): improved a gold page's rank in 6 cases, DEGRADED it in 6, changed
    nothing in 80 of 92 — a wash — and demoted it to opt-in (`SB_GRAPH_RANKING_BOOST=1`,
    default off). FIXED@0.24.39; boost retired@0.33.22.
- **Incident B — access-counts file corrupted by the test suite (fixed 0.24.39).** The engine
  read `access-counts.json` from a fixed live path; eval/test runs both READ live state into
  rankings and WROTE fixture slugs back — the live file contained ONLY test artifacts and was
  reset. Fix: resolve via `SB_BRAIN_DIR`/`BRAIN_DIR` (hermetic) — see the R2.2 comment in
  `mcp/src/tools/knowledge-search.ts` (~line 75). FIXED@0.24.39.
- **Incident C — access-frequency boost cut (P4b, 0.33.30, sha `6fba312`).** The per-result
  `1 + 0.1·min(count,10)` ranking multiplier was removed as the recsys "rich-get-richer" hub
  bias — "the same ~10,000× corruption class as the pre-R2.1 graph boost" (CHANGELOG 0.33.30).
  PRECISION NOTE: the literal ~10,000× number belongs to incident A; the access boost itself
  was capped at 2× but self-reinforcing. Counts still record and survive ONLY as `acc=`
  telemetry in `wiki-forget-score.sh` (P4b comment in `knowledge-search.ts` ~line 83).
  FIXED@0.33.30. Related: 0.33.25 (sha `7638c94`) removed access-count (w=0.30) + recency
  (w=0.25) from the FORGET eviction score for the same reason; `SB_FORGET_W_ACCESS`/
  `_W_RECENCY` knobs are now inert.
- **Open residuals (audit):** no regression lock against re-introducing count-into-ranking
  (medium) — OPEN; the `knowledge_search` tool description still advertises the removed
  access-frequency boost (`mcp/src/server.ts:74`, verified 2026-07-05) (low) — OPEN; recency
  boost applied AFTER RRF fusion on rank-scale scores (~19-rank override) (medium) — OPEN.

## 9. REFLECT feedback loop (introduced 0.33.28, fixed-WT 0.33.31)

- **Symptom (latent, caught by audit before mass damage):** dream REFLECT (Phase 5b, 0.33.28)
  writes `reflection-<id>` pages into normal categories (learnings/concepts). Those generated
  pages then joined the NEXT dream's clustering INPUT: a reflection joining its own cluster
  changes `member_hash`, defeating idempotence (the LLM re-reflects every dream), and when
  `reflection-<id>` sorts lexicographically first it BECOMES the cluster id — spawning
  `reflection-reflection-<id>` / `theme-reflection-<id>` page growth each run.
- **Root cause:** `graph-cluster-cli.ts`'s directory walk excluded only the `projects/` and
  `themes/` DIRS, but reflections live inside content categories — invisible to a dir-based
  skip.
- **Fix:** exclude `generated: true` frontmatter pages from clustering input
  (`mcp/src/tools/graph-cluster-cli.ts:69-76` working tree, verified — the comment narrates the
  loop); regression-locked in `tests/test-graph-cluster-shim.sh`.
- **Evidence:** CHANGELOG `## 0.33.31` bullet 3; REFLECT introduced by `056f017` (0.33.28).
- **Status:** FIXED-WT@0.33.31.

## 10. jq on Windows: CRLF emission + `jq`-without-`-c` corruption

- **Incident A — jq CRLF systemic faucet (0.30.1).** The Windows Git-Bash `jq` build emits CRLF
  in `-r` output EVEN ON CLEAN LF INPUT (jq 1.8.1 stdout is text-mode on Windows: `\n`→`\r\n`) —
  so every `$(jq -r …)` capture, pipe-to-grep, and config read was `\r`-contaminated:
  comparisons, arithmetic, `grep '^x$'`, and path building silently broke (user-visible: the
  validator built `…/\r/.claude-plugin/plugin.json`; a non-last record fails while the last one
  passes). Fix at the leverage points: `sb_config_get`/`sb_config_bool` strip `\r` (one fix
  covers every config knob — without it `auto_improve: true` read back as `"true\r"` and fell
  through to the default); 121 single-line `$(jq -r …)` captures across 29 scripts CR-stripped;
  `tests/test-jq-crlf-windows.sh` reproduces Windows jq via a stub on Linux CI. Evidence:
  CHANGELOG `## 0.30.1` (sha `063d89d`). FIXED@0.30.1 (class guard = the stub test).
- **Incident B — `jq` without `-c` shreds projects.jsonl (FIXED-WT@0.33.31).** The SessionStart
  bookkeeping rewrite pretty-printed each JSONL record across ~8 lines (audit HIGH). The MCP
  registry reader does line-by-line `JSON.parse` → returned `[]` → slug resolution, dream
  family filters, and search tiering all went BLIND — and the corruption UNDID the 0.33.0
  projects.jsonl repair every session. Fix: `jq -c` + CRLF strip + `[ -s ]` no-clobber guard
  (working tree `scripts/session-load.sh:707`, verified); membership test asserts
  one-compact-object-per-line. Evidence: CHANGELOG `## 0.33.31` bullet 5. FIXED-WT@0.33.31.

## 11. CRLF frontmatter corruption (0.28.3, 0.29.2)

- **Symptom:** a CRLF wiki page (Windows / git autocrlf / import-host) lost its whole
  frontmatter on read; WORSE, the validator saw "no frontmatter" and autofix PREPENDED a second
  block — corrupting the page further on every reindex (a compounding, self-inflicted write).
  0.29.2: the incomplete-frontmatter detector/patcher also returned no match on CRLF pages —
  broken imported pages were never flagged and never patched: un-healable by the automation,
  the exact "the plugin creates an issue you can't fix" class.
- **Fix:** `\r?\n`-tolerant fence regexes — 0.28.3 fixed `parseDoc` + the detector; 0.29.2
  swept the remaining 15 LF-only regexes across `knowledge-validate.ts` (×7),
  `graph-project.ts` (×4), `graph-cluster-cli.ts` (×2), `test-oracle.ts` (×2); write-back
  normalizes fences to LF.
- **Evidence:** CHANGELOG `## 0.28.3`, `## 0.29.2`.
- **Status:** FIXED@0.29.2 (discriminating CRLF round-trip test vs a real js-yaml oracle).

## 12. The YAML/graph corruption era (~86% of pages invalid) — 0.24.47 → 0.26.0

- **Symptom:** the wiki graph pipeline had been emitting INVALID YAML
  (`related: [[a]], [[b]]` bracketless multi-item) — ~86% of live pages affected (~125 pages
  self-healed post-fix); FORGET emitted ZERO candidates (180-day recency decay put reachable
  scores below the 0.15 floor); dangling links to deleted pages re-emitted forever; reindex was
  non-idempotent.
- **Root cause (structural):** there was NO REAL YAML PARSER anywhere — every in-tree reader
  was a tolerant regex extractor, so every test re-read broken output through the same tolerant
  regex that produced it. Masked corpus-wide.
- **Fix arc:** 0.24.47 (sha `3302cdc`, user-reported) — canonical `related: [a, b]` emitter,
  orphan-GC, dangling-link filter, 90-day FORGET window, `malformed_frontmatter` autofix.
  0.24.48 — `extractYamlValue` empty-quoted-value bug (`description: ""` → stray `"`).
  0.24.49 — THE SAME CLASS SHIPPED AGAIN in 0.24.48 (three interaction bugs made reindex
  non-idempotent on a graph-enabled wiki); root-cause gate added: js-yaml (dev-only) + a
  parse-validity property test ("projector/validator output is always valid YAML"); also
  deleted a duplicate `sb_validate_wiki` in lib.sh that SHADOWED the count-returning
  definition, killing dream-accept's convergence telemetry. 0.24.50 — dream-snapshot `cp -r`
  reset staged mtimes → dream-accept rsynced them live → the FORGET age-gate was re-armed
  corpus-wide on every accepted dream (fix `cp -rp`). 0.26.0 — `knowledge_validate` uses real
  `yaml.load()` at runtime (catches duplicate mapping keys — the regex reader had returned the
  STALE first `updated:` value, corrupting the recency boost); js-yaml became a runtime dep.
- **Evidence:** CHANGELOG `## 0.24.47`–`## 0.26.0`; test-quality stats in 0.24.50
  (CHANGELOG:1106 "506 green tests missed 14 bugs"; :1112 "An audit found 53 tautological
  tests").
- **Status:** FIXED@0.26.0 for the class (real parser + property gate). User-facing heal step
  was one `/second-brain:reindex`.
- **Related churn loop (0.29.1, sha `f62ff24`):** `sb_write_generated_page` emitted 6 of 7
  required frontmatter fields → every Stop-hook regeneration of the cost-routing state page was
  born incomplete → autofix patched it → the next regeneration stripped it again — an eternal
  autofix↔regenerate loop the user could not fix by hand. Fix: emit `tags: []`/`related: []`
  byte-identical to autofix output; tests derive the required-field set directly from
  `REQUIRED_FM_FIELDS`. FIXED@0.29.1.

## 13. run-all SKIP false-green (FIXED-WT@0.33.31) + the test-infrastructure incident family

- **run-all SKIP false-green (audit HIGH):** `tests/run-all.sh` classified a test as SKIP if
  ANY output line matched `^SKIP[:\s]` — even when the test then FAILED (exit ≠ 0). A genuine
  failure in a test with one optional skipped subtest reported ALL GREEN. Double bug: `[:\s]`
  in POSIX ERE is the literal chars `:`,`\`,`s` — it never matched a space. Worst on Windows
  (no CI lane — the local suite IS the release gate). Fix: SKIP requires exit 0 (working tree
  `tests/run-all.sh:84-93`, verified: "CRITICAL: only honor SKIP when the test also EXITED 0");
  fixture-driven `tests/test-run-all-skip-semantics.sh` (driven by `SB_RUN_ALL_TESTS_DIR`).
  Evidence: CHANGELOG `## 0.33.31` bullet 6. FIXED-WT@0.33.31.
- **Siblings in the family (each a released incident):**
  - 0.24.10 — vitest transpiles per-file, never typechecks: a real `tsc` error (the 0.24.7
    `EDGE_TYPES` zod cast) broke `npm run build` yet shipped in TWO releases through a green
    gate; fix = `test-mcp-typecheck.sh` running `tsc --noEmit`.
  - 0.24.32 (sha `d77b1b9`) — 4 tests POLLUTED THE REAL `~/.second-brain` on every suite run
    (unisolated `BRAIN_DIR`); permanent guard `tests/test-real-kb-isolation.sh`; 0.24.44 later
    forced suite-temp HOME/BRAIN_DIR/KNOWLEDGE_DIR for EVERY bash test structurally.
  - 0.24.34 — a test was location-dependent (hardcoded expected slug = checkout dir basename)
    → spurious failures from the plugin cache / CI / worktrees.
  - 0.33.15 — a TEST aborted the Linux CI suite: `OUT=$(failing-cmd); RC=$?` under
    `set -euo pipefail` aborts on bash 4/5 but NOT bash 3.2 (macOS) → macos-pass/linux-fail;
    missed locally by not checking the final `Results:` line. Lesson: run the FULL suite + CI
    gates locally before push.
  - 0.33.9 / 0.33.11 — the systemic "presence vs effect" audit: 16 gaps where tests grepped
    source/prompt files for strings but never RAN the behavior; closed with mutation-proven
    behavioral tests. Canonical example: a renamed `subagent_type` silently no-ops the dispatch
    — this ALREADY SHIPPED once as `9f2264a` and presence-greps did not catch it; class guard =
    `tests/test-subagent-dispatch-resolves.sh`.
  - 0.33.14 (sha `b3e1c53`) — Windows scheduler task NEVER created: git-bash MSYS-translated
    `schtasks`' POSIX-looking flags (`/Create` → `C:\Program Files\Git\Create`), schtasks
    rejected the command, yet the script printed "applied". Tests stubbed `schtasks`, so only a
    LIVE `--apply` caught it. Fix: `MSYS_NO_PATHCONV=1` on create+delete, fail-loud non-zero
    exit + shim rollback, stub-asserted.
  - 0.30.2 (sha `894d9a3`; offending PR #79 `2006273`) — a release shipped with NO version
    bump; green because no test asserted a release bumps the version (both manifests stale →
    the drift check agreed with itself). Fix: `tests/test-release-version-bump.sh` tripwire vs
    `origin/main` (a git fact, not a self-assertion).
- **Status:** each FIXED at its version. The class keeps recurring — treat "does the gate test
  the real capability?" as a standing review question. Open members (audit, medium):
  guard-wiring liveness covers PreToolUse only; stop-extract tests stub `claude` ignoring
  stdin/args; path-guard symlink tests skip on Windows with no Windows CI.

## 14. Silently-wrong-output wave (0.29.3, 0.29.4, 0.24.37)

All exit 0 while emitting wrong/incomplete content; found by an adversarial multi-agent audit
with EVERY finding reproduced by running the script (CHANGELOG `## 0.29.4`, sha `7f47fa7`).

- **0.29.4 #1 (highest impact):** `session-load.sh` awk RANGE `/^## X$/,/^## /` — the start
  line also matches the end pattern, collapsing each range to its header → the project keyword
  harvest was ALWAYS EMPTY → the wiki-enrichment gate never fired → **every session silently
  lost project wiki recall**. Fix: in-section flags.
- **0.29.4 #2:** `grep -c … || echo 0` → the two-line string `0\n0` (grep -c prints `0` AND
  exits 1 on zero matches) at 12 sites — broke supersede integer math and split telemetry
  bullets. Fix `|| true`. (The 2026-07-02 audit found ONE MORE instance in the status skill —
  low, OPEN.)
- **0.29.4 #3:** `wc -l` dropped a no-trailing-newline final transcript line while the marker
  advanced past it — PERMANENT loss when the Stop hook reads before the final newline flushes.
  Fix `awk 'END{print NR}'`.
- **0.29.4 #4:** `grep -vwF` stopword filter shredded hyphenated identifiers (`-w` treats a
  hyphen as a word boundary). Fix `-vxF`.
- **0.29.3 (sha `3e5ebe1`):** bash `printf '- …'` parses the leading dash as an OPTION flag —
  every Escalation/Notes bullet was dropped from the cost-router telemetry page on every
  machine; the test stayed green because the `## Escalation` HEADING itself matched
  `grep -qiE 'escalat'`. Fix: `printf --` + a structural "no `## section` may be empty" oracle.
- **0.24.37:** `cost-router-capture.sh` aggregated NOTHING since ship — `jq -r` over multi-line
  JSONL missing `-s` (slurp) made every count 0; the learning loop was inert.
- **Status:** all FIXED at their versions.

## 15. Attribution incident — setup scan filed 88 docs into the wrong project (fixed 0.33.0)

- **Symptom:** a setup deep-scan run in `claude-code-plugin` filed 88 docs into `witcherrpg`'s
  raw inbox. Evidence: `docs/specs/2026-06-18-project-scoping-model-design.md` ("**Trigger:** A
  setup deep-scan in `claude-code-plugin` filed 88 docs into `witcherrpg`'s raw inbox").
- **Root cause:** capture derived its destination from the AMBIENT active-session slug
  (`resolveActiveSlug`), independent of the `SCAN_ROOT` actually scanned — scanning repo A from
  a cwd resolving to B silently files A's docs into B. (Also: the maintainer drain stamped the
  ACTIVE project facet, never item provenance; dream mined ALL projects by default.)
- **Fix (0.33.0; merge `eeadac6`):** capture destination derives from the SCANNED RESOURCE and
  fails loud on mismatch; every raw item carries an `origin:` provenance field; the drain holds
  foreign-origin items out of the work-list; dream defaults its mining scope to the active
  project (`"all"` = explicit opt-out). Plus M3 monorepo scoping and a 3-layer projects.jsonl
  migration/collision protocol (`docs/plans/2026-06-18-scoping-phase{A,B,C}-*.md`).
- **Status:** FIXED@0.33.0. A misroute now requires cwd≠repo-root + unset `CLAUDE_PROJECT_DIR`
  + a stale pin to coincide.
- **Prequel — concurrent-session slug hijack (0.24.29 → 0.24.30):** the single global
  `~/.second-brain/.active-session-slug` pin was rewritten by every SessionStart; a concurrent
  session in another project clobbered it and hijacked this session's scoping (observed live).
  0.24.29's fix DID NOT WORK where `CLAUDE_PROJECT_DIR` is unset (inconsistently present across
  MCP spawns). Root cause of the miss, verbatim from CHANGELOG 0.24.30: all tests ran in
  sandboxes that set the var or relied on the pin; no live query against the real env ran
  before merge; a test regression was "fixed" by reverting precedence — "green tests over
  real-env correctness". 0.24.30 corrected to
  `CLAUDE_PROJECT_DIR > cwd-if-known-project > pin > cwd` with the known-project gate, verified
  LIVE. FIXED@0.24.30.
- **Sibling — episodic cross-project leak (0.24.27):** `episodic_search` (and the per-prompt
  hint on every UserPromptSubmit) searched ALL projects, injecting other projects' session
  memory into every prompt — a context-rot correctness bug, not just wasted budget.
  FIXED@0.24.27 (active-scope default + broaden-when-thin).

## 16. MCP server failed to start for EVERY installed user (0.24.35, supersedes 0.24.5)

- **Symptom:** `✘ Failed to connect` for the knowledge-base MCP from any real project dir; the
  server started ONLY when cwd == the plugin dir. Reproduced live on Linux AND macOS.
- **Root cause:** 0.24.5 changed the manifest server path to `${CLAUDE_PLUGIN_ROOT:-.}` to
  silence a project-context warning — but Claude Code substitutes ONLY the bare
  `${CLAUDE_PLUGIN_ROOT}` token in MCP args, NOT the shell `${VAR:-default}` form, so the path
  collapsed to cwd-relative `./mcp/dist/server.bundle.js`. Per the CHANGELOG: "it traded a
  loud, correct failure for a silent, cwd-dependent one." The 0.24.5 validator guard had
  REQUIRED the broken form and was INVERTED.
- **Fix (0.24.35, sha `7c5e162`):** revert to bare `${CLAUDE_PLUGIN_ROOT}`; relocate the
  manifest to `.claude-plugin/mcp.json` wired via `plugin.json "mcpServers"` so it loads only
  in plugin context; `validate-plugin.sh` now FAILS on the `:-` form, on a root `.mcp.json`,
  and on missing `mcpServers` wiring.
- **Evidence:** CHANGELOG `## 0.24.35` + the superseded-marker on `## 0.24.5`.
- **Status:** FIXED@0.24.35. Residual operational gotcha: a repo-root `.mcp.json` still fails
  as a PROJECT MCP server (`${CLAUDE_PLUGIN_ROOT}` unexpanded there) — disable via
  settings.local.json; don't edit the path.

## 17. Release/process incidents

- **0.30.2 unversioned ship** — see §13.
- **`## 0.33.19` heading MISSING from CHANGELOG.md:** commit `7180966` (release 0.33.19) had
  the heading (`git show 7180966:CHANGELOG.md | grep -n "^## 0.33.19"` → line 7) but
  `grep -c "^## 0.33.19" CHANGELOG.md` → 0 today (verified 2026-07-05), and
  `git log --all --oneline -S'## 0.33.19' -- CHANGELOG.md` shows exactly two commits: `7180966`
  (added) and `616bfef` (release 0.33.20 — removed). The 0.33.19 bullets ("Self-heal couldn't
  repair a shim-less scheduler", "In-session floor didn't normalize Windows paths") now sit
  ORPHANED inside the `## 0.33.20` section (CHANGELOG.md ~lines 194-226). The migration-row
  test only checks the CURRENT version's heading, so this cannot self-heal. **OPEN** (doc
  defect; likely an accidental deletion when inserting 0.33.20).
- **`9f2264a` subagent rename shipped a silent no-op dispatch** — see §13.

## 18. awk/mawk/BSD portability class (silent no-ops on non-GNU userlands)

Six shipped incidents, one mechanism family (mawk = Debian/Pi default awk; BSD userland =
macOS):

- 0.21.4 — awk variable named `in` (reserved in gawk AND mawk) → both lint blocks emitted
  `syntax error` and SILENTLY SKIPPED, hiding broken cross-references entirely. Fix + a
  RED-on-injection meta-test. FIXED@0.21.4.
- 0.22.3 — first production dream (2026-06-02): empty `access-counts.json` → an EMPTY shell
  interpolation into `awk "BEGIN{a=$acc…}"` → mawk syntax error, degrading the FORGET access
  signal. Fix: `-v` + numeric coercion (`x=x+0`). FIXED@0.22.3.
- 0.24.17 D3 — awk `-v` runs POSIX escape-processing on its value → `C:\temp\notes` bullets had
  `\t`/`\n` rewritten → persona dedup missed → double-injection. Fix: pass via `ENVIRON[]`.
  FIXED@0.24.17.
- 0.33.18 — SAME mechanism corrupted Windows paths written to PROJECT.md (`\t`→TAB, `\W`
  dropped the backslash) in the deterministic capture floor. Fix: `ENVIRON` + forward-slash
  normalization. FIXED@0.33.18 (sha `5e470eb`).
- 0.28.2 — GNU-only regex escapes silently matched NOTHING on BSD/macOS: `sed \x1b/\x07`
  stripped no ANSI (leaked into extracted wiki content), `grep -E \b…\b` verify-gates never
  fired, `\+` a no-op. Fix + portability-scanner rule 11 (no `\b \w \s \d \xNN` inside a
  sed/grep program). FIXED@0.28.2.
- 0.29.4 — awk range collapse + `grep -w` hyphen boundary (see §14). FIXED@0.29.4.

Rules this history encodes: never interpolate shell into awk program text; pass data via
`ENVIRON[]` (not `-v`) when backslashes are possible; no GNU regex escapes in sed/grep;
`tests/test-script-portability.sh` is the accumulated static scanner for the class.

## 19. macOS bash-3.2 class

- **0.24.33 (shas `c07d202`, `6c33cb8`, `cb165f6`) — every `dream_accept` broken on macOS:** a
  `case` statement inside `$(…)` command substitution is a LOAD-TIME parse error on bash 3.2.57
  (the pre-4.0 parser extracts the comsub body by naive paren-matching and mis-counts the `)`
  closing each case pattern) — the ENTIRE script failed to parse. Parses fine on bash 4+/Linux
  CI, which is why it shipped; reproduced live on macOS. Second sibling same release: bare
  `readlink -f` (absent on stock macOS/BSD) returned empty → a legitimate in-tree alias read as
  an escape → EVERY accept refused. Fixes: `[[ == ]]` glob replaces the case; portable
  `sb_realpath` chain in lib.sh (`realpath` → `readlink -f` → `greadlink -f` → `cd && pwd -P`);
  permanent guard = `test-script-portability.sh` check 8, a depth-aware awk scanner —
  explicitly because a `bash -n` smoke on a 4+/5.x CI host CANNOT catch this class.
  FIXED@0.24.33 (follow-up `cb165f6` closed a leaf-`..` escape bypass in sb_realpath).
- **0.33.15** — bash 3.2 vs 4/5 `set -e` divergence aborted the Linux CI suite (see §13).
  FIXED@0.33.15.
- CI has run a macOS job on real bash 3.2/BSD since 0.24.44.

## 20. Security incidents & containment gaps

- **Staging→accept symlink escape (0.24.26):** the bwrap jail was spatially airtight (8 escape
  probes empirically blocked) but TEMPORALLY leaky — staged content was later mirrored to live
  by an UNJAILED `rsync -a --delete` with no `--safe-links`; a prompt-injected headless agent
  could plant `decisions/x.md → ~/.claude/.credentials.json` in staging and get a read/write
  trapdoor into the live wiki. Fix: dream-accept REFUSES the accept on any out-of-tree symlink
  in staging (in-tree relative aliases preserved) + `--safe-links` defense-in-depth; the OAuth
  cred file bind flipped `--bind`→`--ro-bind`. Documented residual: token readable + network up
  ⇒ exfil possible in ANY OAuth-headless run. Evidence: CHANGELOG `## 0.24.26`. FIXED@0.24.26;
  residual formally re-flagged OPEN by the 2026-07-02 audit ("headless lethal-trifecta run is
  default-ON but its credential-exfil risk acceptance still claims 'mitigated by opt-in'" —
  medium). The quarantine/dual-LLM + network-severing design is staged, code not landed:
  `docs/superpowers/plans/2026-06-30-p6-quarantine-dual-llm.md` (CHANGELOG 0.33.30).
- **Secret leak into the raw inbox (0.24.17 D2):** the deep-scan `SECRET_RE` anchored
  `\.pem$`/`\.key$` to the FULL path, but every scan candidate already ends in `.md`, so those
  branches were structurally unreachable — `server.key.md` (a private key wrapped in markdown)
  leaked through to the inbox. Fix: extensions match as dot-delimited components. FIXED@0.24.17.
- **episodic_read path traversal (G-MCP-1 closure, 0.24.38):** the one MCP entry point missed
  by the 0.21.0 `path-guard.ts` hardening; `episodic_read` now rejects paths outside
  `~/.second-brain/transcripts`. Evidence: CHANGELOG 0.24.38;
  `docs/plans/2026-06-10-r1-extraction-loop.md`. FIXED@0.24.38.
- **Nested-spawn write reachability (0.32.0, sha `a81151f`):** a headless `claude -p` over
  untrusted transcript content could reach all 11 destructive knowledge-base write tools
  (reachability CONFIRMED: alwaysLoad, no `--allowedTools`, env inherited). Now refused under
  `SB_NESTED_SPAWN=1`. Same release (sha `5496cad`): `knowledge_validate` defaulted
  `autofix:true` — a casual model call could DELETE pages; flipped to report-only.
  FIXED@0.32.0. (Audit low, OPEN: `knowledge_reindex` still hardcodes `autofix:true`
  internally.)
- **Invisible-Unicode ingestion (P6a/P6b, 0.33.20/0.33.21):** ASCII-smuggling channels (Unicode
  Tags block U+E0000–E007F, ZWSP/word-joiner/BOM) stripped at raw-inbox write+read (0.33.20,
  sha `616bfef`) and at transcript→dream staging + episodic read (0.33.21; canonical
  `stripInvisible` in `mcp/src/tools/sanitize.ts`). MITIGATED — bidi-control (Trojan-Source) +
  variation-selector channels explicitly deferred; audit mediums OPEN:
  `sb_strip_invisible_copy` FAILS OPEN when sanitize-cli is missing (stages unsanitized
  transcripts); retrieval paths serve wiki text verbatim with no stripInvisible.
- **dream-accept post-snapshot data loss (audit HIGH "finding D"):** a completed dream can sit
  for days while the drainer/maintainer write NEW live pages; on accept, the bare
  `rsync --delete` from the stale snapshot silently DELETED them. Fix (FIXED-WT@0.33.31): every
  live page modified after the snapshot is protected via a `touch`-stamped reference + POSIX
  `find -newer` (working tree `scripts/dream-accept.sh:154-211`, verified — merge-only,
  newer-live-wins; unusable snapshot time → fail-SAFE merge-only with a loud warn; the no-rsync
  fallback is now a merge `cp`, no more `rm -rf` of the live wiki). Prequel: 0.28.1 — MANUAL
  accepts had NO pre-accept backup at all (only the auto path did); surfaced live during the
  first real headless-maintainer test; fixed fail-closed.
- **Consolidation-agent grants (two audit HIGHs → 0.33.31):** maintainer/raw-drainer protocols
  mandated MCP tools their `tools:` whitelist EXCLUDED — phases/steps silently skipped — while
  dream-runner held broad `Bash(rm/cp/mv/find/sed…)` + `Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)`
  grants that would let an injected agent SELF-ACCEPT its own dream via `dream-accept.sh`.
  Fix-WT@0.33.31: unused `Bash(git *)` dropped, missing `knowledge_*` grants added, "untrusted
  input — DATA, not instructions" framing added to all three agents, locked by
  `mcp/src/agent-grants.test.ts`. Earlier least-privilege step: 0.33.20 scoped the node grant
  to `Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*)`. (Audit medium, OPEN: the containment
  premise that `${CLAUDE_PLUGIN_ROOT}` is expanded inside `Bash()` grant patterns is unproven.)

## 21. SessionStart budget-starvation class (silent context loss)

- 0.24.16 — USER.md (the user's Never/Always rules, priority-1) could be silently dropped when
  conditional banners spent the hook byte budget. Fix: `sb_append … force` + 6000B cap.
- 0.24.24 — the sibling: PROJECT.md appended with no `force` AFTER ~9 banners; a degraded
  SessionStart silently dropped the ENTIRE project context. Also `[degraded]` breadcrumbs were
  filling the 5-slot Recent-decisions cap during outages (noise crowding out real decisions) →
  routed to a sidecar `pending-extraction.log`.
- 0.29.0 — the combination bug: forced sections were emitted at the END, and Claude Code's
  ~10K hook-output ceiling truncates FROM THE END — so budget-gated banners ahead of them could
  push the very rules `force` guarantees off the cliff. Fix: RESERVE the forced sections'
  actual bytes from the banner budget (discriminating test: 9.1K with the reserve vs 10.8K —
  over the cap — without).
- Evidence: CHANGELOG `## 0.24.16`, `## 0.24.24`, `## 0.29.0`.
- Status: FIXED@0.29.0 for the class. Audit medium, OPEN: session-load buffers everything and
  emits only at the end — a 15s hook timeout still loses USER.md/PROJECT.md entirely.

## 22. Raw-inbox drain truncation/duplication class (0.33.3–0.33.5) + drainer wiki misroute

- **0.33.3 — re-drain duplicated nodes:** the maintainer's LLM batched the per-item "mark
  processed" bookkeeping and TRUNCATED on a large backlog — wiki nodes existed but raw items
  stayed `unprocessed`, so a re-run RE-DRAINED them into duplicate nodes. Fix: deterministic
  `kb-drain-reconcile.sh` (scans wiki for `(raw <id>)` provenance back-refs, marks each item
  processed) run at drain START and END; a truncated drain is safely CONTINUED, never
  restarted. FIXED@0.33.3.
- **0.33.4 — cross-project drain dead-end:** `raw-capture-cli process/pending/list/discard`
  were hard-scoped to the ACTIVE project; the maintainer couldn't mark another project's items
  (it hand-edited files as a workaround). Found live-draining another project's inbox. Fix:
  `--slug <project>` flag, passed explicitly by the drain. FIXED@0.33.4.
- **0.33.5 — whole-drain truncation:** one maintainer context drained ~1-3 items before
  exhausting its output budget. Fix: lean `agents/raw-drainer.md` batch worker
  (`SB_DRAIN_BATCH`=5), re-dispatched in a FRESH context per batch until
  `DRAINED: 0`/`REMAINING: 0` (30-iteration fail-loud cap). FIXED@0.33.5.
- **Drainer wiki misroute:** the drainer can write pages into the legacy `~/.second-brain/wiki`
  (INVISIBLE to search — retrieval is scoped to `~/knowledge/wiki/`) instead of
  `~/knowledge/wiki`. Mitigation in place: the dispatch prompt pins the absolute destination
  (`agents/raw-drainer.md:136`, verified: Write `~/knowledge/wiki/<type>/<kebab-slug>.md`);
  operator verify step after drains: `find ~/.second-brain/wiki -name '*.md'` should return
  nothing, then reindex. Audit medium, OPEN: `test-raw-drainer.sh` never pins the drain
  DESTINATION, so the class has no regression lock; related open tension: agent write
  instructions hard-code `~/knowledge/wiki`, ignoring the `knowledge_dir` plugin option.
  **MITIGATED / regression-lock OPEN.**

## 23. Transcript-archive eviction destroying undrained captures (FIXED-WT@0.33.31)

- **Symptom/root cause (audit HIGH):** `sb_prune_transcripts` enforced the 100-file/5MB cap in
  LEXICAL filename order — but archives are named `${session_id}_${slug}_${date}.txt`; the
  random UUID leads, so eviction order was age-RANDOM: the cap could evict a just-archived,
  NOT-YET-DRAINED transcript, silently breaking the "the transcript is still archived; the
  drainer mines the real knowledge later" recovery contract that R1/0.33.18 depend on.
- **Fix:** evict by MTIME (GNU `find -printf '%T@'`, BSD stat fallback) — working tree
  `scripts/lib.sh:908-909` ("Deletes oldest files first, ranked by MTIME … NOT by filename",
  verified); adversarial UUID-ordering test.
- **Evidence:** CHANGELOG `## 0.33.31` bullet 4. FIXED-WT@0.33.31.

## 23b. 0.33.31 shipped RED on Linux CI: exec bits invisible to every Windows-local gate (FIXED@0.33.32)

- **Symptom:** the 0.33.31 release commit (e9dfbd1) passed EVERY local gate (tsc, vitest,
  bundle-current, full run-all 149/0, validate-plugin, tripwire, portability) and the macOS CI
  lane — then failed the Linux full-suite lane at `test-exec-bits`.
- **Root cause:** the two NEW test files were committed `100644`. Authored on Windows/git-bash,
  where the filesystem FAKES the exec bit (`[ -x ]` is true for everything), so even
  `test-exec-bits` — the guard built for exactly this — passed locally. On the Linux checkout
  they land non-executable and the guard fails the suite. The macOS lane stayed green because
  it runs only its 4 fixed tests. Newest instance of the "Windows-local gates cannot see
  Linux-only red" class (see §16, §22).
- **Triage method (reusable):** CI job logs need auth; the failure was isolated by full-suite
  reproduction on REAL Linux — WSL + userland node 22 (`/tmp` tarball) + static jq. Of 5 WSL
  failures, 4 were WSL artifacts (Windows-platform esbuild binaries under `mcp/node_modules`,
  missing `python3`); the deterministic discriminator for the real one:
  `git ls-files --stage tests/ | grep 100644`.
- **Fix:** `git update-index --chmod=+x tests/test-normalize-path.sh tests/test-run-all-skip-semantics.sh`
  (mode-only). Shipped 0.33.32 (593e3cd), CI green 2026-07-05.
- **Prevention:** before pushing any new executable file: `git ls-files --stage <file>` must show
  `100755` — now a step in sb-validation-and-qa's add-a-shell-test checklist.
- **Evidence:** CHANGELOG `## 0.33.32`; run history: e9dfbd1 linux lane failure → 593e3cd success.

## 24. "Wired ≠ works" — the drainer that was never installed (0.24.18 → 0.33.19)

- **Symptom:** `extract-drain.sh` was BUILT in v0.13.0 but never installed or run — a prior
  wiring audit said "wired" while a live-runtime check found 0 transcripts ever drained.
- **Fix arc:** 0.24.18 (SP-A) deployed it: installer, local-LLM Backend 0, Claude fallback, and
  a capture-health SessionStart self-check explicitly named "the 'wired ≠ works' guard".
  Follow-ups: 0.24.19 — the new banner FALSE-NAGGED API-key users (read the drainer's state,
  not auth mode), and the `ANTHROPIC_BASE_URL` override the SP-A spec CLAIMED existed was
  actually hardcoded to the public host; 0.24.20 — cross-OS schedulers (launchd/schtasks);
  0.33.18 (sha `5e470eb`) — auto-install by default + self-heal, deterministic capture floor
  in-session and at the drainer's quarantine boundary; 0.33.19 (sha `7180966`) — the self-heal
  couldn't repair a SHIM-LESS scheduler: the OS registration existed but the shim had been
  GC'd, so the task exec'd a non-existent `~/.second-brain/bin/sb-extract-drain.sh` and failed
  silently every fire; the shim is now a required health signal.
- **Evidence:** CHANGELOG `## 0.24.18`, `## 0.24.19`, and the 0.33.19 entry text (currently
  orphaned under the 0.33.20 heading — see §17).
- **Status:** FIXED across 0.24.18→0.33.19. Audit medium, OPEN: the Stop hook chain is fully
  synchronous — stop-extract (45s budget) + cost-router-capture (10s) block the user at every
  turn end on slow boxes.

## 25. Persona/injection noise & regressions

- 0.32.0 (shas `98b3f20`, `d97da9d`): the persona-card was injected PER-PROMPT AND at
  SessionStart — a ~95% paraphrase of USER.md, ~330 tokens re-sent every prompt. Both
  injections removed. `persona_dismiss` had been a PHANTOM (recorded but affected nothing) —
  wired to real backoff (sha `107ce47` closed a BRAIN_DIR split-path in it). Also 0.32.0: a
  designed "machine heartbeat" was REFUTED during adversarial verification and dropped for a
  simpler timeout clamp — the design→adversarial-verify loop killing a feature pre-ship.
  FIXED@0.32.0.
- 0.24.6(b): the persona-card seed LEAKED THE PLUGIN AUTHOR'S own conventions and "senior
  engineer" identity to every fresh install as the default persona. FIXED@0.24.6.
- P1c measurement (0.33.30): the per-turn `UserPromptSubmit` injection is now ~662 B /
  ~165 tokens (slug pointers + principles, no wiki body) — CHANGELOG `## 0.33.30`.
- Audit medium, OPEN: `SB_PERSONA_GATE` is a SHARED kill switch — silencing the ambient prompt
  injection also disables the persona-tool-guard deny/ask safety layer.

## 26. Deep-audit 2026-07-02 — disposition ledger

The 11-agent deep audit (referenced in CHANGELOG `## 0.33.31`: "Deep-audit batch B — all 9
HIGH-severity findings from the 11-agent deep audit closed") produced 88 confirmed findings:
9 high / 55 medium / 24 low, across 11 areas (hooks-flow, bash-core, dream-pipeline,
mcp-search, mcp-core, skills-audit, agents-audit, flows-e2e, tests-audit, security-recheck,
platform-alignment). One finding was refuted ("audit skill's default session filter depends on
$CLAUDE_CODE_SESSION_ID, which nothing sets anywhere").

- **All 9 HIGHs → FIXED-WT@0.33.31** (each verified in the working tree; see §§4, 9, 10B, 13,
  20, 23): transcript-prune UUID order; maintainer/drainer missing MCP grants; agents'
  untrusted-content grants/framing; symlink-guard Windows fail-open; persona-tool-guard Windows
  CWD-relative; dream-accept stale-snapshot deletion; REFLECT feedback loop; projects.jsonl
  jq-without-`-c`; run-all SKIP false-green.
- **Mediums also fixed in the 0.33.31 working tree:** wiki-write-guard backslash glob;
  "data, not instructions" framing.
- **Notable still-OPEN mediums** (audit-reported; re-verify in code before relying — statuses
  drift): PROJECT.md merge has no inter-process lock (concurrent Stop-hook + drainer merges
  silently lose updates); atomic-write contract broken by cross-filesystem `mv` from mktemp;
  corrupt persona-signals.jsonl silently wipes the whole signal history; archive failure
  swallowed while the extraction marker advances (window unrecoverable); recency boost applied
  AFTER RRF on rank-scale scores; episodic vector-inference failure hard-fails with no text
  fallback, swallowed unlogged; embeddings cache written non-atomically and never pruned;
  `projectGraphToPages` rewrites user pages with plain in-place writeFile (crash truncates);
  `persona_think` can crash the whole MCP server via an unhandled stdin 'error' (EPIPE); three
  divergent `resolveKnowledgeDir` implementations with conflicting env precedence;
  raw-capture-cli fails soft (errors to STDOUT, exit 0 → contaminates the drainer's TSV
  work-list); skills direct users to uninvocable commands (/improve, /capture); dream skill
  auto-accepts live + calls `knowledge_reindex` mid-dream, contradicting its own staging story;
  setup's `## Intent` block exhausts pin_to_user's 15-line whole-file cap; stop-extract's
  second EXIT trap replaces the gate-logging trap; quality-gate PostToolUse stdout never
  reaches the model; session-load all-or-nothing on a 15s timeout; `alwaysLoad: true`
  force-loads ~20 tool schemas per session; SubagentStop self-exclusion omits raw-drainer +
  code-review-premise-reviewer; stop-verify-gate is ordering-blind and Bash-only;
  `knowledgeSearch` re-reads + re-tokenizes the whole wiki multiple times per call on the
  per-prompt hot path; no Windows CI lane; P4b regression lock missing; transcript-mined dream
  pages carry no provenance tag (blocks the planned P6 untrusted-confirm gate); symlink-guard
  omits `~/.claude`.

## 27. Chronology quick-reference (incident → version → sha/anchor)

| Incident | Version | Evidence sha / anchor |
|---|---|---|
| Hardening gap analysis; guards born (G-HOOK-2 first closure) | 0.21.0 | CHANGELOG `## 0.21.0`; scripts/symlink-guard.sh:4 |
| symlink-guard trailing-slash prefix miss | 0.21.1 | CHANGELOG `## 0.21.1` |
| lint awk `in` reserved-word silent skip | 0.21.4 | CHANGELOG `## 0.21.4` |
| First production dream: mawk empty-interp, theme slug collision | 0.22.3 | CHANGELOG `## 0.22.3` |
| graph-migrate junk edges (bash `[[ ]]` scraped as links) | 0.22.4 | CHANGELOG `## 0.22.4` |
| MCP path `${CLAUDE_PLUGIN_ROOT:-.}` broke server for all installs | 0.24.5→0.24.35 | `7c5e162` |
| Windows dream toBashPath | 0.24.6 | CHANGELOG `## 0.24.6` |
| EDGE_TYPES tsc break shipped twice; typecheck gate added | 0.24.7/8→0.24.10 | CHANGELOG `## 0.24.10` |
| Dead auto-reindex (D1), secret leak (D2), awk -v dedup (D3) | 0.24.17 | CHANGELOG `## 0.24.17` |
| Drainer never installed ("wired ≠ works") | 0.24.18 | CHANGELOG `## 0.24.18` |
| Dream 19-day nag + running-state deadlock | 0.24.22 | CHANGELOG `## 0.24.22` |
| USER.md / PROJECT.md budget starvation | 0.24.16/0.24.24 | CHANGELOG rows |
| Staging symlink escape; creds ro-bind | 0.24.26 | CHANGELOG `## 0.24.26` |
| Episodic cross-project leak | 0.24.27 | CHANGELOG `## 0.24.27` |
| Slug hijack (failed fix, then corrected live) | 0.24.29→0.24.30 | CHANGELOG `## 0.24.30` |
| Tests polluted the real KB | 0.24.32 | `d77b1b9` |
| bash-3.2 dream-accept parse + readlink -f refusals | 0.24.33 | `c07d202` `6c33cb8` `cb165f6` |
| R1 wave (169 ec=124, 18× re-archive, 435MB junk) | 0.24.38 | `88df6df`; deep-dive appendix |
| R2 hub-proof ranking (~10,000× graph boost) | 0.24.39 | `b6d2d12`; r2 plan |
| R4 bwrap RestrictNamespaces 100% failure | 0.24.41 | `f43c6c3` |
| YAML corruption era (~86% of pages) | 0.24.47→0.26.0 | `3302cdc` |
| cp -r mtime reset re-armed FORGET corpus-wide | 0.24.50 | CHANGELOG `## 0.24.50` |
| Manual dream-accept had no backup | 0.28.1 | CHANGELOG `## 0.28.1` |
| BSD regex silent no-ops (ANSI, \b gates) | 0.28.2 | CHANGELOG `## 0.28.2` |
| CRLF frontmatter double-block corruption | 0.28.3→0.29.2 | CHANGELOG rows |
| Forced-rules truncated from the END (budget reserve) | 0.29.0 | CHANGELOG `## 0.29.0` |
| Generated-page autofix↔regenerate churn loop | 0.29.1 | `f62ff24` |
| printf '- ' dropped every telemetry bullet | 0.29.3 | `3e5ebe1` |
| Silently-wrong-output wave (awk range; 0\n0; wc -l; -vwF) | 0.29.4 | `7f47fa7` |
| CRLF env-var class; cleanEnvPath | 0.30.0/0.30.1 | `03a4cc7` `063d89d` |
| Unversioned ship (PR #79) | 0.30.2 | `894d9a3`; offender `2006273` |
| Starvation + ee8a74c poison-pill regression | 0.31.0 | `fc1da08`; extract-drain.sh:121 |
| Persona per-prompt noise; phantom dismiss; nested-spawn guard; autofix default | 0.32.0 | `98b3f20` `a81151f` `5496cad` |
| Attribution incident (88 docs → wrong project) | 0.33.0 | scoping design spec; `eeadac6` |
| WSL bash shadow | 0.33.1 | `05eddfc` |
| dream HOME unset (Node side) | 0.33.2 | `01b64ef` |
| Drain truncation/duplication trilogy | 0.33.3–0.33.5 | CHANGELOG rows |
| ln -s deep-copy → junction | 0.33.7 | `83772c2` |
| tar/rsync `C:\` as remote host; swallowed stderr hid it | 0.33.10 | `00a1b5c` |
| BRAIN_DIR normalized at the lib.sh boundary | 0.33.12 | CHANGELOG `## 0.33.12` |
| schtasks task silently never created | 0.33.14 | `b3e1c53` |
| CI-only test abort (set -e bash-version divergence) | 0.33.15 | CHANGELOG `## 0.33.15` |
| HOME→CWD stray-.second-brain class closed | 0.33.17 | `aa43dcb` |
| Capture floor; awk -v path corruption | 0.33.18 | `5e470eb` |
| Shim-less scheduler self-heal gap; CHANGELOG heading later lost | 0.33.19 | `7180966`; heading removed by `616bfef` — OPEN |
| Invisible-Unicode strip (capture, then transcripts/episodic) | 0.33.20/0.33.21 | `616bfef` `4df5bf5` |
| Graph boost demoted after live measurement (wash) | 0.33.22 | `71df749` |
| FORGET drops usage/recency from the eviction score | 0.33.25 | `7638c94` |
| REFLECT introduced (loop latent) | 0.33.28 | `056f017` |
| P4b access-frequency boost cut | 0.33.30 | `6fba312` |
| Deep-audit batch B: all 9 HIGHs closed | 0.33.31 | WORKING TREE, uncommitted; CHANGELOG `## 0.33.31` |
