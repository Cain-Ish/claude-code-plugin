# V2-D22, after the gate failed stage 1

Written 2026-10-26, after option (A), the gate at the write, failed its stage-1 bar, and before any choice, check or
run. The user asked for the options written up, attacked by the second opinion, and then brought back for a choice.
The evidence is in D22's record in [../DECISIONS.md](../DECISIONS.md) and in
[2026-10-26-d22-level-above.md](2026-10-26-d22-level-above.md), which chose (A). New counts were taken from the saved
run streams on 2026-10-26. They are exploratory, and only counts are given. The second opinion is at the end.

## What failed

Stage 1 ran 5 Opus runs of P2 vague on the plugin copy, all valid.

- R5 failed in 0 of 5. The reference failed it in 4 of 5.
- The main session Read R5's document before its first C# write that went through in 0 of 5. The bar was 4.

The level-above note said: "If stage 1 fails because Claude names the wrong document at the write, timing is ruled out
as the cause, and the selector itself is what reopens." The failure has two halves, and only one of them is that.

| Half | What the streams show (calls grouped by the assistant message that made them) |
| --- | --- |
| **The cap** (a defect in the copy) | In 4 of 5 runs, the first C# writes came as one message of 4 edits. The hook sees each call before Claude sees any result: the first two were denied, the 2-deny cap let the rest through, and the writes landed before any deny reached Claude. Over all 21 directories gated in the 5 runs, 6 opened this way. The smoke had shown the same batch, and its record misnamed it as retries |
| **The choice** (the selector) | In the other 15 directories, a deny reached Claude and Claude Read at least one document before writing again (median 1). R5's document was among them in 3 of 15, all three at the directory of the new file the task asks for. At the first C# write, the gate reached Claude in one run (run 5), and Claude read two other documents |

More detail:

- After a deny, Claude went straight to a tool call in 25 of 29 cases. The line naming the binding documents appeared
  as text 4 times, and none of the 4 named R5's document.
- The main session read R5's document before writing the new file in 4 of 5 runs. In 3 of those, the read came right
  after that file's deny. In run 3 only a subagent read it.
- **What Claude chose by:** the topic of the file being written. R5 binds every C# file, but it is about one system,
  and Claude reached for its document only when the write was on that system.
- **Cost:** a median of 6 denies per run, against the note's estimate of 2 to 7 directories. The median cost was 6.44 USD
  against the reference's 4.24, so +2.20; the note estimated 1.2 to 2. One run, at 11.79, went above P2's ceiling of
  10.85.

## Where R5 is actually broken

The bar keys R5 to its check's path, every C# file, because the rule's text bans its old names anywhere in C#. The
runs on record show where the old names were actually written: every P2 build run of 2d and 2e (native and the plugin's
arms), rethink 4's attempt and stage 1.

- The old names were written in 16 of 35 runs of 2d and 2e.
  - In 15 of the 16, they were in the new file the task asks for. One of these also wrote them in a shared base class
    on the same system.
  - The other run wrote them only in that base class.
  - No run wrote them in a file off that system.
- Rethink 4's attempt and stage 1 never wrote them: 0 of 10 scored runs.
- **A bar keyed to the writes that could break the rule is the outcome itself.**
  - A write can break R5 only if it contains the old names' common stem.
  - In every run that followed R5, no write contained that stem. Such a bar passes those runs without anything to
    measure.
  - So it is not a mechanism bar.

## The bar question

Stage 1 stays failed (rule 2). Its bar was fixed before it ran. What follows is about the next attempt's bar, and it is
the user's call. The withdrawn change-turn bar is a warning against choosing a bar that passes data already seen.

- **The domain bar** (the current one) asks for R5's document before the first C# write of any kind. A selector that
  goes by topic cannot meet it at an off-topic write. Claude's own choice is such a selector, and so are titles or a
  search on the change's terms. Only a selector keyed to scope can meet it.
