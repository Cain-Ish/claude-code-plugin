# Probe V2-D20 stage 1: Claude in the test-bed repos as they are run today

**Privacy first:** the tasks and rules of the two private repos live in a config under `docs/v2/research/raw/`
(gitignored), passed to the harness by path. This folder holds the harness and counts only: task ids, invented rule
ids, rule kinds and how the native setup delivers each rule. No task text, rule text or private path.

Question (pre-registered in [DECISIONS.md](../../DECISIONS.md), V2-D20 "Stage 1 check"): in each test-bed repo, does
Claude miss rules that bind a realistic task, and when it does, was the rule never in its context, or in context but
not applied? The answer decides which mechanism stage 2 tests ([research/2026-10-21-rethink.md](../../research/2026-10-21-rethink.md)).

## Harness

`native.mjs` (Node, no packages) runs one `claude -p` session per run in a fresh worktree of a pinned scratch clone,
with the repo's own `CLAUDE.md`, rules, skills and hooks, and nothing of the user's (setting sources project and local,
`--strict-mcp-config`, auto memory off, Bash and the web off). `log.mjs` is an `InstructionsLoaded` hook that logs
each instruction file that loads, with its reason and trigger file; `--include-hook-events` puts the repo's hook
output in the stream.

For each rule a run records: the check on the final output; the check on the first write; whether the rule was in
context before the first write and at all (an instruction load, a `Read` of its source, a `Skill` call, or its marker
text in anything Claude saw, each placed at the tool call it followed; a rule loaded by a write arrives with that
write, D12); and the chain: followed, not in context, or in context but not applied.

```
node native.mjs checks  <config>                  every check against a correct and a wrong sample
node native.mjs smoke   <config> <task>           one cheap session (a small model): plumbing only
node native.mjs run     <config> <task> [runs] [first] [arm]   arm a (default) is stage 1
node native.mjs summary <config>                  writes results/summary.json (counts only)
node native.mjs arrival  <config> <task> [runs]   stage 2: nonce smoke of three hook channels
node native.mjs summary2 <config>                 stage 2: writes results/summary-stage2.json (counts only)
```

## Plumbing smoke (2026-10-21, before any task run)

One small-model session per repo, writing one file: valid in all three, under 0.01 USD each. Each repo's own skills
are listed and no plugin of the user's loads (the built-in ones do). The `InstructionsLoaded` hook logs the root
instruction file at session start, and a path rule at the first read of a matching file, with its trigger file. A
repo's `PostToolUse` reminder shows in the stream as hook output. The v1 repo has no git history in its extracted
form; the scratch copy is committed once so it can be pinned.

## Tasks (shape only)

| Task | Repo shape | Output | Rules | Rule kinds |
| --- | --- | --- | --- | --- |
| P1-build | path-scoped rule files, large root file | a UI component and its test | 6 | placement 1, convention 2, design 2, unloaded counter-pattern 1 |
| P2-build | prose documents, validators, nothing path-scoped | one game-content script | 8 | placement 1, convention 1, canon 3, always-on counter-pattern 1, unloaded counter-pattern 2 |
| R0-build | no `CLAUDE.md`, rules in project skills | a hook script and its wiring | 8 | placement 1, stale-skill counter-pattern 2, convention 2, design 2, skill-only 1 |
| P2-plan | as P2 | a design plan in the reply, no write | 5 | design 2, canon 2, process 1 |

All 27 checks passed their correct sample and failed their wrong one before the pilot (`checks` mode).

## Results (2026-10-21)

Pilot: P1-build run 1, valid, 0.30 USD; five runs per task projected well under 25 USD, so all ran. 20 runs, all
valid, one epoch (CLI 2.1.305, Sonnet 5.5), 6.37 USD in all. The private config's hash (first 12 hex of its SHA-256)
was `6995c767da91` before the pilot and after the last run; the per-task input hashes recorded with every run are
P1-build `115a7256d3d0`, P2-build `3c70703cefec`, R0-build `933caaaed819`, P2-plan `0605a4d1871c`. Counts per rule: followed / missed while not in context
/ missed while in context. Full counts in [results/summary.json](results/summary.json).

