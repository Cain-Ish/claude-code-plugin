# P1 — Autonomous Capture Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make session knowledge capture run with **zero manual steps** on the user's OAuth/subscription setup — without depending on the in-session recursive-`claude` lock.

**Architecture:** The in-session Stop hook already archives every substantive transcript and advances an incremental marker; the *write-back* (decisions → PROJECT.md/wiki) is the part that degrades under OAuth. The out-of-band drainer (`extract-drain.sh`) already does that write-back when no interactive session is active, driven by a per-OS scheduler (`install-extract-timer.sh`: systemd/launchd/schtasks). P1 makes that scheduler the **installed-by-default, self-healing** path and adds a deterministic non-LLM fallback so *something* is always captured even when no extractor backend is reachable.

**Tech Stack:** Bash (POSIX, cross-OS), the existing `scripts/lib.sh` helpers, the per-OS schedulers, `tests/test-*.sh` (the auto-discovered suite), vitest only where TS is touched.

## Global Constraints (verbatim from spec v2 + CONSTITUTION.md)

- **Fully autonomous** — zero required user interaction.
- **Cross-platform** — must work on **macOS, Windows (git-bash/MSYS), and Linux** (+ BSD CI).
- **Fail loud over silent fallback** — route hook errors via `sb_log_error`; no `2>/dev/null` silent exits.
- **Surface-budget ratchet** — any new `tests/test-*.sh` or script bumps `docs/surface-budget.json` in the SAME commit (R8 gate); ratchet down freely.
- **Single-source resolution** — brain/knowledge dir only via `mcp/src/brain-paths.ts` (TS) / `BRAIN_DIR` env (bash); no new resolvers.
- Run the full suite locally before push (`tests/run-all.sh`); CI runs linux+macos.

---

## File Structure (decomposition)

- `scripts/install-extract-timer.sh` — MODIFY: add an idempotent `--ensure` mode (apply only if not already installed + healthy) callable from setup; no behavior change to `--apply`/`--uninstall`.
- `scripts/lib.sh` — MODIFY: add `sb_timer_installed()` + `sb_timer_health()` helpers (per-OS query), and a deterministic `sb_extract_deterministic()` fallback (no LLM).
- `scripts/stop-extract.sh` — MODIFY: when the LLM backend is unavailable, call `sb_extract_deterministic` to write a minimal real delta (files-touched + tool-derived decisions) instead of only a `[degraded]` breadcrumb.
- `skills/setup/SKILL.md` (or the setup script it calls) — MODIFY: call `install-extract-timer.sh --ensure` so the drainer is installed on first setup.
- `scripts/session-load.sh` — MODIFY: the capture-health banner becomes self-healing — if the timer is absent, attempt `--ensure` once (idempotent) and report, instead of only nagging.
- Tests: `tests/test-timer-ensure.sh` (new), `tests/test-extract-deterministic.sh` (new), extend `tests/test-stop-extract.sh`.

> Verify exact current line ranges at execution (they drift): `sb_call_extractor` lib.sh:1076; the degraded-fallback block stop-extract.sh:176-215; the capture-health banner in session-load.sh.

---

## Task 1: Deterministic non-LLM extraction fallback

Guarantees a real (if minimal) write-back even with no extractor backend — the floor that makes capture *never* fully no-op.

**Files:**
- Modify: `scripts/lib.sh` (add `sb_extract_deterministic`)
- Test: `tests/test-extract-deterministic.sh` (create)

**Interfaces:**
- Produces: `sb_extract_deterministic <transcript> <start_line> <total_line>` → prints a valid delta JSON `{"recent_decisions":[...],"open_blockers":[],"cross_refs":[],"files_touched":[...],"relations":[]}` to stdout. Derives `files_touched` from Edit/Write/MultiEdit tool_use entries (the existing jq in stop-extract.sh:185-198), and one decision bullet per distinct non-trivial user request line. Never calls an LLM. Exits 0.

- [ ] **Step 1: Write the failing test** — feed a 3-line synthetic JSONL transcript (one user msg, one assistant tool_use Write to `src/a.ts`) and assert the JSON has `files_touched` containing `src/a.ts` and a non-empty `recent_decisions`.
- [ ] **Step 2: Run it, verify FAIL** (`bash tests/test-extract-deterministic.sh`; function undefined).
- [ ] **Step 3: Implement `sb_extract_deterministic`** in lib.sh — lift the scratch-path-filtered `files_touched` jq from stop-extract.sh into a shared helper; emit a minimal decision from the first user prompt line. Reuse `sb_safe_json_array`.
- [ ] **Step 4: Run it, verify PASS.**
- [ ] **Step 5: Bump `docs/surface-budget.json` `tests` count +1; commit** (`feat(capture): deterministic non-LLM extraction fallback`).

## Task 2: stop-extract uses the deterministic fallback (not just a breadcrumb)

**Files:**
- Modify: `scripts/stop-extract.sh:176-215` (the `if [ -z "$DELTA_JSON" ]` degraded block)
- Test: extend `tests/test-stop-extract.sh`

**Interfaces:**
- Consumes: `sb_extract_deterministic` (Task 1).

- [ ] **Step 1: Write the failing test** — drive stop-extract with `SB_EXTRACTOR_MODEL` unreachable (stub the extractor to fail) on a transcript with a Write tool_use; assert PROJECT.md's Recent decisions gains a real `files touched` decision (currently it only writes the sidecar breadcrumb).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Replace the empty-delta branch** so on extractor failure it sets `DELTA_JSON=$(sb_extract_deterministic ...)` (still also logs the `[degraded]` sidecar). Keep the quality-gate pass (line 219).
- [ ] **Step 4: Run, verify PASS;** run full `mcp` vitest unaffected.
- [ ] **Step 5: Commit** (`feat(capture): write a real deterministic delta when the LLM backend is unavailable`).

