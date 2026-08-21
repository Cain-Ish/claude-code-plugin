# Daily engineering pass — second-brain plugin

> **Scheduler entry point.** The Claude Desktop / scheduled task should NOT carry a copy of these
> instructions. It should carry only the short launcher in "Scheduler entry point" below, which
> tells the run to read THIS file. That keeps one version-controlled source of truth: the
> scheduler and any review session both correct the same file, and a fix lands for every future
> run instead of only the next one.
>
> Caveat that bit us on 2026-08-21: a run branches from `main`, so **edits to this file only take
> effect once the PR that carries them is merged to `main`.** A correction sitting on an open PR
> is invisible to tomorrow's run — that is expected, not a bug. Correct this file anyway; it
> lands with the same PR as the rest of the day's work.

## Scheduler entry point

Paste exactly this into the scheduled task; nothing else:

```
Daily engineering pass on the second-brain Claude Code plugin.

Repo: C:\Workplace\Projects\claude-code-plugin   (use git-bash / POSIX sh for all scripts)

Do exactly this, in order:

1. Run `git status --short` in the repo. If it is not empty, STOP and report — do not stash,
   do not commit work in progress.
2. Run `git switch main` then `git fetch origin --quiet` then `git merge --ff-only origin/main`.
   If the merge is not a fast-forward, STOP and report — local main has diverged.
3. Read C:\Workplace\Projects\claude-code-plugin\docs\daily-prompt.md IN FULL, before creating
   any branch.
4. Follow that file exactly. It is the complete, authoritative instruction set for this run and
   the single source of truth. Do not substitute remembered instructions from a previous run,
   and do not skip anything it marks non-negotiable.

Keep the file's contents in context for the whole run: the pass creates its own branch and the
file may not exist on the branch you end up on.

The run is expected to measure the live system, research one focus area, hunt for the repo's
signature bug class, make at most 3 evidence-backed changes on an `audit/YYYY-MM-DD` branch,
improve docs/daily-prompt.md itself, open a PR against main, and leave the working tree back on
main. Never push to main. Never merge your own PR.

If docs/daily-prompt.md cannot be read, recover it with:
  git -C C:/Workplace/Projects/claude-code-plugin show origin/main:docs/daily-prompt.md
If that also fails, STOP and report it. Do not improvise a pass from memory.
```

---

You are doing a scheduled daily engineering pass on the second-brain Claude Code plugin.

REPO: `C:\Workplace\Projects\claude-code-plugin` (git-bash / POSIX sh for scripts)

Read `CONSTITUTION.md` first — it is the north star and every change is measured against it. Its
"What belongs in memory" section defines the four content classes (decisions · architecture ·
code map · session recap); any surface that serves none of them is out of scope by definition.

## Step -1 — Environment preflight (do this BEFORE anything else)

This pass is built on measuring the LIVE system. Two directories outside the repo carry that data:

| Path | Needed by |
|---|---|
| `$BRAIN` (default `~/.second-brain/`) | Step 0 (continuity log), Step 1 (all metrics), Step 6 (writing the log) |
| `$KNOW` (default `~/knowledge/`) | Step 1 (wiki counts), Step 3 (proving findings against live data) |

Both roots are CONFIGURABLE — resolve them before classifying anything. `mcp/src/brain-paths.ts`
honours `SB_BRAIN_DIR` / `BRAIN_DIR` for the first and
`CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` / `KNOWLEDGE_DIR` for the second. A healthy install using
those supported overrides has neither default path, and treating that as "missing" drops you into
REPO-ONLY MODE and then reads the wrong directories for the rest of the run.

```
BRAIN=${SB_BRAIN_DIR:-${BRAIN_DIR:-$HOME/.second-brain}}
KNOW=${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}
ls -d "$BRAIN" "$KNOW" 2>&1
```

Use `$BRAIN` / `$KNOW` — not the literal `~/…` paths — everywhere below, and record which values
resolved in your report.

**If BOTH are present** — run the full pass as written below.

**If either is MISSING** (e.g. a sandboxed session that mounts only the repo) — you are in
**REPO-ONLY MODE**. Do not silently carry yesterday's numbers forward as if you measured them.
In repo-only mode:

- Record Step 1 as `LIVE MEASUREMENT UNAVAILABLE — <which path was missing>`. Never present a
  carried-forward number as a fresh measurement.
