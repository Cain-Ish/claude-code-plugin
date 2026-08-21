You are doing a scheduled daily engineering pass on the second-brain Claude Code plugin.

REPO: `C:\Workplace\Projects\claude-code-plugin` (git-bash / POSIX sh for scripts)

Read `CONSTITUTION.md` first — it is the north star and every change is measured against it. Its
"What belongs in memory" section defines the four content classes (decisions · architecture ·
code map · session recap); any surface that serves none of them is out of scope by definition.

## Rules of engagement (non-negotiable)

1. NEVER commit to `main` and NEVER push. Work on a branch named `audit/YYYY-MM-DD`.
   Leave the branch local; end by summarising what a PR would contain.
2. **Start from a clean tree.** Run `git status --short` first. If it is not empty, STOP and
   report — do not stash, do not commit someone else's work in progress.
3. A no-op day is a SUCCESS. If you find no evidence-backed defect, say so and stop.
   Do not invent refactors, do not "tidy", do not add features nobody asked for.
4. Evidence before every claim. Never report something as fixed without pasting the command
   output that proves it.
5. Budget: at most 3 distinct changes per run, each independently revertable. Prefer one
   well-verified fix over three plausible ones.
6. **Never mutate the knowledge base.** Do not run `/second-brain:dream`, `dream_accept`,
   `/second-brain:maintain`, or any forget/archive operation. You READ `~/knowledge` and
   `~/.second-brain` as measurement data. Unattended consolidation is an open safety question
   (P6) and is not this job.

## Step 0 — Continuity (do this FIRST, it stops you repeating yesterday)

- Read `~/.second-brain/daily-audit-log.md` (create it if absent). It lives OUTSIDE the repo on
  purpose: your work happens on a throwaway `audit/` branch, so a log committed there would be
  invisible to tomorrow's run, which branches fresh from `main`.
- Read `docs/plans/2026-08-20-rethink-delivery-layer.md` — the active rethink plan, its phase
  checklist, its Scope audit, and its "known gap" sections.
- Read the last 10 entries of the audit log. Do NOT re-investigate anything already recorded as
  investigated unless you have a new reason.
- Because each day branches fresh from `main`, yesterday's fix is NOT in your tree. The log's
  "Changed:" line is the only record — read it before touching anything, or you will re-fix it.

## Step 1 — Measure the live system (never start from the code)

The central metric is the injection→read rate:

```
grep -o "gate=value-loop injected=[0-9]* read=[0-9]* prior=[0-9]* hits=[^\"]*" \
  ~/.second-brain/audit-log.jsonl | sort | uniq -c | sort -rn
```

(`audit-log.jsonl`, not `error-log.jsonl`: `sb_log_error` routes `gate=*` breadcrumbs logged with
exit code 0 to the audit channel — `scripts/lib.sh:238-240`.)

# CORRECTED — three things about this metric that will mislead you otherwise:
- The breadcrumb is emitted by `scripts/stop-extract.sh:194`, ONCE PER SESSION at the Stop hook.
  It is not per-turn. A day with few sessions moves the number barely at all.
- Use ONLY the `grep -o` extraction form above. Do NOT use `grep -c "gate=value-loop"` — the
  measurement pollutes its own channel, because `persona-tool-guard.sh` audit-logs the text of
  your grep command, which itself contains the literal string. On 2026-08-21 `grep -c` returned
  17 where the true count was 14.
- `audit-log.jsonl` carries TWO schemas: `{ts, hook, verdict, rule, target, ...}` from
  `sb_log_audit` (the vast majority) and `{timestamp, script, message, exit_code}` from
  `sb_log_error`. Any `jq` you write over that file must handle both or it silently sees nothing.

Also check: `error-log.jsonl` tail, transcripts pending vs extracted, wiki page count,
degraded-search flags, and whether the drainer scheduler actually ran.

Write down the numbers. They are the baseline for today.

## Step 2 — Research (deep, primary sources only)

Pick ONE focus area, rotating day to day; record which you chose so tomorrow picks a different
one: retrieval/ranking · capture/extraction · consolidation · hooks/guards · cross-platform
(Windows/macOS/BSD) · skills+agents quality · telemetry/observability.

For that area:

- Read the actual code in full — not summaries, not comments, not the wiki's claims about the
  code. Comments in this repo are sometimes arithmetically wrong.
- Check the relevant `sb-*` skill (sb-architecture-contract, sb-memory-systems-reference,
  sb-config-and-flags, sb-debugging-playbook, sb-change-control) for the design contract, then
  VERIFY it against the live code — the skills carry stale line numbers and stale surface lists.
  As of 2026-08-21 several also carry stale SURFACE COUNTS, dead verification one-liners, and a
  whole section on `cost-router` (removed in 0.36.0). Treat every `sb-*` claim as a hypothesis.
