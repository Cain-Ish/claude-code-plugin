# V2-D19 scale probe

How is value measured where the user's projects are: large repos with big documents (scenario A2)? The check, its
premise count and the result are in [`DECISIONS.md`](../../DECISIONS.md) under V2-D19. A2 reuses D20's harness and
four test-bed tasks; the task text, rules and the user's auto memory stay in `research/raw/d19/` (gitignored), and
this folder holds counts only.

- Harness: [`../V2-D20-adherence/native.mjs`](../V2-D20-adherence/native.mjs).
  - Arm `m` is M1 at scale: the user's own auto memory, a fresh copy per run. Its smoke check (`smoke … m`) asks a
    cheap model to quote the memory index's first line without opening it.
  - Mode `scale` writes [`results/a2.json`](results/a2.json): per task, M1 (arm `m` where the user has a memory for
    the repo, native elsewhere), each rule's followed count, and the medians, spreads and thresholds by D17's rule.
- Native runs 1 to 5 are D20 stage 1's. Runs 6 to 10 were added here in the same epoch (CLI 2.1.305, Sonnet 5.5).

## Results (2026-10-22)

| | Result |
|---|---|
| Smoke | The memory index arrived (quoted without opening it); `InstructionsLoaded` does not report auto memory, so each run checks the memory folder named in its start event |
| Runs | 25 runs, the pilot among them, all valid, one epoch; 9.16 USD. Every task has 10 valid M1 runs |
| Thresholds | In [`05-eval-plan.md`](../../05-eval-plan.md), scenario A2, by D17's rule. Its gaps: 4 rules at floor 0, and 5 count or token cells where M1's spread is at least its median |
| Context | At most 13% of the 1M-token window in these runs (17% across 57); no compaction, no subagent |
| P1, the user's memory against native | Nothing measured changed (R2 4 of 10 against 2 of 5; the shared value reused 0 of 10 against 1 of 5); median cost 0.32 against 0.24 USD |
