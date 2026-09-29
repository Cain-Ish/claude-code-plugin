# S1 evaluation harness

A with/without falsification experiment answering: does second-brain's pushed
memory (SessionStart repo card, JIT path-triggered lines, role cards, compact
reinjection) change agent outcomes on real repo tasks, versus turning that
push off, versus a static offline-rendered block, versus nothing at all?

Arms: **A** full plugin · **B** same plugin, push hooks removed (guards + MCP
pull stay) · **C** no plugin, an offline-rendered static block instead ·
**D** floor (no plugin, no block). Full design: `s1/SPEC.md` was the build
spec for this dispatch (kept outside the repo, in the dispatching session's
scratchpad — see "Design provenance" below).

## Why this lives under `tests/evals/`, not `tests/`

Two repo gates only look at **top-level** `tests/test-*.sh` files:

- `scripts/validate-plugin.sh`'s R8 surface-budget check counts tests with
  `find "$PLUGIN_ROOT/tests" -maxdepth 1 -name 'test-*.sh' -type f` (verified
  at `scripts/validate-plugin.sh:250`, inside the R8 block starting at line
  242).
- `tests/run-all.sh` runs `for script in "$TESTS_DIR"/test-*.sh; do ...`
  (verified at `tests/run-all.sh:189`), a shell glob that does not recurse
  into subdirectories.

Everything under `tests/evals/s1/` is `.mjs`/`.json` (no `test-*.sh` name,
and not top-level even if it were), so neither gate ever sees it. It is not
wired into any CI workflow either — this harness is invoked by hand, on
purpose, since a single full run costs real API budget and 2-6 hours of
concurrent `claude` invocations.

## Files

