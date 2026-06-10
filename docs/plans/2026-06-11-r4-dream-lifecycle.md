# R4 — Dreams and auto_maintain Run Unattended — Implementation Plan

> **For agentic workers:** Implement task-by-task following TDD. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** `auto_maintain` either completes a dream or fails LOUDLY with a captured error and a sane retry — never a silent pending. Kill the 100%-structural-failure (`RestrictNamespaces` vs bwrap), the burned weekly slot, the invisible failed/canceled states, and the inert retention GC.

**Architecture:** A cheap bwrap preflight runs BEFORE staging (no dream created, no throttle burned on structural failure). Failures re-stamp the throttle to a 24h retry horizon and increment a quarantine counter (3 strikes → stop retrying + persistent banner via the autostage scan). The headless run's stderr is captured and a non-zero exit transitions status pending→failed (tmp+mv). The autostage SessionStart scan reclaims stale pendings (runner never started) into failed and banners failed dreams. The snapshot prune treats failed/canceled as prunable (staging deleted, status.json kept for forensics). `sb-prune-archives.sh` runs unconditionally from the drainer (regenerable-only GC — `bak_ttl_days` was silently inert behind `auto_improve`).

**Versioning:** second-brain `0.24.40 → 0.24.41`, marketplace lockstep, migration row. No MCP change (server stays 2.6.9).

**Evidence:** SCRIPTS-01..05 in `docs/specs/2026-06-10-plugin-deep-dive-findings-appendix.md`. Live smoke available: stuck `drm_20260607T161658Z` (pending since 06-07) gets reclaimed by the new scan.

---

### Task 1: Branch
`git checkout -b fix/0.24.41-r4-dream-lifecycle` from updated main; commit this plan.

### Task 2: systemd reconciliation (SCRIPTS-01 root cause)
- `systemd/sb-extract-drain-oauth.service`: REMOVE `RestrictNamespaces=true`, replace with a comment: bwrap (`--unshare-pid --new-session`) IS the containment for the headless maintainer and requires namespace creation; RestrictNamespaces made auto_maintain structurally impossible (100% failure, deep-dive SCRIPTS-01). The remaining directives (NoNewPrivileges, ProtectHome=read-only + ReadWritePaths) stay.
- `systemd/sb-extract-drain.service` (API-key unit): KEEP RestrictNamespaces; add a comment that the headless maintainer and `SB_USE_BWRAP=1` extraction are namespace-blocked under this unit by design — the preflight probe (Task 3) makes that loud instead of silent.
- Static test in the new `tests/test-maintain-llm-drain.sh`: oauth unit must NOT contain `RestrictNamespaces=true`; plain unit must.

### Task 3: maintain-llm-drain failure-aware lifecycle (SCRIPTS-01/02/03)
New `tests/test-maintain-llm-drain.sh` (sandboxed HOME/BRAIN_DIR, `SB_MAINTAIN_LLM_FORCE=1`, PATH-stubbed `bwrap`/`claude`, tiny wiki for dream-snapshot):
- (a) bwrap probe FAILS (stub exits 1) → exit 0, NO dream dir created, error-log line names the probe, throttle MARK re-stamped to ~24h retry (mtime ≈ now−INT+86400, assert within tolerance), `.llm-maintain-fails` == 1.
- (b) three consecutive probe failures → `.llm-maintain-quarantine` file exists containing the error; a 4th run exits without probing (quarantined).
- (c) probe OK but headless run exits 1 with stderr "boom" → dream status.json transitions `pending → failed` with `ended_at` set and `error` containing "boom"; error-log line carries the stderr tail; fails counter incremented.
- (d) success path (probe OK, claude stub writes status completed) → MARK stamped at now, fails counter and quarantine cleared.

Implementation in `scripts/maintain-llm-drain.sh`:
- Probe before staging (after the gates, before the throttle stamp): `bwrap --ro-bind / / --unshare-pid --new-session -- /bin/true` — on failure: `sb_log_error` naming RestrictNamespaces as the likely cause, `_fail_step` (below), exit 0.
- `_fail_step()` helper: increments `$BRAIN_DIR/.llm-maintain-fails`; at ≥3 writes `$BRAIN_DIR/.llm-maintain-quarantine` (one-line error summary + date); re-stamps `$MARK` mtime to `now − INT + SB_MAINTAIN_LLM_RETRY (default 86400)` via the portable `touch -t $(date -u -d "@EPOCH" +%Y%m%d%H%M 2>/dev/null || date -u -r EPOCH +%Y%m%d%H%M)` pair.
- Quarantine gate at the top (after the auto_maintain check): `.llm-maintain-quarantine` present → exit 0 (the autostage banner names it; user clears by deleting the file or running /second-brain:maintain).
- Headless run: capture stderr to a temp file (`2>"$ERR_F"` instead of `2>&1` to /dev/null); on rc≠0: tmp+mv status.json to `failed` (`status`, `ended_at`, `error` = first 300 chars of stderr tail), `sb_log_error` with the tail, `_fail_step`. On rc=0: clear fails counter + quarantine.

