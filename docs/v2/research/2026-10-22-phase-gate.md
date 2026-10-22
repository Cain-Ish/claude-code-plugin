# Concept phase gate (2026-10-22)

**What ran.**
- The devils-advocate workflow (`.claude/workflows/devils-advocate.js`, the user's own, prescribed by rule 8) over
  the whole concept phase: five lenses, and a refute-first verifier for each finding.
- Gemini 3.1 Pro on the architecture page (rule 10).

The scope, files and claims are in the commit that records this note. Rule 8 sets what happens to each surviving
finding: it either fires a named reopen trigger, or it is recorded here as an accepted risk. Nothing re-argues a
lock without a trigger.

## Gemini (3.1 Pro, on a 4 KB brief: the architecture page, the old and new charter sentence, four questions)

| Point | Weighed against | Disposition |
| --- | --- | --- |
| Subagents do not see the index, so they write rule-breaking code, and the main session's rework causes the 3x cost | The token split (D22 route note, §2): P2's subagents researched, and the final files held every in-scope rule. The cost is research, not rework. That subagents *could* write code without the index is real | **Accepted risk**, with a trigger: the first slice shows a file written by a subagent that misses a rule its session read. `SubagentStart` (D12: it reaches every subagent) carrying the index and the session's yes-list is then the candidate |
| A new task in the same session gets no forced decision, so regressions follow | Named in the architecture as untested | **Accepted risk**, a D22 trigger (a vague first prompt, several tasks), measured in the first slice |
| A raw file list at 500+ directories costs 30 to 80 KB at every start and compaction | Measured up to 45 directories (6 KB) | **Accepted risk**, D22's index-size trigger |
| Several developers writing `.project-map/*.md` collide in git | D11 and D14: committed with the work, reviewed like code. Merge conflicts are git's normal path | **Accepted risk** for the slice's file layout: one file per entry, or per area, limits collisions |
| Deferring the net breaks "hold Claude to the rules"; instead, a `PreToolUse` hook makes Claude map its change against the rules before the write | D20's net check: a self-review with no check fixed 0 of 5. Claude judged R2's violating file compliant. D18 rejected `PreToolUse` | **Not taken.** The proposal is the same self-judgment that failed. The net's reopen bar stands |
| Re-running the baselines on Opus first is wasted effort; fix the architecture first | PM1: outcome before input, the lesson of v1, which built for months and never measured | **Not taken** |
| Pass the approved documents' contents to subagents via `SubagentStart` | The hook output is capped at 10,000 characters, and the read documents were 92 to 273 KB. Pointers alone were not followed (`p`) | **Recorded** as the candidate under the first trigger above, in pointer form, untested |

## Devils-advocate workflow (50 agents; 45 findings raised, 24 survived refutation, 21 dismissed)

The 24 survivors come down to 11 issues. Severity is the verifier's. All are medium or low; none is critical or
high.

| # | Issue (findings) | Disposition |
| --- | --- | --- |
| A | The harness counts a subagent's Read as the rule's source read first, so P2's "read first, so it is pull" was overstated, and the route note's "by hand, in the main thread" was false (5) | **Corrected.** [mainreads.mjs](../probes/V2-D20-adherence/mainreads.mjs) splits the threads: in P2, R5 was read in the main thread in 3 of 5 `pf` followings and R7 in 3 of 4, and the rest by a subagent. The asymmetry clause names no thread, so the verdicts stand. Recorded in D22 and the route note. The in-session cost variant must be checked on R5 and R7 first |
| B | D22's reopen triggers name session shapes the eval never runs (1) | **Corrected.** The eval plan adds a vague first prompt, two compactions, and a task switch per build task. A mid-turn automatic compaction is added once it can be forced headless |
| C | `/clear` and `resume` fire `SessionStart` with sources the route does not match. After `/clear` there is no index and no capture instruction. The forced decision's state has no production key (4) | **D12's trigger fired** for those two cells: its nonce probe runs before the slice (06, step 0). The state is keyed by session id (architecture) |
| D | The label hook (D14, D16) was probed only for main-session Reads. Subagent, Grep and Bash reads of a map file go unlabelled (3) | **Accepted risk, with a probe before reliance:** a `PostToolUse` arrival probe inside Explore and general-purpose subagents (06, step 0). Until then the freshness row is scoped to main-session reads (charter) |
| E | An automatic compaction inside a turn: the re-forced decision waits for the next prompt (2) | **New D22 trigger.** The candidate fix is the forced text in `SessionStart`'s compact output, untested |
| F | The net's reopen bar could never fire: under its false-alarm rule, the hand-written checks themselves score 0.16 (2) | **Corrected.** The false-alarm part is suspended until an instrument exists that the hand-written checks pass at 0; it is built when a candidate source exists. The verdict rests on recall (6 of 17) and stands |
| G | The generator counts were recorded as 204 checks and 8 invalid; the raw files hold 122 and 5 (2) | **Corrected** in D20 |
| H | The capture instruction keeps rules from any document read, so under pull it copies rules that already live in tracked files (1) | **D14 accepted risk**, watched by its noise trigger. The candidate narrowing is untested |
| I | Captured entries that are not yet committed would be missing from a tracked-files index (1) | **Corrected** in the architecture: the index adds untracked files under `.project-map/` |
| J | `06` loosened the cost bar from gain to no-worse (1) | **Corrected:** 06 now cites 05's bar per cell |
| K | P2's plan task would be scored on `/compact`'s empty reply. P2 R4 was missing from the expected-miss lists (2) | **Corrected:** the plan task runs as one turn, and there is one expected-miss list, in 05 |

No surviving finding re-argues a locked choice without a trigger. One fired a trigger (D12, C). One adds a trigger
(D22, E). Two are accepted risks (D, H). The rest are corrections to documents and instruments, and none of them
changes a recorded verdict.

**Not examined by this gate:** plugin code (none exists); the private configs beyond the counts the lenses re-derived;
runs on macOS or Linux (every probe ran on Windows); Fable 5.1 (the user's other model).
