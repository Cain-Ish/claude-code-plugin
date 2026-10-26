# V2-D22, after the gate failed stage 1

Written 2026-10-26, after option (A), the gate at the write, failed its stage-1 bar, and before any choice, check or
run. The user asked for the options written up, attacked by the second opinion, and then brought back for a choice.
This version is revised after that attack; the first version is in git history.

The evidence is in D22's record in [../DECISIONS.md](../DECISIONS.md) and in
[2026-10-26-d22-level-above.md](2026-10-26-d22-level-above.md), which chose (A). New counts were taken from the saved
run streams on 2026-10-26. They are exploratory, and only counts are given. The second opinion is at the end.

## What failed

Stage 1 ran 5 Opus runs of P2 vague on the plugin copy, all valid.

- R5 failed in 0 of 5. The reference failed it in 4 of 5.
- The main session Read R5's document before its first C# write that went through in 0 of 5. The bar was 4.

The level-above note said: "If stage 1 fails because Claude names the wrong document at the write, timing is ruled out
as the cause, and the selector itself is what reopens." The failure has two halves. Counts below are by run and in
order, with each call grouped by the assistant message that made it.

**The cap, a defect in the copy.**
- In 4 of 5 runs, the first C# writes came as one message of 4 edits.
- The hook sees each call before Claude sees any result. So the first two were denied, the 2-deny cap let the rest
  through, and the writes landed before any deny reached Claude.
- 6 of the 21 gated directories opened this way, inside the message that held their denies.
- `gatecheck`'s "directories that reached the cap" (8 in all) also counts 2 directories that took two denies but
  opened later, after a Read.
- The smoke had shown the same batch, and its record misnamed it as retries.
- So at the event the bar scores, the first C# write, the gate reached Claude in only 1 run of 5.

**The choice, the selector.** The counts come from directories where a deny reached Claude before the main session
had read R5's document. After that read, the gate's "Read the ones you have not read" rightly sends Claude elsewhere,
so those directories are left out.
- *Off the system R5 is about:* 7 such directories, in 4 of 5 runs. Claude read other documents in all 7 (median 1).
  R5's document was read in none.
- *The directory of the new file the task asks for:* 4 such directories. R5's document was read in 3 of them. In the
  fourth (run 3), only a subagent had read it, in the first turn.
- *What Claude wrote after a deny:* of 20 messages that held a deny, the next message started with text in 4. No text
  named R5's document.

**Other numbers:**
- R4, a miss listed in 05, failed in 4 of 5 against the reference's 2. It is outside the no-loss set, but worse.
- Cost: a median of 6 denies per run. The median cost was 6.44 USD against the reference's 4.24, so +2.20, while the
  level-above note estimated 1.2 to 2. One run, at 11.79, went above P2's ceiling of 10.85. That was with the cap still
  letting batches through. A cap that holds adds deny cycles.

**What Claude chose by:** the topic of the file being written, under a gate text that asked for "the documents ... that
bind this change" at "your first write in <dir>/". That text anchors Claude on the directory and the change. It never
asks for rules that bind every file of the language. So the counts show how Claude selects under this text. They do
not show that no text could do better.

## Where R5 is actually broken

