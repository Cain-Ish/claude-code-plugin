# V2-D21 inventory probe

Does Claude re-create what a repo already has, and would an inventory computed without a parser stop it? The check,
both parts and the block are in [`DECISIONS.md`](../../DECISIONS.md) under V2-D21. The task text, file names and judge
verdicts of the private repos stay in `research/raw/d21/` (gitignored); this folder holds scripts and counts only.

- `units.mjs`: what each of D20's 36 logged build runs added (its successful Write and Edit calls against the pinned
  commit), shuffled per task without arm or run labels: the judge's input.
- `judge.md`: the judge's prompt (one fresh Opus subagent per task, searching a worktree at the pinned commit). One
  planted re-implementation of an existing unit per task tests its recall.
- `score.mjs`: part 1's counts from the verdicts, the run keys and the hand verification of each claimed duplicate.
- `inventory.mjs`, `inventory-hook.mjs`: option (b), a `git ls-tree` file list grouped by directory, delivered when
  the prompt arrives (D20's harness, arm `i`).
- `reuse.mjs`: part 2's deterministic score per run, with the names read from the private config.

| Part | Result |
|---|---|
| 1, option (a) | [part1.json](results/part1.json): controls 3 of 3; duplicates in 10 of 36 runs, all in one task and of one kind (a value re-declared that a shared module exports); no file duplicated |
| 2, options (b), (c) | [part2.json](results/part2.json): the inventory left 5 of 5 runs duplicating; the repo's own checks do not look |

D21 is BLOCKED after attempt 2 and goes up a level to the user.
