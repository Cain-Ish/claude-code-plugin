# Post-audit improvements — what the 2026-09-05 deep audit says to change next

**Status: PROPOSED.** Source: `docs/audits/2026-09-05-deep-audit.md` (173 confirmed defects at 1d9d70a, all five gates green).
The remediation branch fixes the confirmed critical/high rows; this memo is about the *shapes* behind them.
Each item gives 2–3 options; the recommended one is marked. Nothing here is decided.

## 1. Delivery still converts ~nothing (2 reads / 117 injections, `gate=value-loop`)

The CONSTITUTION names this the product metric. Two fixes (0.1 gate, 0.8 executable hint) shipped and the number
did not move, which means the remaining suspects are the denominator and the consumer, not the ranking.

- **A. Instrument before changing anything (recommended, Phase 0.2/0.3 of the rethink plan).** persona-context.sh writes
  its per-prompt injections to the same manifest session-load uses; stop-extract records a miss reason per injected id
  (below-gate / injected-not-fetched / fetched-unused), and counts reads across the WHOLE session, not the first Stop
  window (D115-known). Cost: ~60 lines bash, no new surface. Risk: none; it only makes the zero explainable.
- **B. Delegate the hot tier to native memory now (Phase 1).** Deletes 8.8 KB/session of forced injection and the
  byte-budget machinery; the CONSTITUTION already claims this is done (D022 — it is not). Risk: loses the one surface
  that demonstrably *is* read (the code-map spine); do it after A shows what is read.
- **C. Evidence-of-need retrieval (Phase 2).** Inject only on tool-use patterns / file context. Highest upside, but
  unmeasurable until A lands.

## 2. Shared JSONL files have no single-writer discipline (D120 class, critical)

Five parallel SessionStart hooks and every PreToolUse guard append to `audit-log.jsonl` with `jq … >>`; on Windows that
loses and tears rows, and every reader then aborts. The fix on the branch (one `printf` per row, tolerant readers) closes
the observed sites. The class needs a lock, not a sweep.

- **A. Portability guard #13 (recommended):** `tests/test-script-portability.sh` fails on any `jq … >>` or multi-command
  append to a `*.jsonl` path; the only sanctioned appenders are `sb_log_audit`/`sb_log_error`/`sb_append_jsonl`.
  Cost: one grep rule + a helper. Catches every future sibling.
- **B. Per-process log shards merged at read.** Eliminates contention entirely but multiplies files and complicates
  rotation and every reader. Over-engineered for ≤4 KiB rows, which O_APPEND already makes atomic.
- **C. A lock around every append.** `flock` is absent on macOS; mkdir locks add ~10 ms per hook call × 22 hooks.

## 3. The consolidation lane runs unattended everywhere and mines the wrong data (D095, D201, D134)

Docs say bwrap gates it to Linux; code runs it on every OS under the user's OAuth, auto-accepts, and stages the 50
lexically-highest transcripts (all `sub-*`). The lethal-trifecta argument in the CONSTITUTION assumes a jail that is not
there on the platform the maintainer uses.

- **A. Fix selection, make the docs true, keep the lane (recommended, minimal).** Sort by date-in-filename; setup consent
  ladder says exactly what runs where; Stage B jail masks transcripts and credentials (`--tmpfs` + env allowlist) where
  bwrap exists. The rethink plan's non-goal ("preserving the dream lifecycle") is not reopened.
- **B. Default `auto_maintain` off on non-Linux until the V4 hands-off validation exists.** One config seed change;
  unattended token spend stops being a surprise. Combine with A.
- **C. Delete the lane (rethink plan Phase 3).** Removes the largest untrusted-input surface, but the audit shows the
  wiki write path is the part that works — deletion is not evidence-backed yet.

## 4. Green gates did not predict correctness

44% of shell tests pin an `SB_*` override; CI and local vitest both run embeddings off; run-all's SKIP rule hides
indented partial skips; two guard tests are tautological. The CONSTITUTION rule "tests must not disable the thing they
test" has no gate.

- **A. Override census lock (recommended).** A source-scan test: for every `tests/test-X.sh` that pins `SB_FOO=<value>`,
  `SB_FOO` must not be a gate read by the script under test (derive from `scripts/X.sh` greps) unless the file declares
  `# pins: SB_FOO — <why>` in its first 20 lines. Makes the exception visible and blameable, like `run-all-timeout:`.
- **B. Production-config lane in pre-push.** Re-run the injection/search tests with embeddings on and no overrides on the
  developer machine (CI cannot fetch the model). Slow (~2 min) but it is the only place the hybrid path runs.
- **C. Windows CI lane.** GitHub `windows-latest` with git-bash covers the primary dev platform's path forms; the
  suite takes ~28 min there, so run only the guard/normalize/log tests.

## 5. Registry and code-map hygiene (D039, D118, D121)

HOME and Temp are registered projects; brain-os code-maps the whole profile every tick; the drainer sanitizes slugs no
other funnel sanitizes.

- **A. Registration guard (recommended):** refuse to register a root that is `$HOME`, a temp root, or has no `.git`
  and no workspace manifest; one-time purge of the 8 junk rows with a migration note. Code-map only git roots.
- **B. Keep registration open, cap the walk.** Cheaper but keeps injecting browser-extension paths as the "spine".

## 6. Prose promises without locks

README "every guard has an SB_* kill switch", "plan-first is soft", "Linux-only unattended", CONSTITUTION "hot tier
delegated to native memory", "single-source resolution" (bash side unscanned), "least-privilege agents".

- **A. Fix the prose to match the code now (on the branch), then add the cheap locks:** kill-switch claim → a test that
  every guard script reads its named `SB_*`; single-source → extend the source scan to `scripts/*.sh`; least-privilege →
  `agent-grants.test.ts` asserts no unscoped `Write`/`rm *` in dream-runner.
- **B. Move unlocked promises to a "direction" section.** Honest but hides real gaps.

## 7. The audit loop itself is too expensive

This audit spent ~11M tokens; ~80% went to fifteen full-file readers on the top model and three-vote verification.
Same coverage is reachable for a fraction:

- Readers on a mid-tier model with file-scoped briefs; one strong-model verifier only for critical/high; batched
  skeptics for low. (This is how the remediation is being run.)
- Class-sweeps instead of re-reads: once a class is confirmed, a grep-driven sibling sweep is deterministic and free.
- Fold the sibling list and the "uncited files" list into `docs/daily-prompt.md` so the daily pass works the backlog
  instead of rediscovering it.