| Task | Followed in all 5 | Missed, not in context | Missed, in context | Median cost, input tokens, turns |
| --- | --- | --- | --- | --- |
| P1-build | R1, R3, R4, R5 | R6 5/5 (a document named for review only) | R2 3/5 (a path rule Claude read; the repo's e2e guard would catch it later) | 0.24 USD, 478k, 16 |
| P2-build | R1, R2, R3a, R3b, R4 | R5 5/5, R7 5/5 (a document nothing points to; 35 and 32 of 35 neighbours do it the old way) | R6 5/5 (always-on text; 0 of 35 neighbours follow it) | 0.54 USD, 918k, 42 |
| R0-build | R1, R3, R5, R7 | R4 3/5, R6 2/5, R2a and R2b 1/5 (skill bodies; no run invoked any of the 17 skills) | R4 1/5 | 0.36 USD, 641k, 28 |
| P2-plan | P3b, P4 | P3a 3/5 (see below) | P5 5/5, P1 1/5, P3a 1/5 | 0.13 USD, 130k, 9 |

Scored as pre-registered, with two checks found wrong on reading the outputs (rule 2: the scores stand, the reason is
written here). P3a counts a plan that names the excluded creature in order to exclude it as a breach; all four of its
misses do exactly that, so by hand P3a is followed in 5 of 5. P5 requires the vision's full path; two plans name the
governing vision by file name, so by hand P5 is followed in 2 of 5. Neither changes an outcome. Lesson for later
checks: test a wrong sample that mentions the forbidden thing in order to reject it.

What the runs show, beyond the counts:
- **A rule in a document nothing points to was missed in every run** (P1 R6, P2 R5 and R7: 15 of 15), and never
  entered the context.
- **The neighbours decide.** Rules the nearby code already shows were followed although the rule was not in context
  before the first write in any run (P2 R2, R0 R5 and R7: 15 of 15 followed). Rules the nearby code contradicts were
  missed, including one in the always-on file (P2 R6, 5 of 5).
- **Project skills holding rules were never opened** (R0: 0 of 5 runs invoked any of 17), while a task-named project
  command was used in every P2 build run.
- **Read but not applied** happens with a path rule Claude itself opened (P1 R2) and with a process rule whose
  document Claude read in every run (P2-plan P5).
- The planning task, with no write, cost a quarter of the build task and read the right vision document in every run.

Limits: one task per repo and five runs; Sonnet 5.5 only; Bash off, so the repos' own lint, tests, e2e and builds did
not run (P1 R2 and P2 R5 would be flagged later by them); regex checks; `followedAtFirstWrite` is blank where the
first write holds no file a rule looks at (fixed after the pilot; it feeds no outcome). A few skills from outside
the repo (bundled, or the user's) were listed in every run; they are the same for every task and arm.

## Stage 2: delivery, then checks and an account (pre-registered 2026-10-21)

Pass condition and decision rule: [DECISIONS.md](../../DECISIONS.md), V2-D20 "Stage 2 check". Each rule now has a
card in the private config: its text quoted from the repo's own files, its source, the area it governs, its class
(17 pattern-held, 10 judgment) and, for pattern-held rules, the feedback line. A card names the counter-pattern only
where its source does (9 of 27). The config's hash before the pilot: `08a2dc047fb1`. Card bytes delivered at prompt
arrival per task: P1-build 1,965, P2-build 2,146, R0-build 2,529, P2-plan 1,742.

- `deliver.mjs` is the hook of both arms. Arm (b) adds the cards to the prompt (`UserPromptSubmit`), and before
  the first write in each card's area it denies once, with the area's cards in the reason (`PreToolUse`). Arm (d)
  adds, after each write, the failing pattern checks of that file (`PostToolUse` block reason). At the first `Stop`
  it sends the failing checks plus a request for a `## Rule account` section. Each call is logged with its duration,
  measured inside the hook process; process start-up is not counted.
- `check.mjs` holds the check and the changed-file listing, shared by the harness and the hook.
- `nonce.mjs` is the arrival smoke's hook.
- The harness skips a denied write when it looks for the anchor and the first write. It keeps the denied content and
  scores it (`atDeniedWrite`): what Claude wrote with the cards from prompt arrival alone.
- Two checks were corrected before any stage 2 run (P3a, P5). On the stage 1 replies each reproduces the hand count
  (5 of 5, 2 of 5). Stage 1's own scores stay in `results/summary.json`.

**Arrival (2026-10-21, CLI 2.1.305, Haiku):** each of the three channels D12 did not probe carried its own nonce,
taken from the environment and in no file. In all 3 of 3 runs, each nonce was quoted: the `PreToolUse` deny reason,
the `PostToolUse` block reason and the `Stop` block reason (0.005 USD). Two earlier trials are reported in the
decision. In both, Claude declined content the user had not asked for: an extra first line in a file it was asked to
create, or an edit to that file. It said why, and asked the user.

**Plumbing smoke (Haiku, P1-build, one run per arm):** both runs were valid. Each area was denied once, the component
first and then the test. Arm (d) fed back nothing (no pattern check failed). Its `Stop` sent the account request, and
the reply carried the `## Rule account` heading. Hook calls took 19 to 222 ms.