| File | Role |
|---|---|
| `s1/tasks.json` | Byte-identical copy of the pre-registered 12-task set (t01-t09 + c01-c03): prompts, gold/wrong answers, scoring regexes, the canary string. Generated (and self-tested) by the design session's `gen-tasks.mjs`; this copy is never hand-edited. |
| `s1/config.json` | Pins: plugin commit (`TBD-after-S0-merge` until S0 merges), task-repo commit, frozen-snapshot manifest hashes, model (`TBD-after-smoke` until the smoke run reports `init.model`), effort, seed, concurrency, retry policy, arm definitions, arm B's hook-removal list, the settings.json allowlist. |
| `s1/lib.mjs` | Shared, pure-where-possible library: env scrub, leak guards, path normalization + touch matching, scoring (ported from the design session's `gen-tasks.mjs`), decision-rule math, a seeded PRNG/shuffle, the run-plan builder, `claude` argv/`settings.json` builders, a 3-total/2-A-B concurrency scheduler, and the git helpers for the one-time repo template + per-run worktrees. |
| `s1/prepare.mjs` | One-time `EVAL_ROOT` setup: imports the frozen snapshots (never re-snapshots the live brain), verifies their manifest hashes, leak-scans them before import, redacts `PROJECT.md`'s experiment-meta line, and writes the seeded 144-cell run-plan. `--dry-run` does every read-only check without copying anything or touching the network. |
| `s1/run.mjs` | Orchestrator: `--smoke`, `--full`, `--resume`. Builds the per-run sandbox + `settings.json`, scrubs env, spawns `claude` (argv array, no shell), captures the stream-json output, computes touch metrics, runs the leak guards, appends to `runs.jsonl`. Refuses to start (hard guard, not just a convention) while `config.json`'s `plugin_commit` pin is still the placeholder. |
| `s1/score.mjs` | Scores a `runs.jsonl` against `tasks.json` and applies the pre-registered decision rules. `node score.mjs selftest` is the required self-test (see below). |

## Node only, no new dependencies

Everything is Node >=18 built-ins (`node:fs`, `node:path`, `node:crypto`,
`node:child_process`, `node:os`, `node:url`) — no npm install, consistent
with the plugin repo's "no new native deps" convention. `spawnClaude` and the
git helpers in `lib.mjs` always pass an **argv array** to `child_process`
(`spawn`/`spawnSync` with `shell: false`), never a shell string, so Git-Bash/
MSYS path conversion can never rewrite an argument mid-flight.

## Running it

```bash
# 1. One-time setup (safe to run any time; --dry-run touches no filesystem
#    outside EVAL_ROOT and makes no network call):
node tests/evals/s1/prepare.mjs --dry-run \
  --snapshot-src <dir containing frozen-brain-20260927/ and frozen-knowledge-graph-20260927/> \
  --id <run-id>

# same, for real (copies the snapshots into EVAL_ROOT and redacts PROJECT.md):
node tests/evals/s1/prepare.mjs \
  --snapshot-src <dir> --eval-root <EVAL_ROOT> --id <run-id>

# 2. Selftest the scorer (no EVAL_ROOT needed):
node tests/evals/s1/score.mjs selftest

# 3. Smoke (build order step 6 — NOT run by this dispatch; needs the plugin
#    commit pinned in config.json first):
node tests/evals/s1/run.mjs --smoke --eval-root <EVAL_ROOT> --repo-source <local checkout>

# 4. Full run (build order step 7 — 144 cells, 3-way concurrency):
node tests/evals/s1/run.mjs --full --eval-root <EVAL_ROOT>

# Interrupted? Resume without re-running completed cells:
node tests/evals/s1/run.mjs --resume --eval-root <EVAL_ROOT>

# 5. Score + apply the decision rules:
node tests/evals/s1/score.mjs run <EVAL_ROOT>/runs.jsonl --out <EVAL_ROOT>/results.json
```

`EVAL_ROOT` defaults to `%LOCALAPPDATA%/sb-evals/s1/<id>` (never inside the
repo, never under `~/.second-brain`, `~/knowledge`, or `~/.claude` — enforced
by `assertNotLiveBrainPath` on every write target in `lib.mjs`).

## Decision-rule interpretation notes

`SPEC.md`'s decision rules are pre-registered but two lines are terse enough
to need an explicit reading, written down here rather than picked silently:

- **Harm**: "A >=2/3 below D on any task" is implemented as a **pass-rate
  difference** — `rate(D, task) - rate(A, task) >= 2/3`, where
  `rate(arm, task) = correct_count / reps` (e.g. D at 3/3 vs. A at 0/3 or
  1/3). `computeDecisionRules` in `lib.mjs` documents this at the `harmTasks`
  line.
- **R's shuffle**: "3 blocks ... shuffled with seed 20260927" is read as one
  continuous seeded PRNG stream shared across all 3 blocks (rather than
  re-seeding `20260927` independently per block) — see `buildRunPlan` in
  `lib.mjs`.
- **Missing cells**: a task/arm cell with fewer than the pre-registered 3
  reps present is a failure for `maj`/`pass`/`Δtasks`/native-dominance
  purposes (per SPEC.md, literally), but is *excluded* (and reported in
  `missing_cells`) from the per-task median used by `R`, since a median over
  present-only reps has no principled way to represent an entirely-absent
  cell as a number.
- **Bootstrap CI**: reported as a 95% percentile CI over 10,000 resamples of
  the 12 task-level `+1/-1/0` win/loss/tie indicators — not specified further
  by SPEC.md, and explicitly "reported, not gating."
- **Blinded audit sample**: 20% of scored runs, deterministically selected;
  the blinded list an auditor sees carries only `task_id` + answer text (no
  arm/rep/session id), with the arm/rep/session-id mapping kept in a
  separate, un-shown key file for reconciliation after the audit.

## `selftest` output

```
$ node tests/evals/s1/score.mjs selftest
selftest OK: 45 cases passed
```

Exit code 0. The 45 cases: 12 gold answers (one per task) each score
`correct`; 24 wrong answers (two per task) each fail; 1 case for
`is_error`/missing-`final_text` forcing `correct=false` with
`no_answer_line=true`; 5 decision-rule arithmetic cases on synthetic
`runs.jsonl` data — not-falsified, falsified, inconclusive (>=6 saturated
tasks), harm, and missing-cells-count-as-failures; 1 env-scrub case proving
`SB_NESTED_SPAWN` and every `CLAUDE*` key are removed (and that arm B's
`SB_JIT=off` overlay still lands correctly afterward); 1 leak-guard case
(canary detected in a fixture, no false positive on clean text); 1
touch-matching case (calls-before-first-correct, censoring at `total+1` when
nothing touches, and proving a `Grep`/`Glob` `pattern` never counts as a
touch even when it lexically matches a `correct_files` regex).

## Design provenance

`tasks.json` and the scoring semantics it encodes are a byte-identical copy
of the design session's pre-registered artifact (`gen-tasks.mjs` ->
`tasks.json`, self-tested there before being copied here). `config.json`,
`lib.mjs`, `prepare.mjs`, `run.mjs`, and `score.mjs` are new, written for this
dispatch directly against `SPEC.md` (the build spec handed to this dispatch,
not itself part of this repo).

