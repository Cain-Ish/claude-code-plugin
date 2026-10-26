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
- **First proposed, then withdrawn after the second opinion:** the source read before the first code write after the
  change is requested. Under it, stage 1 would have scored 4 of 5.
  - It moved the goalposts: it defines run 3 out of the count, so the failed option would pass without a byte changed.
  - Real sessions have no "symptom" or "task" label on a turn: a turn-1 edit is a real code write.
  - The note also contradicted itself. It treated symptom-turn writes as not needing the read, and then counted reaching
    them as a strength of (A).
- **The candidate now, keyed to the rule's domain rather than to the turn:** the source read before the first code
  write in the rule's domain, in any turn.
  - Each rule's domain is a path scope, fixed before any run from the rule's own text.
  - Where a rule's text covers every file of a language, its domain is that language. R5 forbids its old names in any
    C# file, so its domain is all C#, and run 3's symptom-turn write counts. Stage 1 fails under this bar too, as it
    should.
  - Consequence: in the vague shape, a write in a rule's domain can come in any turn, including before the change is
    named (P2: 1 of 5 in both 2e and stage 1). Only a mechanism that acts at the write can meet this bar for such runs.
  - Stage 1 stays failed (rule 2). Its bar was fixed before it ran, and tightened before its output was read.

## Options, by level

### (A) Selection at the write

A `PreToolUse` hook on code writes denies the first one in each directory of an epoch, once. Its reason asks Claude to
name the documents from the index that bind this write, read them, then write again. The second try passes only if a
Read came after the deny. The forced decision at each epoch's first prompt stays as it is.

Revised after the second opinion; the first draft had three flaws:
- it gated only the first write of each turn, which leaves a turn's later writes in other areas ungated (count 3:
  median 2 to 7 directories per run);
- it accepted any Read since the epoch began, which the symptom turn's reads already satisfy;
- it asked for names "from your yes directories", which carries a decision made on a vague prompt forward.

- **Addresses:** timing, wholly. At the write, the change's terms are always in hand: the target file and the edit. It
  reaches writes that no prompt-time text reaches:
  - a write in a rule's domain before the change is named (run 3);
  - a write after a compaction inside a turn (a phase-gate trigger, still open);
  - subagent writes (the other open phase-gate trigger), but only if `PreToolUse` fires inside subagents. That is
    unverified: an arrival probe comes first (D12's rule).
- **Enforces a read, not only a name** (run 4's bypass): the hook sees the session's tool calls, so the second try needs
  a Read after the deny.
  - It still cannot tell whether the Read was of the binding document. That is the bypass left: read anything.
- **A rule whose domain is a whole language binds every write in it.** (A) passes such a rule only if Claude names that
  rule's document at the first such write, whatever the write is about (R5 at run 3's first write). Stage 1 measures
  exactly this, and nothing on record predicts it.
- **Does not change the selector.** Claude still chooses documents by name, now with the write's terms in hand and the
  whole index to choose from. This moves the same selector to the moment the terms are present. It is not a new
  selector, and it does nothing for granularity.
- **Cost:**
  - one deny and one rewrite per directory first written in an epoch: median 2 to 7 per run (count 3). D20 measured a
    deny's rewrite taking P1's output from about 5.3k to 9k tokens;
  - priced from 2e's P2 vague streams: a late main-session call costs about 0.10 USD (0.087 to 0.099; stage 1:
    0.098 to 0.133). A deny cycle is about 3 to 5 calls (the wasted write, the naming, 1 to 3 Reads, the rewrite), so
    about 0.3 to 0.5 USD. At P2's median of 4 directories per run, that adds about 1.2 to 2 USD to a median of 4.24.
    P2 build's no-worse ceiling is 10.85 USD (D19's rebase file). This is an estimate, not a measurement;
  - a Node start per Write or Edit call (D18: 40 to 90 ms on Windows).
- **Reopens the parent constraint:** D18's surface ("No `PreToolUse`") and 06's budget of exactly 3 hook events (PM6).
- **The margin is thin.** Stage 1's bar allows one miss in 5. If Claude does not name R5's document at a write that
  looks unrelated, a run like run 3 (1 of 5 in both samples) uses up that miss. A read of the wrong document after a
  deny then fails the cell. (A) is a sound attempt, not a likely fix.
- **Check, rough shape:**
  - an arrival probe (Haiku, minutes);
  - then stage 1 on P2 vague, 5 runs, under the domain bar;
  - then no loss across the shapes and standard arms, as rethink 4's stage 2 planned, with cost against the no-worse
    ceilings, since this option adds a rewrite to every run;
  - about 40 Opus runs.

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

Rethink 4's (c) again, with the second opinion's change: names come from the whole index, not only the yes
directories.

