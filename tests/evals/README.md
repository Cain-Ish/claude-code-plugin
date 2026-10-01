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
| `s1/lib.mjs` | Shared, pure-where-possible library: env scrub, leak guards (base + a brain-only extended set), redaction (`redactLines`/`REDACTION_PATTERNS`), path normalization + touch matching, scoring (ported from the design session's `gen-tasks.mjs`), decision-rule math, a seeded PRNG/shuffle, the run-plan builder, `claude` argv/`settings.json` builders, arm B's `hooks.json` rewriter (`buildArmBHooks`), the `git archive`-based arm A/B plugin-dir builder, a 3-total/2-A-B concurrency scheduler, and the git helpers for the one-time repo template + per-run worktrees. |
| `s1/prepare.mjs` | One-time `EVAL_ROOT` setup: imports the frozen brain/knowledge-graph/wiki snapshots (never re-snapshots the live brain), verifies their manifest hashes + the wiki's `.md` count, leak-scans them before import, redacts `PROJECT.md`'s two experiment-meta lines, builds `plugins/{a,b}` from `--plugin-commit`/`--repo-source` when given, and writes the seeded 144-cell run-plan. `--dry-run` does every read-only check without copying anything or touching the network. |
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
selftest OK: 47 cases passed
```

Exit code 0. The 47 cases: 12 gold answers (one per task) each score
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
touch even when it lexically matches a `correct_files` regex); 1 arm-B
hook-removal case against the REAL `hooks.json` at `origin/main` (`git show
origin/main:hooks/hooks.json`, read-only) — proves `config.json`'s
`hook_removal_b` matches the live file: `SessionStart`'s `compact` group and
the `UserPromptSubmit`/`SubagentStart`/`PostCompact` events are gone, the
`startup|resume|clear|fork` group survives minus exactly `session-load.sh`
and `protocol-guard.sh" card` (its other four hooks and every other event —
`PreToolUse` guards included — stay byte-identical); 1 PROJECT.md-redaction
case proving both the line-67 sentence and the line ~96
`[[context-injection-falsification-test]]` wiki-link are stripped, that a
brain-scoped leak scan (`buildBrainLeakPatterns`) both catches the
un-redacted text and comes back clean after redaction, and that the base
(wiki-safe) pattern set never flags the same text — see "Wiki entity-stub
finding" below for why that split exists.

## Design provenance

`tasks.json` and the scoring semantics it encodes are a byte-identical copy
of the design session's pre-registered artifact (`gen-tasks.mjs` ->
`tasks.json`, self-tested there before being copied here). `config.json`,
`lib.mjs`, `prepare.mjs`, `run.mjs`, and `score.mjs` are new, written for this
dispatch directly against `SPEC.md` (the build spec handed to this dispatch,
not itself part of this repo).

## Wiki entity-stub finding (found while wiring the wiki snapshot)