- Restrict the Step 2 focus area to one that is fully verifiable from the repo alone:
  **skills+agents quality**, **cross-platform**, or **doc/claim truth**. Do NOT pick
  retrieval/ranking, capture/extraction, consolidation, or telemetry — every finding in those
  areas needs live data, and a "finding" without a measurement is exactly what Step 3 forbids.
- Skip Step 6's append; emit the log entry verbatim in your final message so a human can paste it.
- Still branch from `main`, still open the PR, still return to `main` (Step 6). If the remote or
  `gh` is unreachable, leave the branch local, say so explicitly, and paste the exact
  `git push` + `gh pr create` commands a human should run.
- Step 7 (improve this prompt) still applies — it needs no live data.
- Say so in the first line of your report. An unmeasured pass reported as a measured one is worse
  than no pass.

Ask for the mounts to be added if you are running under a sandbox that supports it — Step 1 is
the spine of this job and repo-only mode is a degraded fallback, not the normal path.

## Rules of engagement (non-negotiable)

1. **Branch from `main`, deliver as a PR, end on `main`.** Never commit to `main` and never push
   to `main` directly. Work on `audit/YYYY-MM-DD`, based on `origin/main`. If the run produces
   changes, push that branch and open a PR (Step 6). Then return the working tree to `main`.
   Never merge your own PR — a human reviews it.
2. **Start from a clean tree.** Run `git status --short` first. If it is not empty, STOP and
   report — do not stash, do not commit someone else's work in progress.
3. A no-op day is a SUCCESS. If you find no evidence-backed defect, say so — and stop ONLY if
   you also have no rung-2 lock and no rung-3 measurement to deliver (Step 4).
   Do not invent refactors, do not "tidy", do not add features nobody asked for.
   **"Tidy" does NOT cover deleting a dead reference.** A line that points at a file, flag,
   skill, agent or command that no longer exists is a FALSE CLAIM, not untidiness — removing
   or rewriting it is a rung-1 defect fix and is always in scope. Prove the surface is gone
   (`ls`, `git log --diff-filter=D -1 -- <path>`) before deleting anything.
   "No defect found" does not mean "nothing to deliver" — see Step 4's ladder: a measurement
   that closes an open question, or a lock on an unguarded invariant, is a real deliverable and
   is how the codebase gets better on days when nothing is broken.
4. Evidence before every claim. Never report something as fixed without pasting the command
   output that proves it.
5. Budget: at most 3 distinct changes per run, each independently revertable. Prefer one
   well-verified fix over three plausible ones.
6. **Never mutate the knowledge base.** Do not run `/second-brain:dream`, `dream_accept`,
   `/second-brain:maintain`, or any forget/archive operation. You READ `$KNOW` and
   `$BRAIN` as measurement data. Unattended consolidation is an open safety question
   (P6) and is not this job.

## Step 0 — Continuity and branch base (do this FIRST)

- **Full mode only:** read `$BRAIN/daily-audit-log.md` (create it if absent). It lives OUTSIDE the
  repo on purpose: your work goes to a PR that may sit in review for days, so a log committed there
  would be invisible to tomorrow's run — which branches from `main`. In REPO-ONLY MODE `$BRAIN`
  does not exist: do NOT create it — skip this bullet and the "last 10 entries" read below, and say
  in your report that you ran without continuity history.
- Read `docs/plans/2026-08-20-rethink-delivery-layer.md` — the active rethink plan, its phase
  checklist, its Scope audit, and its "known gap" sections.
- Read the last 10 entries of the audit log. Do NOT re-investigate anything already recorded as
  investigated unless you have a new reason. The log's "Changed:" line is the only record of
  yesterday's work — read it before touching anything, or you will re-fix it.

**Create today's branch from `main`.** Always. One run = one branch = one PR, so every run starts
from the same known base and each day's work is reviewable in isolation:

```
git status --short                  # must be empty; if not, STOP (Rule 2)
git fetch origin --quiet
git switch -c audit/$(date +%F) origin/main
```

**Then read the open PRs before you investigate anything** — yesterday's fix is usually still in
review, so it is NOT in your tree, and re-finding it wastes the whole run:

```
gh pr list --state open --json number,headRefName,title,body,updatedAt
```