- **Addresses:** timing, for prompts that carry the change.
- **Its two failure modes are built into prompt-time text:** it cannot act on a write made before the change is
  named, and it cannot see whether a named document was read.
  - Under the domain bar both still count. In P2's vague shape, a domain write came before the change in 1 of 5 runs in
    2e and in stage 1 alike, and naming stood in for reading in 1 of 5 in stage 1. That is stage 1's 3 of 5 again.
- **Cost:** the cheapest. No new hook event, and 255 B on later prompts.
- **Risk:** it passes only under a bar that leaves those runs out, which is the withdrawn change-turn bar.
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

## Recommendation: (A) as revised, under the domain bar

- Under a bar that does not move, it is the only option that can reach a write made before the change is named. It is
  also the only one that can require a read rather than a name.
- It covers both open phase-gate triggers: the compaction inside a turn and, if the probe shows arrival, subagent
  writes.
- **What it is not:** a new selector. If stage 1 fails because Claude names the wrong document at the write, timing is
  ruled out as the cause, and the selector itself is what reopens: granularity, and (B) or a search.
- **Cost:** a rewrite per directory first written in an epoch, median 2 to 7 per run. Estimated at about 1.2 to 2 USD
  per P2 run, within P2 build's ceiling. The check measures it against the no-worse ceilings.
- **Why the forced decision stays,** although its "read every yes directory" cannot be followed at 1.5 MB:
  - arm `p` failed without it;
  - the standard-shape gains rest on it;
  - one change at a time.
- **Surface:** it grows from 3 hook events to 4, which reopens D18's surface and 06's budget. That is also the user's
  call.
- **Order:** the arrival probe first (a deny inside a subagent, and after a compaction inside a turn), then the
  pre-registered check. Attempts run from a copy of the plugin, never from `plugin/` in place.
- **If the surface should not grow:**
  - (C) is no real fallback under the domain bar. It meets stage 1's two failure modes in the same runs.
  - The honest alternative is (D), as a deliberate choice of scope, with the vague and switch numbers stated.

Nothing is pre-registered here: the check follows the user's choice of level and bar.

## Second opinion: Gemini 4 Argon (2026-10-26)

*Channel:*
- Antigravity CLI 1.4.7, model `gemini-4-argon-high`, plan mode, run in an empty folder holding only the brief.
- The brief was this note as first committed, plus public context: the route's fixed texts, rule 4, rethink 4's text
  and stage 1 result, and the options already rejected with their numbers.
- The CLI reported status "ERROR" after 514 s, but returned the full reply, printed twice with the first copy cut off.
- Usage: 34,463 input tokens and 17,785 output tokens, 15,641 of them thinking.

Its points, and what was done with each:
- **The change-turn bar moves the goalposts.** It defines run 3 out, so the failed option passes unchanged. Real
  sessions have no turn labels, and the note contradicted itself on symptom-turn writes. *Taken:* that bar is
  withdrawn.
- **The legitimate bar is keyed to the rule's domain, in any turn.** *Taken,* with each domain fixed from the rule's
  text before any run. A rule that covers a whole language (R5) keeps the strict reading, so stage 1 fails under this
  bar too.
- **Keep a mechanism bar, but the jump from 1 of 5 to 5 of 5 is real:** naming works as a retrieval cue, without read
  enforcement. *Taken:* it matches the record, and it is why (A) enforces the read.
- **(A)'s bypasses:** the symptom turn's reads already satisfy "a Read since the epoch began", and a first-write-per-turn
  gate leaves a turn's later writes ungated. *Taken:* a Read after the deny is required, and the gate is per directory
  per epoch.
- **(B) can pass on a test rule whose title echoes the prompt.** It misses rules under subheadings, and it does nothing
  when the prompt lacks the terms. *Noted:* (B) is not recommended, and its check would need a new measure first.
- **(C) passes P2 vague under the change-turn bar** without fixing either failure. *Taken:* with that bar withdrawn,
  (C) is no fallback.
- **(D) passes by tautology,** and real epochs often start with "continue" or a symptom. *Agreed,* as the note
  already said.
- **(A) is not a new level, but the same selector moved to another hook.** *Taken in part.* (A) changes when and where
  the selection happens, and enforces the read. It does not change the selector. The recommendation now says so, and
  names what reopens if (A) fails on selection.
- **Timing and directory scope are coupled:** a directory marked no on the vague first prompt stays excluded at the
  change. *Taken:* (A) and (C) now name from the whole index.
- **A missed level, compliance enforcement:** run 4 named the right document at the right time and skipped the Read.
  *Taken:* it is what the read requirement in (A) addresses.
- **Its choice:** (C) within the 3-hook budget, or (A) if the subagent and mid-turn writes justify reopening D18, either
  way with the three changes above. *Weighed:* under the domain bar it endorses, (C) still meets stage 1's two failure
  modes, so the recommendation stays (A).