- If the area touches an external technique (BM25, RRF, MinHash, PageRank, memory agents), check
  current primary sources for anything that changes the tradeoff.

## Step 3 — Hunt for the repo's signature bug class

The suite is green and large, yet critical logic has shipped broken. The pattern, confirmed
repeatedly: **tests disable the thing under test.** Specifically hunt for:

- Gates/thresholds that are UNSATISFIABLE — a constant compared against a scale whose maximum is
  lower than the constant. (Real example: injection gated `score >= 0.045` while fused RRF caps
  at `2/(60+1) × 1.3 = 0.0426`, so it could never fire.)
- Constants calibrated for one corpus size / OS / auth mode that die in another.
- Tests whose FIXTURES never exercise the production path. (Real example, found 2026-08-21:
  `tests/test-subagent-capture.sh` passes with 15 cases, every one supplying a non-empty
  `agent_type` — while in production `agent_type` arrives EMPTY, the self-exclusion loop matches
  nothing, and the hook archives the parent session's own text.)
- Tests that pin an `SB_*` override or `SECOND_BRAIN_DISABLE_EMBEDDINGS` to a value making
  failure impossible. ~45% of shell tests (72/158) pin at least one override; CI disables
  embeddings in its Vitest step, so the hybrid path is never exercised there.
- Guards that fail OPEN on Windows path forms, or on an unparseable input file.
- Telemetry that has been reporting a broken value for weeks with nobody alerted.
- Hooks whose declared `timeout` in `hooks/hooks.json` is lower than their real runtime — they
  are killed every session and the failure is invisible. TIME every hook you touch.

For each candidate: prove it with a measurement against the LIVE data in `~/knowledge` and
`~/.second-brain`, not a fixture. A hypothesis without a measurement is not a finding.

## Step 4 — Fix (code first)

- Write the fix, then verify against live data, THEN add the regression lock.
- Prefer locks that are arithmetic or source-scans over behavioural fixtures — they need no
  model, run in CI's offline lane, and no env override can neuter them.
- PROVE each new lock fails on the old behaviour before you keep it. A lock that cannot go red is
  worse than no lock.
- Never disable something in a test unless another test owns that behaviour; if you do, say in a
  comment which test owns it.
- Ranking code: NEVER add a multiplicative boost after RRF fusion. That family has caused three
  separate incidents here (10,000× compounding, the P7 wash, access-frequency bias).
- Cross-platform: bash-3.2/BSD floor, `tr -d '\r'` after every `jq -r`, `jq -c` for JSONL, no
  `ln -s` for directories on MSYS (use a node junction), no native deps.
- Any change under `mcp/src` REQUIRES `cd mcp && npm run bundle` in the same commit — `mcp/dist`
  is committed because marketplace installs have no build step.
- **Scope gate:** a new skill/agent/script must serve one of the four content classes. If it does
  not, do not add it.
- Surface budget moves in BOTH directions in the same commit: a new skill/agent/script/test file
  requires bumping `.claude-plugin/surface-budget.json` up (or `validate-plugin.sh` R8 fails);
  deleting surface requires ratcheting it down.

# ADDED — the version-bump tripwire. Without this you will hit an unexplained red in Step 5:
- `tests/test-release-version-bump.sh` fails whenever the tree changes ANY shipped path
  (`mcp/src mcp/dist mcp/package.json model-ladder.json scripts hooks skills agents bin systemd
  .claude-plugin/plugin.json .claude-plugin/mcp.json`) versus `origin/main` WITHOUT bumping the
  version. `run-all.sh` globs it, so it runs every time. If you change shipped code, bump
  `.claude-plugin/plugin.json` AND keep `.claude-plugin/marketplace.json` in sync (validate-plugin
  checks them for drift). A docs-only or tests-only change needs no bump.

## Step 5 — Verify (gate on exit codes, never on log tails)

Run these from the repo root and record each EXIT CODE, not the last line:

```
cd mcp && npx tsc --noEmit
bash tests/run-all.sh            # shell suite + Vitest + bundle-drift + portability
bash scripts/validate-plugin.sh
```

`run-all.sh` globs every `tests/test-*.sh` and then runs Vitest, so it already covers the
bundle-drift (`test-bundle-current.sh`), portability (`test-script-portability.sh`) and
version-bump (`test-release-version-bump.sh`) gates. Run `cd mcp && npx vitest run` separately
only when you want an isolated Vitest exit code.

Record BOTH the FAIL list and the SKIP list BY NAME, not just the counts. A skip you cannot name
is a failure you have not looked at — and so is a fail you have not classified.

# CORRECTED — do not treat ec=124 as a defect without re-running in isolation:
`run-all.sh` uses a 120s per-test timeout (`PER_TEST_TIMEOUT`, `run-all.sh:30`). Several tests run
close to or past it on Windows, and a loaded machine pushes more of them over. Measured
2026-08-21: `test-extract-drain` 147s (52 pass / 0 fail), `test-dream-accept-guards` 72s
(14 pass / 0 fail) — both reported `ec=124` in the suite and both pass clean standalone.
On any `ec=124`, before calling it a defect, re-run that ONE test isolated:

```
env "SB_SUITE_REAL_HOME_PATH=$HOME" "HOME=$(mktemp -d)" timeout 600 bash tests/<name>.sh
```

If it passes, it is a timeout artifact — record it as such and move on. Consider running the
whole suite with `SB_RUN_ALL_TIMEOUT=300`. Do NOT spend the 3-change budget chasing this.

Known-legitimate skips on Windows without Developer Mode (real symlinks unavailable):
`test-dream-lifecycle` (subtests 5b-5i) and `test-symlink-guard` (tests 8, 9, 18).

Then re-run the Step 1 measurement and state whether the number moved. Remember it only moves at
session Stop, so a same-run re-read will usually be identical — that is expected, not a failure.

If anything is red, either fix it or revert your change. Do not hand over a red tree.

## Step 6 — Report and record

Append one entry to `~/.second-brain/daily-audit-log.md`:

```
## YYYY-MM-DD — <focus area>
Baseline:      <the Step 1 numbers>
Investigated:  <what you read, so tomorrow doesn't repeat it>
Findings:      <each with its measurement, or "none">
Changed:       <files + why, or "nothing">
Verification:  <the exit codes + the named FAIL and SKIP lists>
After:         <the Step 1 numbers again>
Open / next:   <what you would do tomorrow>
```

Commit any code changes on the `audit/YYYY-MM-DD` branch (the log itself is outside the repo).

Finish with a short summary: what changed, what it cost, what you would do next. If nothing
changed, say exactly that — it is a valid and useful outcome.

## Known state (so you do not rediscover it as a defect)

- 0.44.0 removed the `code-review-deep` and `team` skills, six agents (`quality-reviewer`, four
  `code-review-*`, `team-worker`) and `scripts/team-run.sh` — deliberately out of scope, not
  missing. The fresh-context critic role moved to `persona_think`.
- `model-ladder.json` `protocol_names` (SCOUT/DO/THINK) is now dead data, knowingly retained;
  retirement belongs to the Phase 4.3 flag audit.
- Surface budget as of 0.44.0 is exactly 17 skills / 4 agents / 53 scripts / 158 tests, and the
  live counts match. Any `sb-*` skill quoting different numbers is stale, not evidence of drift.

# ADDED — standing hypothesis for `read=0`. Do not re-derive this from scratch each day:
- `read=0` is the known baseline, but it is no longer an open MYSTERY — it is an open FIX.
  Measured 2026-08-21 across all 14 sessions since Aug 11: `injected=83, read=0, prior=0,
  hits=none`, INCLUDING the three sessions after Phase 0.1 shipped. So 0.1 fixed injection;
  nothing has yet fixed consumption. The plan's Phase-0 exit criterion is therefore UNMET.
  The leading suspects, both unverified by experiment:
    1. `scripts/persona-context.sh:380` emits `[Wiki — auto-retrieved slugs; Read in full ...]`
       followed by a bare `[[slug]]` with NO filesystem path. `Read` requires an absolute path,
       so the instruction cannot be executed as written.
    2. `knowledge_fetch` — which takes exactly a `slug` — is absent from the MCP instructions
       blurb (`mcp/src/server.ts:48`), from all 17 skills, and from every injected line.
  The telemetry counts a hit only on `knowledge_fetch(slug)` or a `Read` of `/slug.md`
  (`stop-extract.sh:161-196`), so both suspects would produce exactly the observed 0.
  `session-load.sh:610` (the code-map block) is the shape that works: content + tool name + when
  to call it. If you touch this, the wording is pinned only by `tests/test-injection-wrap.sh:37`.
- Extraction is structurally starved and this is already tracked as plan item 0.6 — do not file
  it as new. `extract-drain.sh:156` calls `sb_drain_escape_safe` FIRST, which requires
  `ANTHROPIC_API_KEY` or `SB_DRAIN_DEFER_PMODE_ONLY=1`; under OAuth-only with a live interactive
  Claude, every tick defers and both escapes are unreachable. Defer count was 47 against a max
  of 6. Note `~/.second-brain/.extract-timer-env` is 0 bytes, so exporting the key in a shell
  will NOT reach the scheduled task — the installer must be re-applied with the key present.