The bar keys R5 to its check's path, every C# file, because the rule's text bans its old names anywhere in C#. The
runs on record show where the old names were actually written, across every P2 build run of 2d and 2e (native and the
plugin's arms), rethink 4's attempt and stage 1.

- The old names were written in 16 of 35 runs of 2d and 2e.
  - In 15 of the 16, they were in the new file the task asks for. One of these also wrote them in a shared base class
    on the same system.
  - The other run wrote them only in that base class.
  - No run wrote them in a file off that system.
- Rethink 4's attempt and stage 1 never wrote them: 0 of 10 scored runs.

So R5's prohibition covers every C# file, but its risk surface on record is narrow: the writes that put that system to
use, with old names or new. Those writes are the new file and its base class. That tension is real, and it is what the
next section is about.

## The bar

Stage 1 stays failed (rule 2): its bar was fixed before it ran. **The next attempt keeps the domain bar.**

- A bar keyed to R5's topic or risk surface would pass both failed attempts on data already seen. Under it, stage 1
  scores 4 of 5 and rethink 4's attempt 4 of 5, with the topic taken as the new file's directory plus the base class.
- That is the withdrawn change-turn bar again, moved from turns to files.
- Any rule for drawing a topic, written now, is informed by where the reads and violations landed.
- Promising less for rules whose scope is wider than their topic is a narrower claim, so it belongs under (D), the
  user's call. It is not a way to meet the current claim.

## Options

### (A2) Fix the cap

Count denies per assistant message: every edit to a gated directory in one message gets the same deny and counts once.
The directory opens only after a main-session Read since the deny. The loop guard counts denied messages, not calls.
The smoke must show it on a message that batches several edits.

- **Addresses:** the cap half only. It is needed inside any later gate attempt.
- **Alone, predicted to fail:** at the 7 off-topic directories where a deny reached Claude, R5's document was read in
  none.
- **Cost:** more deny cycles than the +2.20 USD per P2 run measured, since no batch slips through.

### (P) Ask for language-wide rules in the gate's text

The deny's reason asks for two kinds of document: those that bind this change in `<dir>/`, and those that bind every
`<ext>` file anywhere in the project.

- **Addresses:** the choice half as far as the text caused it. Stage 1's text never asked for language-wide rules.
- **Untested.** Stage 1's evidence (0 of 7 off-topic) was gathered under the old text, so it does not predict this one.
  The risk is the one rethink 4's text attempts met: Claude may name documents without reading them, or read one and
  move on. Only (A2)'s read requirement guards against that, and only for one Read.
- **Cost:** a few bytes, plus the deny cycles of (A2).

### (S) Scope found by the hook

At a deny, the hook lists the index documents that state a scope covering the written file. The gate then requires a
Read of every unread document on that list, not just one. There are two matchers, tested separately:
- (S-a) a document's text names the file's extension, language or a folder on its path;
- (S-b) a scope statement found in the document's header or first lines, carried into its index entry as a tag.

**The catch.**
- A language-level match may list most documents: P2's rule folder alone holds 13 documents and about 150 KB, and
  P1's holds 29 and about 580 KB.
- A folder-level match stays short, but it misses R5 at an off-topic write.
- A long list with a one-Read unlock lets Claude pick by topic again.
- So (S) is viable only if lists are short and every listed document must be read.

**The static probe, rough shape, with no model calls (rule 5).** Its numbers are pre-registered before it runs.
- It searches every document in the plugin's index of P1, P2 and R0, not only the scored rule documents.
- *Recall:* every in-scope build rule's document is matched at the paths its check covers.
- *Length:* at each first code write in each epoch of the saved stage-1 streams, and at the first code write of each
  P1 and R0 shape on record, the list of unread matches stays at or under a ceiling (the second opinion suggests 4
  documents and 40 KB).
- A false pass is possible if a matcher keys on words that happen to appear in the scored rules. A false fail is
  possible if documents state their scope in concepts or class names instead.

### (D) Narrow the claim

D22 re-locks on the route as it is, with no gate and 3 hook events. The vague first prompt and the task switch become
named weaknesses, with their numbers.

- **Cost:** none now.
- **Gives up:** R5 in the vague shape, held in 1 of 5 by the route against 5 of 5 with either later read. A symptom
  first and the change second is ordinary use (rethink 4).
- **A narrower variant:** promise rules whose scope is wider than their topic only on their topic.
  - Under that claim, rethink 4's prompt-time re-gate (3 hook events, no deny cycles) is the candidate, not the gate.
  - It needs a topic rule fixed before any run, and a fresh attempt on rules not used to design it.
  - The second opinion advises against it.

## Recommendation: keep the domain bar; probe (S); then one combined attempt, or (D)

1. **Pre-register and run (S)'s static probe**, both matchers, over the whole index of P1, P2 and R0, with recall and
   length ceilings fixed first. Minutes, no model calls.
2. **If a matcher passes:** one combined attempt on a new copy, under the domain bar. It brings together (A2)'s cap
   per message, (P)'s text, and the list with every listed document required, plus a cost stop at the ceiling. This
   would be the second attempt at this level (rule 4).
3. **If neither passes:** the second opinion says (D). (P) with (A2), without a list, remains an untested lever the
   user may spend that second attempt on. The odds are uncertain. Stage 1 shows Claude does not reach for a
   language-wide rule unprompted, and (P) is the prompt.
4. **(A2) on its own, and a topic bar, are not recommended.**

Nothing is pre-registered here. The check follows the user's choice.

## Second opinion: Gemini 4 Argon (2026-10-26)

*Channel:*
- Antigravity CLI 1.4.7, model `gemini-4-argon-high`, plan mode, run in an empty folder holding only the brief.
- The brief was this note as first committed, plus public context: process rules 2, 4 and 5; D22's record from (A)'s
  attempt check to the stage-1 result; and the level-above note's bar section and option (A).
- Status SUCCESS after 301 s. Usage: 16,892 input tokens and 21,583 output tokens, 15,591 of them thinking.

Its points, and what was done with each:
- **The counts pooled what they should not.**
  - "3 of 15 directories" counted directories visited after R5's document was read, which the gate's own text sends
    elsewhere.
  - "25 of 29" counted calls inside one batch as reactions to a deny.
  - At the bar's event, the gate was tested in 1 run. *Taken:* re-tabulated by run and order.
    - Of 7 off-topic directories where a deny reached Claude before R5's document was read, R5's document was read in
      none, in 4 of 5 runs.
    - Of 20 messages holding a deny, 4 were followed by text.
- **"6 directories" against `gatecheck`'s 8.** *Taken:* both are right, and they count different things. The note now
  says which is which.
- **The argument that "a bar keyed to the writes that could break the rule is the outcome itself" equivocates.** It
  confused writes that break the rule with writes that put its system to use, which also include the new names.
  *Taken:* the argument is removed, and the tension is stated as scope against risk surface.
- **(T) is a goalpost move, the change-turn bar moved to files.** Both failed attempts pass it on seen data. *Taken:*
  it is struck as a bar and kept only as a narrower-claim variant of (D), with the second opinion's advice against it.
- **(S) is caught between recall and list length.** And a one-Read unlock lets Claude pick by topic from any list.
  *Taken:* every listed document must be read, the probe runs over the whole index of all three repos, its ceilings
  are fixed first, and the two matchers are tested apart.
- **The gate's own text anchored Claude on the directory and the change** and never asked for language-wide rules, so
  the note could not conclude that Claude cannot select them. *Taken:* that is option (P), and the note's account of
  what Claude chose by is qualified.
- **Granularity and titles were dropped from the registered reopen list.** *Taken in part.* Scope tags in index entries
  are matcher (S-b). Titles alone were set aside at the level above (they describe topic, not scope).
- **A cap fix needs a loop guard keyed to messages, not calls.** *Taken* in (A2).
- **Cost and R4 were underweighted.** A cap that holds raises cost further. *Taken:* the note says so, with R4's 4 of 5
  against 2.
- **Bias: for the second note running, a post-hoc subset that scores 4 of 5 was offered as a bar.** *Agreed.* The
  domain bar stays.
- **Its choice:** keep the domain bar; re-tabulate the saved streams (done above); run a corrected, pre-registered
  probe of (S) with both matchers; then one combined attempt (cap per message, the text fix, the list, a cost stop) if
  a selector proves viable, or (D) if not. *Taken* as the recommendation, with one difference. If the probe fails, the
  note leaves (P) with (A2) open to the user as the second attempt, since stage 1 never tested a text that asked for
  language-wide rules.