The frozen wiki snapshot (`frozen-wiki-20260927/`, archived from
`wiki_history_commit` = `f681200838d4dd7e1cca09389efaff871e7b35ef`, dated
2026-09-27T19:27:34+02:00, 1104 `.md` files matching `expected_md_count`)
contains `entities/context-injection-falsification-test.md` — an
auto-created, empty `"TODO: expand"` stub — plus one mention of the same
slug in `index.md`'s alphabetical, 377-entry entity list (indistinguishable
there among hundreds of unrelated names like `afk-journey-*` and
`witcherrpg-*`). This was found by actually leak-scanning the real archived
snapshot, not assumed. It's deliberately left un-redacted: unlike the two
`PROJECT.md` lines (real meta-commentary about the experiment's design), this
is a content-free stub name with no leak of task content or design details.
Consequently the redaction-check leak patterns (`REDACTION_PATTERNS` in
`lib.mjs`) are layered onto `<run>/brain` scans only, via
`buildBrainLeakPatterns()` — never onto `<run>/knowledge` (which now
contains the wiki). Applying them there would abort every real run on this
one false positive. `config.json`'s `snapshots.redactions_note` documents the
same split. Flagging this for a human call before step 6 rather than
silently expanding the redaction scope beyond what was asked, or silently
shipping an entity name that happens to match the experiment's own slug.

## Gaps (build order steps 1-5 scope; steps 6/7 not run in this dispatch)

Done in this dispatch (previously listed here as gaps):

- **`EVAL_ROOT/plugins/{a,b}`** are now built by `prepare.mjs` via
  `--plugin-commit <sha> --repo-source <dir>`: arm A is a `git archive
  <sha> plugin/` extraction (argv arrays, no shell; the tar output goes to a
  temp *file*, not a `spawnSync` `input` buffer, and every path handed to
  `tar`'s argv is forward-slashed — both worked around real Windows/MSYS
  failures found while testing this for real, see `lib.mjs`
  `gitArchiveExtract`'s comments), arm B is a full copy of A with
  `hooks/hooks.json` rewritten per `config.json`'s `hook_removal_b`
  (`buildArmBHooks`, moved into `lib.mjs` so both `prepare.mjs` and
  `score.mjs selftest` can use it). `assertDirsDifferOnlyIn` enforces "a and
  b differ ONLY in hooks/hooks.json" as a hard runtime check, not just a
  convention. Verified for real in this dispatch against this repo's actual
  `plugin/` tree (commit `d6067fd`, HEAD at dispatch time) into a throwaway
  `EVAL_ROOT`, cross-checked with an independent `diff -rq`, then deleted.
  `hook_removal_b` itself is also unit-tested against the REAL
  `hooks/hooks.json` at `origin/main` (`score.mjs selftest` case 8) — not
  just this manual run.
- **The wiki snapshot** is archived (`git --git-dir
  ~/.second-brain/wiki-history.git archive <full hash>`, read-only) into
  `frozen-wiki-20260927/` alongside the brain/knowledge-graph snapshots
  (same `SHA256SUMS`/`FROZEN_AT_UTC.txt` convention). The full commit
  (`f681200838d4dd7e1cca09389efaff871e7b35ef`) is resolved and recorded in
  `config.json`'s `pins.wiki_history_commit` (was the short hash `f681200`
  with an "unresolved" note). `prepare.mjs` imports it alongside brain/kg
  (manifest hash + `.md`-count checks), and `run.mjs`'s `seedSandbox()` now
  copies it into `<run>/knowledge/wiki` for every arm.
- **The one-time repo-template clone** (`ensureRepoTemplate` in `lib.mjs`)
  was run for real in this dispatch: `git clone --no-local` from this repo
  at `497fe050efb35437a11865f80ce1518484f0caf9` into a throwaway dir, ref
  pruning, `reflog expire`, `gc --prune=now`, origin set to the GitHub URL —
  confirmed `rev-list --all --count` (998) equals `rev-list --count
  497fe05` (998), confirmed zero refs remain, confirmed HEAD is detached,
  then the throwaway dir was deleted.
- **`PROJECT.md` redaction** now also strips the line ~96 wiki-link mention
  (`[[context-injection-falsification-test]]`), content-matched like line
  67, not a hardcoded line number. `prepare.mjs` fails loud if either
  redaction pattern never fires anywhere across every imported `PROJECT.md`
  (a stale-pin signal, same philosophy as the original line-67-only check).

Still open, deferred to whoever runs step 6/7:

- **Steps 6 (smoke) and 7 (full) were not run**, by design: `config.json`
  pins `plugin_commit` to the placeholder `"TBD-after-S0-merge"`, and
  `run.mjs` has a hard, code-level guard (`assertReady`) that refuses to
  spawn a single `claude` process while that placeholder is in place (or,
  for `--full`/`--resume`, while `model` is still `"TBD-after-smoke"`).
  Verified in this dispatch: the guard fires with exactly that message when
  invoked against a real (throwaway) `EVAL_ROOT`.
- **The C2 optional arm (native `autoMemoryDirectory`) is not implemented.**
  `config.json` documents it as `optional`/`not in the decision`;
  `run.mjs`/`lib.mjs` have no code path for it.
- **`run.mjs`'s claude-invocation path (`spawnClaude`, the full per-run
  sandbox/settings/argv wiring) has not been exercised against a real
  `claude` process** — only its pure/offline pieces were: `lib.mjs`'s
  functions via `score.mjs selftest` (47/47 passing), and `prepare.mjs`'s
  leak-scan + hash-verify + real snapshot import + `PROJECT.md` redaction +
  plugin-dir build against the actual frozen snapshots and this repo's real
  `plugin/` tree (run manually during this dispatch, then cleaned up — no
  artifact from those checks was left on disk).
