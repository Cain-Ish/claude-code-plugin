# V2-D22, going up a level (rule 4)

Written 2026-10-26, after rethink 4's attempt failed stage 1 and D22 went BLOCKED, and before any choice, check or run.
The user decides the level (map item 17f3). The evidence is in D22's record in [../DECISIONS.md](../DECISIONS.md), in
[2026-10-26-d22-rethink-4.md](2026-10-26-d22-rethink-4.md), and in [../06-first-slice.md](../06-first-slice.md) (2e,
and the user's own check under 2f). New counts were taken from the saved run streams on 2026-10-26; only counts are
given. The second opinion is at the end.

## Where rule 4 stands

- The route locked on 2026-10-22 had its triggers fired twice by the eval (2d, 2e). Then rethink 4's attempt failed.
  2e's reopen note had already said: "If it fails as well, D22 goes BLOCKED, and the assumption is what reopens."
- Rule 4 allows a fourth attempt when the third was a near miss with a known cause. Stage 1 scored 3 of 5 against a bar
  of 4, and both misses have known causes. The clause is not invoked: the registration named BLOCKED for any fail. A
  retry of the same option appears below as option (C), argued at this level, not as a fourth attempt.

## The assumption, in two halves

*One yes/no decision per directory, made at the start of an epoch, selects what a later change needs.*

| Half | What breaks it | In v2's claim? |
| --- | --- | --- |
| **Timing:** "at the start of an epoch" | Vague first prompt: R5's document read in 1 of 5 runs, against 9 of 10 in the standard shape (2e). Task switch: re-read in 2 of 5 after the compaction. Stage 1 re-gated at the change: R5 followed 5 of 5, but its document read before the first code write in only 3 of 5 | Yes: change tasks |
| **Granularity:** "per directory" | 2d: anchors in directories of 15 and 33 files read in 1 of 10 runs. The user's own check: about 1.5 MB of documents in the yes directories in each of three epochs, and 7 to 15 documents read | 2d: no (investigation tasks). The user's check: real use, unmeasured for misses |

What both halves show: **the route's real selector is Claude's own choice of files inside the yes directories, made
from the terms of the prompt at hand.** "Read the documents in every directory you marked yes" cannot be followed at
1.5 MB, so Claude samples by file name. The forced decision scopes directories. It does not select documents. Where
the prompt carries the change's terms, the sample tends to hold the binding document (standard shape, 9 of 10). Where
it does not, the sample misses it (vague, 1 of 5).

The user's check ran on CLI 2.1.310 in a real session. It is cited as real-use evidence, not as an eval cell.

## New counts

1. **Code written in the vague shape's symptom turn,** before the task prompt (2e, valid runs):
   - P1 in 5 of 5, P2 in 1 of 5, R0 in 0 of 5; P2 in 1 of 5 in stage 1 (run 3).
   - P1 held every rule in scope in all five, so a symptom-turn write is ordinary in this shape and harmless there.
   - Stage 1's run 3 wrote code in the symptom turn to the files the symptom concerned. None touches the item system R5
     is about, and none contains R5's banned names. R5's check still covers every C# file, so by the check's scope R5
     governs those writes.
2. **D20's pre-write deny, re-read.**
   - It was tested only bundled with rule cards delivered at the prompt, in a single-prompt shape. The first attempts it
     stopped already followed P1's rules in 5 of 5.
   - So "it fixed nothing prompt-time delivery had not" was measured where prompt-time delivery had already reached the
     change. It does not transfer to the vague shape, where no text reached the change.
   - A deny's reason reached the model in 3 of 3 runs (D20 stage 2's arrival probe), and it stops the write. Rethink 4's
     "its added context arrives next to the tool's result, after the write" holds for a hook that lets the write
     through with added context, not for a deny.
   - So rethink 4's rejection of a write-time hook rests on its cost and the surface budget, not on arrival.
3. **How often a gate at the write would fire.** 2d's standard arm (P2, R0) and 2e's three shapes (P1, P2, R0):
   - turns holding a main-session code write: median 1 per run, at most 2. The one exception is P1's vague shape, with
     a median of 2, because it writes in the symptom turn;
   - directories written per run: median 2 to 7;
   - runs with code written by a subagent: 7 of 65 (R0 6, P1 1);
   - a compaction inside a turn followed by a code write before the next prompt: 0. The harness compacts between turns,
     so the eval never meets the phase-gate trigger about compaction inside a turn.

## The bar: what the plugin guarantees

Every option's check depends on this, so it comes first.

- Stage 1 is the first time the outcome and the mechanism split: R5 followed in 5 of 5, its document read before the
  first code write in 3 of 5.
- The charter's main idea: the plugin "puts the right part of it in front of Claude when a task needs it, and holds
  Claude to it". The outcome alone does not show that the plugin did this. In 2e, R5 held in 1 of 5 runs without the
  read. So a mechanism bar stays, as in the route's own pass (`pf`: the source read before the first write each time).
- **The question is which write.** The registered bar was the first code write of the epoch. In the vague shape that is
  a symptom-turn write in P1 5 of 5 and P2 1 of 5. Meeting it would mean reading, before any C# write, every document
  whose rule's check covers C#. That is P2's whole rule set, and at about 1.5 MB it is the read Claude already cannot
  do. So the bar measured the shape as much as the mechanism.