### Task 4: autostage scan — reclaim + surface (SCRIPTS-02/04 visibility)
Extend `tests/test-dream-autostage.sh`:
- (e) a `pending` dream with `created_at` older than `SB_DREAM_PENDING_STALE` (default 86400s) → transitioned to `failed` (error: "runner never started — stale pending reclaimed by autostage") and the banner says "previous dream failed", not "run to resume".
- (f) a fresh `pending` → unchanged behavior (resume banner).
- (g) a `failed` dream (and no pending/running) → one banner naming the id + error tail + the hint (`/second-brain:maintain` to retry; `.llm-maintain-quarantine` to clear if present); does NOT block the threshold banner logic (failed counts as terminal for the watermark).

Implementation in `scripts/dream-autostage.sh`: in the scan loop add `failed) FAILED_ID=… FAILED_ERR=… ;;` and stale-pending detection (compare `created_at` epoch vs now; jq `-r '.created_at'` + portable date parse — store epoch via `date -u -d "$ts" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s`); transition uses the same tmp+mv discipline. Banner emission order: running > fresh-pending(resume) > newly-reclaimed/failed > threshold.

### Task 5: snapshot prune treats failed/canceled as prunable (SCRIPTS-04)
Test (extend `tests/test-dream-lifecycle.sh` or the autostage test): with keep-count exceeded, a `failed` dream's `staging/` + `transcripts/` are deleted while `status.json` is kept; `pending`/`running`/`completed-unreviewed` still never touched; `archived` still fully removed.
Implementation in `scripts/dream-snapshot.sh` prune loop: terminal = archived (full `rm -rf`, as today) OR `status` in `failed|canceled` (delete `staging/` and `transcripts/` subdirs only).

### Task 6: retention GC decoupled from auto_improve (SCRIPTS-05)
Test (extend `tests/test-extract-drain.sh`): with `auto_improve` absent/off and a fake `sb-prune-archives.sh` stub in the scripts dir... the drainer calls the REAL path — instead assert via a probe file: stub not feasible (script path fixed). Simplest honest test: create `$BRAIN_DIR/embeddings-cache-probe.bak` older than `bak_ttl_days` and a minimal config.json with `auto_improve:false`; run the drainer; assert the `.bak` is gone IF `scripts/sb-prune-archives.sh` handles it — check that script's actual targets first and assert on whichever regenerable artifact it prunes; otherwise fall back to a static assertion that the `sb-prune-archives.sh` invocation in `extract-drain.sh` is OUTSIDE the `auto_improve` gate (grep the 5 lines around it).
Implementation in `scripts/extract-drain.sh`: move/duplicate the `sb-prune-archives.sh` call out of the `auto_improve` block, unconditional, with a comment (regenerable-only GC; `bak_ttl_days` was inert for auto_improve=off users — every default install).

### Task 7: release + verification
0.24.41 lockstep (plugin.json + marketplace; cost-router stays 0.1.2) + migration row (auto_maintain now fails loudly: probe→no-dream, 24h retry, 3-strike quarantine at `.llm-maintain-quarantine`; stale pendings auto-reclaim to failed; failed/canceled staging pruned past keep-count; retention GC now always runs). Full suite + validator. **Live smoke:** run the autostage scan against the real brain dir (read-only check first: `jq .status ~/.second-brain/dreams/drm_20260607T161658Z/status.json`) — after merge+install the next session reclaims it; in-branch, run `bash scripts/dream-autostage.sh` with real BRAIN_DIR and confirm the stale pending transitions to failed with the reclaim error.

### Task 8: gate + PR + merge
Focused deep review (dream-lifecycle unit + history + premise), fix findings, push, PR, merge.

## Self-review
SCRIPTS-01 → T2+T3(probe); SCRIPTS-02 → T3(c)+T4(reclaim); SCRIPTS-03 → T3(a/b retry+quarantine); SCRIPTS-04 → T4(g surface)+T5(prune); SCRIPTS-05 → T6. Deferred to R7 per spec: `sb doctor` unification of these signals. The macOS dream-lifecycle run stays a tracked PROJECT.md deferral.