- For every open PR whose head is an `audit/*` branch, read its body. It is a description of work
  already done. Treat everything it fixes as ALREADY FIXED and out of scope for today.
- `git diff origin/main...origin/<that-branch>` shows exactly what it touched. Do not re-fix, and
  do not "improve" those same lines — you will conflict with a PR under review.
- If an open audit PR is stale (red, or superseded), say so in the report so a human can close
  it. Do not merge it, do not rebase it, do not push to it.
- **Record in the log** which open PRs you excluded and why. This is the only mechanism that
  stops N consecutive runs from producing N PRs that all fix the same thing.

## Step 1 — Measure the live system (never start from the code)

The central metric is the injection→read rate:

```
grep -o "gate=value-loop injected=[0-9]* read=[0-9]* prior=[0-9]* hits=[^\"]*" \
  "$BRAIN"/audit-log.jsonl | sort | uniq -c | sort -rn
```

(`audit-log.jsonl`, not `error-log.jsonl`: `sb_log_error` routes `gate=*` breadcrumbs logged with
exit code 0 to the audit channel — `scripts/lib.sh:238-240`.)

Three things about this metric that will mislead you otherwise:

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

### Hot-path latency (measure this EVERY run)

Performance is a first-class requirement, so it gets measured like any other metric — never
asserted from memory. These scripts run on every tool call / every prompt; regressions here are
felt by the user immediately and no test will catch them.

```
PRE='{"session_id":"perf","transcript_path":"/tmp/none.jsonl","cwd":"'"$PWD"'",
"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$PWD"'/README.md"}}'
for s in persona-tool-guard wiki-write-guard symlink-guard flow-guard plan-first-nudge; do
  S=$(date +%s%N); printf '%s' "$PRE" | bash scripts/$s.sh >/dev/null 2>&1; E=$(date +%s%N)
  printf '%-22s %5dms
' "$s" $(( (E-S)/1000000 ))
done
```

Repeat with a `PostToolUse` payload for `quality-gate`, `tool-return-scanner`, `observe-tool-use`,
`simplicity-gate`, and a `UserPromptSubmit` payload for `persona-context`.

Rules for reading the result:
- Run it on an OTHERWISE IDLE box. A measurement taken while the test suite is running is an
  upper bound, not a number — say which you took, or it is not evidence.
- Sum the PreToolUse + PostToolUse chains: that total is paid on EVERY tool call. Compare against
  the previous run's figure in the audit log, not against a number written in this file.
- Process spawn is the dominant cost on Windows/MSYS (~60ms per `bash`, ~75ms per `jq`, ~130ms per
  `node`, measured 2026-08-21 under load). A script that shells out in a loop pays that tax per
  iteration — prefer one `jq`/`awk` pass over N.

## Step 2 — Research (deep, primary sources only)

Pick ONE focus area, rotating day to day; record which you chose so tomorrow picks a different
one: retrieval/ranking · capture/extraction · consolidation · hooks/guards · cross-platform
(Windows/macOS/BSD) · skills+agents quality · telemetry/observability · **performance**.
(In REPO-ONLY MODE, see Step -1 for the restricted set.)

For that area:

- Read the actual code in full — not summaries, not comments, not the wiki's claims about the
  code. Comments in this repo are sometimes arithmetically wrong.
- Check the relevant `sb-*` skill for the design contract, then VERIFY it against the live code.
  Those skills are the model's own orientation layer and they drift: as of 2026-08-21 a pass
  found 54 lines across 14 files presenting removed surfaces as current. That class is now locked
  by `tests/test-devdocs-stale-surface.sh`, but LINE NUMBERS and counts inside them are still
  unguarded. Treat every `sb-*` claim as a hypothesis.
- If the area touches an external technique (BM25, RRF, MinHash, PageRank, memory agents), check
  current primary sources for anything that changes the tradeoff.

## Step 3 — Hunt for the repo's signature bug class

The suite is green and large, yet critical logic has shipped broken. The pattern, confirmed
repeatedly: **tests disable the thing under test.** Specifically hunt for:

- Gates/thresholds that are UNSATISFIABLE — a constant compared against a scale whose maximum is
  lower than the constant. (Real example: injection gated `score >= 0.045` while fused RRF caps
  at `2/(60+1) × 1.3 = 0.0426`, so it could never fire.)