## Gaps (build order steps 1-5 scope; not run in this dispatch)

- **Steps 6 (smoke) and 7 (full) were not run**, by design: `config.json`
  pins `plugin_commit` to the placeholder `"TBD-after-S0-merge"`, and
  `run.mjs` has a hard, code-level guard (`assertReady`) that refuses to
  spawn a single `claude` process while that placeholder is in place (or,
  for `--full`/`--resume`, while `model` is still `"TBD-after-smoke"`).
  Verified in this dispatch: the guard fires with exactly that message when
  invoked against a real (throwaway) `EVAL_ROOT`.
- **Building `EVAL_ROOT/plugins/{a,b}` (the copy-of-`plugin/`-minus-hooks
  step for arm B) is not implemented.** `prepare.mjs` logs a `SKIP` for this
  step with the reason (`plugin_commit` unpinned). `config.json`'s
  `hook_removal_b` and `run.mjs`'s `buildArmBHooks()` encode *what* to strip
  from `hooks/hooks.json` and are unit-testable once a real `hooks.json`
  is available at the pinned commit, but the actual "copy plugin at commit
  P, apply the removal, assert A and B differ only in `hooks/hooks.json`"
  step was out of this dispatch's scope (steps 1-5 only) and is deferred to
  whoever runs step 6.
- **The wiki snapshot (`git --git-dir ~/.second-brain/wiki-history.git
  archive <full hash>`) is not fetched or copied.** `SPEC.md`'s own text
  truncates the commit hash (`f681200838d4…`); `config.json` records only
  the short hash `f681200` from `tasks.json`'s `frozen.wiki_commit` field and
  flags the full hash as unresolved. `run.mjs`'s `seedSandbox()` copies
  `brain` and `knowledge-graph` but has no wiki step — wiki content will be
  missing from every run's sandbox until this is filled in.
- **The C2 optional arm (native `autoMemoryDirectory`) is not implemented.**
  `config.json` documents it as `optional`/`not in the decision`;
  `run.mjs`/`lib.mjs` have no code path for it.
- **The one-time repo-template clone (`git clone --no-local` + ref
  stripping + `reflog expire` + `gc --prune=now`) is implemented in
  `lib.mjs` (`ensureRepoTemplate`) and unit-testably pure argv-array git
  calls, but was never actually invoked against the network in this
  dispatch** — it needs a `--repo-source` (the local checkout to clone
  `--no-local` from) that only makes sense to supply once step 6 is ready to
  run for real.
- **A residual, non-canary mention of the experiment adjacent to the
  redacted `PROJECT.md` line was found but deliberately left alone.** The
  frozen brain snapshot's `PROJECT.md:96` is a wiki-link title,
  `[[context-injection-falsification-test]]`, one line after the redacted
  meta-commentary at line 67. `SPEC.md`'s redaction list only names line 67;
  this harness's mandatory leak-guard patterns (canary, `tasks.json`,
  `s1-t0`/`s1-c0` prefixes, task-prompt prefixes) do not match this text
  either, so it is neither redacted nor caught by the abort-on-hit scan.
  Flagging it here for a human call before step 6, rather than silently
  redacting beyond what was pre-registered or silently shipping it.
- **`run.mjs`'s claude-invocation path (`spawnClaude`, the full per-run
  sandbox/settings/argv wiring) has not been exercised against a real
  `claude` process** — only its pure/offline pieces were: `lib.mjs`'s
  functions via `score.mjs selftest` (45/45 passing), and `prepare.mjs`'s
  leak-scan + hash-verify + real snapshot import + `PROJECT.md` redaction
  against the actual frozen snapshots (run manually during this dispatch,
  then cleaned up — no artifact from that check was left on disk).