## Task 3: `install-extract-timer.sh --ensure` (idempotent install-if-needed)

**Files:**
- Modify: `scripts/install-extract-timer.sh` (add `--ensure`)
- Modify: `scripts/lib.sh` (add `sb_timer_installed`, `sb_timer_health`)
- Test: `tests/test-timer-ensure.sh` (create), using `SB_INSTALL_OS_OVERRIDE` to exercise each OS branch in dry form.

**Interfaces:**
- Produces: `--ensure` → if `sb_timer_installed` is false, run the same logic as `--apply`; if true, no-op and print `already installed`. Always exit 0. `sb_timer_installed` queries per-OS (systemctl --user is-enabled / launchctl list / schtasks /Query) and returns 0/1.

- [ ] **Step 1: Write the failing test** — with `SB_INSTALL_OS_OVERRIDE=linux` and a fake `XDG_CONFIG_HOME`, assert `--ensure` creates the unit when absent and prints `already installed` on a second call (idempotent).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement** `sb_timer_installed`/`sb_timer_health` in lib.sh (per-OS, `ps`/`schtasks`/`launchctl`/`systemctl` — portable, no `/proc`), and `--ensure` in the timer script reusing the existing `--apply` body.
- [ ] **Step 4: Run, verify PASS** for each `SB_INSTALL_OS_OVERRIDE` (linux/macos/windows).
- [ ] **Step 5: Bump surface-budget `tests` +1; run `tests/test-script-portability.sh` (must PASS); commit** (`feat(capture): idempotent --ensure mode for the extraction timer`).

## Task 4: Setup installs the timer by default (autonomous)

**Files:**
- Modify: `skills/setup/SKILL.md` and/or its setup script — call `install-extract-timer.sh --ensure` once during setup.
- Test: extend the setup test if one exists, else assert via `tests/test-timer-ensure.sh` that the setup entrypoint invokes `--ensure`.

- [ ] **Step 1: Write/extend the failing test** — assert the setup path calls `install-extract-timer.sh --ensure` (grep the setup script for the call, or a behavioral stub).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Add the `--ensure` call** to setup, after `ensure-dirs`. Document in the SKILL the one host-state change (a user scheduler entry) and the `SB_DISABLE_AUTO_TIMER=1` opt-out (fail-loud if install errors).
- [ ] **Step 4: Run, verify PASS.**
- [ ] **Step 5: Commit** (`feat(capture): install the out-of-band drainer by default at setup`).

## Task 5: Self-healing capture-health banner

**Files:**
- Modify: `scripts/session-load.sh` (the OAuth capture-health banner)
- Test: extend `tests/test-drain-health-banner.sh`

- [ ] **Step 1: Write the failing test** — simulate "timer absent" and assert session-load attempts `--ensure` once and reports the result (not just the static nag).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement** — when `sb_timer_installed` is false and `SB_DISABLE_AUTO_TIMER` unset, run `--ensure` (bounded, fail-open), then banner the outcome.
- [ ] **Step 4: Run, verify PASS.**
- [ ] **Step 5: Commit** (`feat(capture): self-healing drainer install on session-load`).

## Task 6: End-to-end verification (no completion claim without evidence)

- [ ] **Step 1:** Run the FULL suite: `bash tests/run-all.sh` (must be ALL GREEN — the bash suite is slow on Windows; run in background if needed).
- [ ] **Step 2:** Run `bash scripts/validate-plugin.sh` (surface budget synced) + `bash tests/test-script-portability.sh` (cross-OS) + `bash tests/test-bundle-current.sh`.
- [ ] **Step 3:** Live proof on this machine: with no `ANTHROPIC_API_KEY`, complete a substantive session, wait for one timer fire (or run `extract-drain.sh` directly once no interactive session is active), and confirm a real decision lands in `~/.second-brain/projects/<slug>/PROJECT.md` — capture with zero manual steps.
- [ ] **Step 4:** Release: bump `.claude-plugin/plugin.json` + `marketplace.json` (lockstep), add a CHANGELOG entry, add a `skills/upgrade/migrations/<version>.md` ONLY if there is a real precondition (the timer install is one — document the opt-out). Commit as `release: <version>`.

---

## Self-review notes

- **Spec coverage (P1 line):** "out-of-band drainer as default" → Tasks 3-5; "deterministic non-LLM fallback" → Tasks 1-2; "salience write-path filter" + "per-turn incremental" are deferred to P2 and a later slice (NOT in P1 — keep P1 to the autonomy floor). Flag this scoping at execution.
- **Cross-platform:** every new bash helper uses `ps`/`schtasks`/`launchctl`/`systemctl` guarded by OS detection + `SB_INSTALL_OS_OVERRIDE`; portability test gates GNU-isms.
- **No host change without consent record:** Task 4 documents the scheduler entry + `SB_DISABLE_AUTO_TIMER` opt-out (the plugin install is the implicit consent for the autonomy the user requested).
- **Open risk:** does headless `claude -p` succeed under OAuth on macOS/Windows when idle (no `--oauth` sandbox there)? Task 6 Step 3 is the empirical check; if it fails, the deterministic fallback (Task 1-2) still guarantees non-empty capture, and the LLM enrichment waits for an API key / local model.