- **Proposed for the next check (the user decides):** the source read before the first code write after the change is
  requested. In the vague shape that means the task turn. In the standard shape it is the same bar as before.
  - *Disclosed:* under this bar, stage 1 would have scored 4 of 5.
  - Stage 1 stays failed (rule 2). Its bar was fixed before it ran, and tightened before its output was read.
  - A bar argued after a fail can govern only a new check, with fresh runs.
  - *Is this a rule 2 move?* It would be if it re-scored stage 1, or if it were picked to make a known result pass. It
    is argued from the charter's "when a task needs it" and from what any mechanism can reach. The second opinion is
    asked to attack it.

## Options, by level

### (A) Selection at the write

At the first code write of each turn (a prompt, or a turn Claude Code starts itself), a `PreToolUse` hook denies that
write once. Its reason asks Claude to name the documents from its yes directories that bind this change, read the
unread ones, then write again. The forced decision at each epoch's first prompt stays as it is.

- **Addresses:** timing, wholly. At the write, the change's terms are always in hand: the target file and the edit. It
  reaches writes that no prompt-time text reaches:
  - the symptom-turn write (run 3);
  - a write after a compaction inside a turn (a phase-gate trigger, still open);
  - subagent writes (the other open phase-gate trigger), but only if `PreToolUse` fires inside subagents. That is
    unverified: an arrival probe comes first (D12's rule).
- **Can check the read mechanically:** the hook can see the session's Reads since the epoch began. Requiring one before
  the second try passes would stop "naming instead of reading" (run 4) from passing silently. It opens another bypass:
  reading some document, not the binding one. That is a check-time choice.
- **Cannot address:** granularity (Claude still picks by name, now with the write's terms in hand), or naming nothing
  when a document binds.
- **Cost:**
  - one rewrite per turn with code (count 3: median 1 or 2 per run, at most 2). D20 measured a deny's rewrite at P1's output
    going from about 5.3k to 9k tokens;
  - a Node start per Write or Edit call (D18: 40 to 90 ms on Windows).
- **Reopens the parent constraint:** D18's surface ("No `PreToolUse`") and 06's budget of exactly 3 hook events (PM6).
- **Check, rough shape:** an arrival probe (Haiku, minutes); then stage 1 on P2 vague, 5 runs; then no loss across the
  shapes and standard arms, as rethink 4's stage 2 planned. P1 vague is where it costs most, since it writes in the
  symptom turn in 5 of 5. About 40 Opus runs.

### (B) Selection at document grain

The index gains each document's title (its first heading) in large directories: rethink 3's (c), rethink 4's (e).

- **Addresses:** granularity. Claude picks by title instead of a bare file name.
- **Cannot address:** timing. In the vague shape the pick is still made on the symptom.
- **No miss inside v2's claim needs it yet.** On build tasks, R5's document sits in a directory of dozens and was read
  in 9 of 10 standard runs. The large-directory misses are on investigation tasks (outside the claim) and in real use
  (unmeasured).
- **Cost:** always-on bytes grow (P2's index is about 6 KB now). It reopens D13's index form and 06's always-on budget.
- **Check:** it needs a measure the eval lacks, a binding document missed in a large directory on a change task. So
  that measure would come first.

### (C) Re-gate at the change, at the prompt

Rethink 4's (c) again, under the change-turn bar above.

- **Addresses:** timing, for prompts that carry the change.
- **Its two failure modes are built into prompt-time text:** it cannot act on a write made before the change is
  named, and it cannot see whether a named document was read. Under the change-turn bar, the first no longer affects
  the score. The second remains: run 4, 1 of 5, where R5 held on a single Grep hit.
- **Cost:** the cheapest. No new hook event, and 255 B on later prompts.
- **Risk:** it is the failed option with the bar moved. A pass would rest entirely on the bar argument.
- (c'), a search in place of naming, has the same built-in limits.

### (D) Narrow the claim (the user's call)

D22 re-locks on the route as it is. The vague first prompt and the task switch become named weaknesses with their
numbers, and the claim covers changes named in an epoch's first prompt.

- **Cost:** none now.
- **Gives up a common case.**
  - In the user's own check, the first prompt after the resume was a bare request to continue. Epochs 2 and 3 began
    with whatever the owner said next.
  - In the eval, R5's document is read in 9 of 10 runs when the change comes first, and in 1 of 5 when it comes second.
- Rethink 4 rejected this ("a symptom first and the change second is ordinary use"). The user may override that.

## Recommendation: (A), under the change-turn bar

- It is the only option that acts where the change's terms are always present.
- It also covers both open phase-gate triggers, the compaction inside a turn and, if the probe shows arrival, subagent
  writes.
- Its cost is bounded by count 3: one gate per turn with code, median 1 per run.
- It grows the surface from 3 hook events to 4, which reopens D18's surface and 06's budget. That is also the user's
  call.
- Order: the arrival probe first (a deny inside a subagent, and after a compaction inside a turn), then the
  pre-registered check. Attempts run from a copy of the plugin, never from `plugin/` in place.
- If the surface should not grow, the fallback is (C) under the change-turn bar, with run 4's bypass as its known
  residual. (D) only as a deliberate choice of scope.

Nothing is pre-registered here: the check follows the user's choice of level and bar.