- **A topic bar** would ask for R5's document before the first write to a file on the system R5 is about.
  - Every violation on record falls inside it.
  - Exploratory counts under it, with the topic taken as the new file's directory plus the shared base class:
    - stage 1: 4 of 5;
    - rethink 4's attempt: 4 of 5 (it added no hook);
    - the 2e reference: 0 of 5;
    - the standard arm: 6 of 10.
  - So both failed attempts would have passed it. That is a reason to distrust it.
  - The topic was drawn here from where the violations landed. A real bar would need it fixed from the rule's text
    before any run, and a name-based definition would also catch files that only mention the system (for example, the
    population code that places these creatures). So the counts above depend on a definition that was not fixed in
    advance.

## Options

### (A2) Fix the cap, keep the domain bar

Every edit in a gated directory waits for a Read after a deny, so a batch of denies counts once.

- **Addresses:** the cap half only.
- **Predicted:** a fail. In the 15 directories where a deny reached Claude, R5's document was read in 3, and never at
  an off-topic write. The choice half is untouched.
- **Cost:** at least the +2.20 USD per P2 run measured, likely more, since no batch slips through.

### (S) A search keyed to scope, at the write

At a deny, the hook itself lists the index documents whose text names the written file's scope: its language or
extension, or a folder on its path. The deny's reason asks Claude to Read those.

- **Addresses:** the choice half under the domain bar, without relying on Claude's sense of topic. It is the "search"
  that the level-above note named for the case where (A) fails on selection.
- **Depends on** documents stating their scope in words a search can match, and on short lists. P2's rule folder holds
  13 documents and about 150 KB; P1's holds 29 and about 580 KB. A language-level match may list most of them, and
  reading them all at each epoch's first write is the read that already cannot be done at P1's size.
- **Check, rough shape:**
  - a static probe first, with no model calls (rule 5): for each build rule of P1, P2 and R0, does its document name a
    scope that covers its check's path? And how long is the list at each first C# write of stage 1, and is R5's
    document on it?
  - only if the probe passes: an attempt on a new copy (the cap fixed, the list in the deny), under the domain bar.
- **Cost:** a text scan in the hook (cacheable per epoch), plus the Reads the list asks for.

### (T) Key the guarantee to the rule's topic (the user's call)

Change what the plugin promises: a binding document is read before the first write on the system it is about, not
before every write its check covers.

- **For:**
  - every violation on record lies on the rule's topic;
  - it matches how Claude selects;
  - it may let a cheaper mechanism pass: rethink 4's re-gate at the prompt needed no fourth hook event.
- **Against:**
  - both failed attempts would have passed it, and the topic counts above use a definition drawn after the fact;
  - a rule whose scope is wider than its topic would be promised only on its topic. A real off-topic violation would
    then be outside the claim;
  - it reverses the domain bar that the second opinion proposed and the user accepted.
- **Check, rough shape:**
  - each rule's topic fixed from its own text before any run, by a rule written down first;
  - then a fresh attempt for each mechanism that competes: (A2), rethink 4's (c), or both;
  - stage 1 on P2 vague, then no loss across the shapes.

### (D) Narrow the claim

D22 re-locks on the route as it is, with no gate and 3 hook events. The vague first prompt and the task switch become
named weaknesses, with their numbers.

- **Cost:** none now.
- **Gives up:** R5 in the vague shape, held in 1 of 5 by the route against 5 of 5 with either later read. A symptom
  first and the change second is ordinary use (rethink 4).

## Recommendation: (S)'s static probe, then the user's call between (T) and (D)

- **(S)'s probe is the smallest check that can fail (rule 5).** It is the only option that keeps the bar and
  addresses the choice half. It costs minutes and no model runs.
- **(A2) alone is predicted to fail:** in the 15 directories where a deny reached Claude, R5's document was never
  read at an off-topic write. The cap fix belongs inside any later gate attempt, not on its own.
- **If the probe fails** (scope not stated in the documents, or lists too long to read), no selector on record can meet
  the domain bar. What remains is a choice of what the plugin promises:
  - (T) promises reads on the rule's topic, through a fresh attempt with the topic fixed in advance;
  - (D) promises the route as it is.
  
  Both are scope decisions, so they are the user's.
- The strike count: (A) was the first attempt at this level. Rule 4 does not yet block it.

Nothing is pre-registered here. The check follows the user's choice.

## Second opinion

*To be added after the run.*