- Constants calibrated for one corpus size / OS / auth mode that die in another.
- Tests whose FIXTURES never exercise the production path. (Real example, 2026-08-21:
  `tests/test-subagent-capture.sh` passed with 15 cases, every one supplying a non-empty
  `agent_type` — while in production `agent_type` arrives EMPTY, the self-exclusion loop matched
  nothing, and the hook archived the parent session's own text.)
- Tests that pass for the WRONG REASON — the fixture never reaches the branch under test. Same
  day: a Windows-path guard test passed with the fix deleted, because the fake path did not exist
  on disk and the hook exited at an earlier `[ -f ]` check. If a test cannot be made to go RED,
  it is not a test. Prefer a source scan when a behavioural fixture cannot reach the branch.
- Tests that pin an `SB_*` override or `SECOND_BRAIN_DISABLE_EMBEDDINGS` to a value making
  failure impossible. ~45% of shell tests pin at least one override; CI disables embeddings in
  its Vitest step, so the hybrid path is never exercised there.
- Guards that fail OPEN on Windows path forms, or on an unparseable input file.
- Telemetry that has been reporting a broken value for weeks with nobody alerted.
- Hooks whose declared `timeout` in `hooks/hooks.json` is lower than their real runtime — they
  are killed every session and the failure is invisible. TIME every hook you touch.
- **Unbudgeted latency on a hot path.** Performance is a REQUIREMENT here, not a nice-to-have:
  every `PreToolUse`/`PostToolUse` script runs on EVERY tool call and `UserPromptSubmit` runs on
  EVERY prompt, so a 300ms script is a 300ms tax on every action the user takes. As of
  2026-08-21 the suite has NO latency budget at all — `tests/test-hook-latency.sh` only asserts
  `duration_ms < 60000`, which is a hang check, not a budget — and 9 scripts sit on the
  per-tool-call path (5 PreToolUse + 4 PostToolUse). A script that got slower is a defect even
  when every test is green. Measure before and after with the Step 1 recipe.
- A doc/prose count that no test compares against its source of truth.

For each candidate: prove it with a measurement, not a fixture. A hypothesis without a measurement
is not a finding.

- **Full mode** — the measurement runs against the LIVE data in `$KNOW` and `$BRAIN`.
- **REPO-ONLY MODE** — live data is unavailable by definition, so the measurement runs against the
  repo alone: a command over the working tree whose output you paste (a source scan, a count
  compared to its source of truth, a test run RED then GREEN). That is a real measurement and a
  real finding. What is still forbidden is asserting a claim with no command output at all, or
  presenting a repo-derived number as a live one. Restrict candidates to the areas Step -1 allows.

## Step 4 — Fix (code first)

**What to deliver, in priority order.** Take the highest rung you have evidence for; do not climb
down to a lower rung while a higher one is available, and never climb UP into invention:

1. **A defect fix** — you proved something is broken against live data. Fix it, lock it.
2. **A lock on an unguarded invariant** — nothing is broken today, but a load-bearing claim has
   no machine check and could silently rot (a prose count with no source-of-truth comparison, a
   threshold with no arithmetic guard, a hook timeout nobody times). Prefer the invariants this
   pass has already had to re-verify by hand: if you checked it manually, that is evidence the
   check should be automated.
3. **A measurement that closes an open question** — you cannot fix it today, but you can make the
   next run start from a fact instead of a hypothesis. Record the number and the command that
   produced it. This is a legitimate deliverable even with zero code changed.
4. **Nothing.** Say so plainly. Do not manufacture rung 1 out of rung 4.

**Deleting beats annotating.** When you find a doc or code reference to a removed surface,
the default fix is to DELETE or rewrite the claim. Only add a "removed/historical" marker when
the line is genuinely about the past (a chronicle entry, an incident write-up). Sprinkling
markers to silence a guard hollows the guard out: it goes green while the false claims remain,
and the next run reads that green as "nothing stale left".

Rungs 2 and 3 are how the codebase gets better on days with no defect. They are also the only
sanctioned way to spend the budget when Step 3 comes up empty — they are not refactors, they add
no surface the four content classes do not already cover, and each is independently revertable.

- Write the fix, then verify against live data, THEN add the regression lock.
- Prefer locks that are arithmetic or source-scans over behavioural fixtures — they need no
  model, run in CI's offline lane, and no env override can neuter them.
- PROVE each new lock fails on the old behaviour before you keep it, and paste the RED output. A
  lock that cannot go red is worse than no lock.
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
- **Exec bit:** a new `tests/*.sh` must be mode 100755 IN THE INDEX. `chmod +x` alone does not
  reach the index on Windows — use `git update-index --chmod=+x <file>` and confirm with
  `git ls-files -s`. `tests/test-exec-bits.sh` gates this and has caught it repeatedly.
- **Version-bump tripwire.** `tests/test-release-version-bump.sh` fails whenever the tree changes
  any shipped path (`mcp/src mcp/dist mcp/package.json model-ladder.json scripts hooks skills
  agents bin systemd .claude-plugin/plugin.json .claude-plugin/mcp.json`) versus the base WITHOUT
  bumping the version. `run-all.sh` globs it, so it runs every time. If you change shipped code,
  bump `.claude-plugin/plugin.json` AND keep `.claude-plugin/marketplace.json` in sync
  (validate-plugin checks drift). Note these are git PATHSPECS rooted at the repo: `skills`
  matches top-level `skills/` only, NOT `.claude/skills/`. A change confined to `.claude/`,
  `tests/`, `docs/` or `README.md` needs no bump.

## Step 5 — Verify (gate on exit codes, never on log tails)

Run these from the repo root and record each EXIT CODE, not the last line:

```
(cd mcp && npx tsc --noEmit)
bash tests/run-all.sh            # shell suite + Vitest + bundle-drift + portability
bash scripts/validate-plugin.sh
```

`run-all.sh` globs every `tests/test-*.sh` and then runs Vitest, so it already covers the
bundle-drift (`test-bundle-current.sh`), portability (`test-script-portability.sh`) and
version-bump (`test-release-version-bump.sh`) gates.

Record BOTH the FAIL list and the SKIP list BY NAME, not just the counts. A skip you cannot name
is a failure you have not looked at — and so is a fail you have not classified.

**Classify every non-pass into exactly one of three buckets:**

1. **DEFECT** — the change broke something. Fix it or revert. Never hand over a red tree.
2. **TIMEOUT ARTIFACT** — `ec=124`. `run-all.sh` uses a 120s per-test timeout
   (`PER_TEST_TIMEOUT`, `run-all.sh:30`) and a loaded machine pushes slow tests over. Measured
   2026-08-21: `test-extract-drain` 147s (52 pass / 0 fail), `test-dream-accept-guards` 72s
   (14 pass / 0 fail) — both reported `ec=124` in the suite and both pass clean standalone.
   Before calling any `ec=124` a defect, re-run that ONE test isolated:
   ```
   TO=$(command -v timeout || command -v gtimeout)   # macOS: brew coreutils, else drop the timer
   env "SB_SUITE_REAL_HOME_PATH=$HOME" "HOME=$(mktemp -d)" ${TO:+"$TO" 600} bash tests/<name>.sh
   ```
   If it passes, record it as an artifact and move on. Consider `SB_RUN_ALL_TIMEOUT=300` for the
   whole suite. Do NOT spend the 3-change budget chasing this.
3. **ENVIRONMENTALLY BLOCKED** — the gate cannot run here at all, for a reason unrelated to the
   change. Example, 2026-08-21: a Linux sandbox reusing a Windows `mcp/node_modules` has only
   `@esbuild/win32-x64`, so `test-bundle-current` cannot bundle and exits 1. This is NOT a pass
   and NOT a defect. To use this bucket you must state: which gate, the platform, the mechanism,
   whether the change touches that gate's inputs at all, and where it last ran green. Then say
   plainly in the report that the gate was not truly exercised. If the change DOES touch that
   gate's inputs, it is a DEFECT until proven otherwise — you may not classify it away.

**Substitute test drivers.** If `run-all.sh` cannot run as one process (sandbox process caps,
per-call time limits), you may drive the tests yourself — but a hand-rolled driver is a false-
signal risk, and on 2026-08-21 one produced two spurious `ec=124`s by leaving stdin open on
hook-reading tests. If you write one: replicate run-all's per-test isolation exactly
(`env SB_SUITE_REAL_HOME_PATH=$HOME HOME=<fresh> timeout <n> bash <test> </dev/null`), validate
it first on a KNOWN-GOOD tree and confirm it reproduces run-all's pass/fail/skip set there, and
report results as "via substitute driver", never as `run-all.sh` output.

Then re-run the Step 1 measurement and state whether the number moved. Remember it only moves at
session Stop, so a same-run re-read will usually be identical — that is expected, not a failure.

## Step 6 — Report and record

Append one entry to `$BRAIN/daily-audit-log.md` (in REPO-ONLY MODE, emit it verbatim in
your final message instead — see Step -1):

```
## YYYY-MM-DD — <focus area>   [mode: full | repo-only]
Base:          origin/main @ <sha>
Excluded:      <open audit PRs you treated as already-done, by number>
Baseline:      <the Step 1 numbers, or LIVE MEASUREMENT UNAVAILABLE — reason>
Investigated:  <what you read, so tomorrow doesn't repeat it>
Findings:      <each with its measurement, or "none">
Rung:          <1 defect fix | 2 lock | 3 measurement | 4 nothing — see Step 4>
Changed:       <files + why, or "nothing">
Prompt:        <what you changed in docs/daily-prompt.md and why, or "unchanged">
Verification:  <exit codes + named FAIL/SKIP lists + bucket for each non-pass>
After:         <the Step 1 numbers again>
PR:            <url, or "none — no changes">
Open / next:   <what you would do tomorrow>
```

The log lives outside the repo, so it is never part of the PR.

### Deliver the work as a PR

**Do Step 7 first** — the prompt edit rides this same PR, so it must be committed before you push.

Only if the run produced changes. Commit them on `audit/YYYY-MM-DD` — conventional-commit
subject, body stating the evidence — then:

```
git push -u origin audit/$(date +%F)
gh pr create --base main --head audit/$(date +%F) \
  --title "audit(YYYY-MM-DD): <one-line thesis>" --body-file <file>
```

The PR body must carry, in this order: the Step 1 baseline; each finding WITH the command output
that proves it; what changed and why; the Step 5 exit codes with the named FAIL/SKIP lists and a
bucket for every non-pass; and anything you deliberately did not do. A reviewer must be able to
reject the PR without re-running your investigation — if the evidence is only in the log or only
in this chat, the PR is incomplete.

**Do not merge it.** Do not enable auto-merge. A human reviews it.

### Return to `main`

Last action of every run, changes or no changes:

```
git switch main
git status --short          # must print nothing
```

Say in your report that you did this and paste the output. If the environment cannot delete
files (some sandboxes cannot), do not leave stray git lock files behind: collect anything
undeletable into `.git/AUDIT-YYYY-MM-DD-DELETE-ME/` and name that single directory in
"Open / next" so the host can remove it in one step.

Finish with a short summary: what changed, the PR link, what it cost, what you would do next. If
nothing changed, say exactly that — it is a valid and useful outcome.

## Step 7 — Improve this prompt (every run, before you open the PR)

This file is the only part of the system that compounds across runs. A run that fixes a bug but
leaves the next run to rediscover the same trap has done half the job.

Ask, and answer honestly:

- What cost me time today that a line here would have saved? Add that line.
- What did this file tell me that turned out to be WRONG, stale, or unexecutable? Fix or delete
  it. A stale instruction is worse than a missing one — it gets followed.
- What did I verify by hand that is now a durable, non-derivable fact? Add it to "Known state".
- What in "Known state" did I just prove is no longer true? Delete it. Do not leave a hedge.
- Did a step's wording let me drift, hand-wave, or skip evidence? Tighten the wording so the
  loophole closes.

Rules for editing this file:

- **Never hardcode a count, version, or line number that the tree can produce.** Write the
  command instead. Hardcoded numbers went stale within one day the last time, which is the exact
  defect class this pass keeps finding elsewhere. "Known state" is for facts NOT derivable from
  the tree — deliberate removals, dead-but-retained data, where archived files went.
- **Additions must earn their place.** This file is read in full at the start of every run; every
  line costs context. If you add a paragraph, look for one to delete. Prefer replacing a vague
  instruction with a precise one over appending a caveat to it.
- **Date every claim you add** (`Measured YYYY-MM-DD: …`) so a future run can tell a fresh
  measurement from an inherited assumption.
- Keep the "Scheduler entry point" block in sync with the launcher actually pasted in the
  scheduler. If you change one, say so in the PR body — the other is edited by a human.
- The prompt change rides the SAME PR as the day's work. It does not get its own. It takes
  effect only once that PR is merged, so tomorrow's run may still be running the old text — that
  is expected.

Record the edit on the log's `Prompt:` line, and give it its own section in the PR body. A prompt
edit needs no version bump (`docs/` is not a shipped path) but it IS reviewed: it changes how
every future run behaves.

## Known state (so you do not rediscover it as a defect)

Counts and versions are deliberately NOT written down here — they went stale within a day the
last time they were, which is the same defect class this pass keeps finding in the docs. Read
them live:

```
jq -r '.version' .claude-plugin/plugin.json                       # current version
cat .claude-plugin/surface-budget.json                            # budget; compare to live counts
ls -d skills/*/ | wc -l; ls agents/*.md | wc -l
ls scripts/*.sh | wc -l; ls tests/test-*.sh | wc -l
grep -c '^registerJsonTool(' mcp/src/server.ts                    # MCP tool count
jq -r '.hooks | keys | length' hooks/hooks.json                   # hook events
```

Durable facts that are NOT derivable from the tree:

- 0.44.0 removed the `code-review-deep` and `team` skills, six agents (`quality-reviewer`, four
  `code-review-*`, `team-worker`) and `scripts/team-run.sh` — deliberately out of scope, not
  missing. The fresh-context critic role moved to `persona_think`.
- `model-ladder.json` `protocol_names` (SCOUT/DO/THINK) is dead data, knowingly retained;
  retirement belongs to the Phase 4.3 flag audit.
- `CHANGELOG.md`, `docs/specs/` and most of `docs/plans/` were removed from the tree in 0.34.0
  and live on the `archive/docs` branch. Read them with `git show archive/docs:<path>`.
- `validate-plugin.sh` emits one known WARN about an undocumented `fork` SessionStart matcher.
  Pre-existing, not caused by your change.
- Known-legitimate SKIPs are declared by the runner itself, per platform — do not keep a second
  copy here to rot. Read the manifest:

  ```
  sed -n '/EXPECTED_SKIPS_LIST=/p' tests/run-all.sh
  ```

  On Windows without Developer Mode (real symlinks unavailable) that manifest currently arms
  three: `test-dream-accept-guards`, `test-dream-lifecycle` (subtests 5b–5i) and
  `test-symlink-guard` (tests 8, 9, 18). Linux/Darwin arms are `__unset__` — unmeasured, so on
  those platforms EVERY skip is unexplained until you explain it. Name each skip in the Step 5
  SKIP list and move on — an armed skip is environmental, not a defect. Any skip NOT in the
  manifest is unexplained until you explain it.

### Standing hypothesis for `read=0` — do not re-derive this each day

`read=0` is the known baseline, but it is no longer an open MYSTERY — it is an open FIX.
Measured 2026-08-21 across all 14 sessions since Aug 11: `injected=83, read=0, prior=0,
hits=none`, INCLUDING the three sessions after Phase 0.1 shipped. So 0.1 fixed injection; nothing
had yet fixed consumption, and the plan's Phase-0 exit criterion is UNMET.

Plan item **0.8** shipped in 0.45.0 as the leading fix: the injected wiki hint now names
`knowledge_fetch(slug)` with a gist-first policy, because the previous wording ("Read in full")
was unexecutable — `Read` needs an absolute path and the payload is a bare `[[slug]]`, so the
only recovery was grep. The telemetry counts a hit only on `knowledge_fetch(slug)` or a `Read` of
`/slug.md` (`stop-extract.sh:161-196`).

**0.8 is a hypothesis under test.** It needs ~5 sessions of value-loop data. Do NOT touch ranking
before reads move. If `read` is still 0 after that, the wording was not the cause and 0.2/0.3
(complete the denominator; record miss reasons) are the queued next moves.

Extraction is structurally starved — already tracked as plan item 0.6, do not file it as new.
`extract-drain.sh:156` calls `sb_drain_escape_safe` FIRST, which requires `ANTHROPIC_API_KEY` or
`SB_DRAIN_DEFER_PMODE_ONLY=1`; under OAuth-only with a live interactive Claude, every tick defers
and both escapes are unreachable. Note `$BRAIN/.extract-timer-env` is 0 bytes, so
exporting the key in a shell will NOT reach the scheduled task — the installer must be re-applied
with the key present.
