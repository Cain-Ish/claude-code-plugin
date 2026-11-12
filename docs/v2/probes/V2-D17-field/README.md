# Field check: the released plugin in the user's own sessions

**Registered 2026-10-29, before any transcript's content was read.** The user asked that the plugin be shown to work
in their real sessions, not only in the eval's: where it fails, where Claude skips it, and where it invents. This
check reads the transcripts of the user's sessions in their other repo (unnamed here, as everywhere in tracked
files). It runs nothing and changes nothing.

## Corpus

- Every main-session transcript of that repo whose time span overlaps the plugin's install there. There are two:
  2026-10-26 07:37Z to 10-27 06:51Z, and 10-27 06:51Z to 10-29 06:12Z, on CLI 2.1.309 and 2.1.310. Their subagent
  transcripts are read for C9 only.
- The plugin ran from the v2 checkout's live files until 2026-10-29 00:52Z, and from the `v2.0.0-alpha.2` tag after.
  Each unit is attributed to the plugin commit live at its timestamp (`git log -- plugin/`).
- **Excluded:** units between 2026-10-26 11:35Z and 12:31Z (`071cd5a` to `716b4cc`), D22 rethink 4's experiment,
  which was never released.

## Units

- **Epoch:** from a session start (startup, resume, clear) or a compaction, to the next one.
- **Human prompt:** a user turn a person typed.
- **Machine turn:** a user turn that is not typed: a queued command, a task notification, a message from another
  session or agent, local command output.

## Checks

Thresholds are fixed here. "Defect" means one occurrence is enough: it is diagnosed, and fixed under its decision
with its own registered check, in a new release epoch.

| # | What | Measured | Pass |
| --- | --- | --- | --- |
| C1 | Arrival (D12) | each epoch start carries the plugin's `SessionStart` context, holding the frozen capture instruction's first sentence. *Amended 2026-11-12 (D24):* a resume whose hook printed the same text the restored conversation already holds passes, since Claude Code does not attach it again | every epoch; a miss is a defect |
| C2 | Force placement (D22) | the forced-decision text arrives as `UserPromptSubmit` context on the epoch's first human prompt, once | a force on a machine turn, a missing force, or a second force in one epoch: each a defect |
| C3 | Forced decision answered (D22) | in the turn that got the force, before its first Write, Edit or NotebookEdit (or by turn end), Claude states per index directory yes or no. A yes list plus an explicit "the rest no" counts. Judged by reading, against this rubric | at least 80% of forced epochs |
| C4 | Read before change (D22) | in answered epochs with at least one yes and a file change before the next human prompt: at least one document of every yes directory Read before the first change (lenient), and every document (strict, reported) | lenient at least 80% |
| C5 | Labels (D14, D16) | each main-session Read of a `.project-map/*.md` file whose entries the session wrote with no `git commit` between that write and the Read gets the plugin's `PostToolUse` context naming them unreviewed. Map files reached by Grep, Bash or a subagent are counted (D12's accepted risk) | every such Read; a miss is a defect |
| C6 | Capture (D14) | each entry written into `.project-map/` (main session and subagents): (a) the entry format of the instruction; (b) a session id, email address or absolute path in it; (c) its quote found verbatim (case, whitespace and Markdown markup ignored) in an earlier human prompt, tool result or hook context of the session. An entry not found is judged by reading: a paraphrase of a statement that is found, or **unsourced** (no such statement found) | (a) at least 90%; (b) zero; (c) zero unsourced |
| C7 | Named sources (D23) | each document or map path Claude names as a decision's source after a file change exists in the repo at the session's end, or was written in the session | zero invented |
| C8 | Hook errors (D18) | any error, timeout or Node message from the plugin's hooks | zero |
| C9 | Subagents (D12, D18) | subagents spawned; whether any received the index; their writes to repo files | reported only |

**In-claim epochs.** D22's claim covers changes named in an epoch's first prompt. C3 and C4 are reported for all
forced epochs and for in-claim epochs apart, and the 80% bars apply to in-claim epochs. An epoch is in-claim when its
first human prompt names a change or creation to make, judged by reading.

## Consequences, written now

- A defect in C1, C2, C5, C6b, C7 or C8: fixed in the plugin, with a check registered before the fix, in a new release.
- C3 or C4 below 80% on in-claim epochs: a trigger observation for D22 (Claude skips the forced decision in real use).
  It goes to the ledger and to a rethink under rule 4, not to a fix by assumption.
- C6c with any unsourced entry: a trigger observation for D14 (capture invents).
- C9 subagent writes to repo files: the observation for D18's `SubagentStart` trigger ("the first slice logs subagent
  use").

## Privacy

Results in tracked files are counts only. No quote, session id, repo name or absolute path. The per-unit record,
which holds judgments and short extracts for the reader's audit, stays in `docs/v2/research/raw/` (gitignored).

## Seen before this was registered (reported, not counted)

A census of record types, with no text read, showed for the two sessions together: 22 `SessionStart` hook successes
with 11 carrying context, 10 `UserPromptSubmit` contexts, 162 `PostToolUse` contexts, 9 compaction boundaries and 26
queued commands. Which plugin each belongs to was not looked at. The plugin's code was read in full in this session.

## Result (2026-10-29)

Scripts: `field.mjs` (counts), `c4.mjs` (C4, from the reader's judgments in `raw/field/judged.json`). Corrections made
to the scanner after its first run, before any result was used: the build of each unit (a pathspec bug), map captures
appended through Bash (`cat >> … <<EOF`), and a source path that exists on disk though untracked.

| # | Result | Verdict |
| --- | --- | --- |
| C1 | 10 of 10 epochs after the install carry the plugin's start and the index (11 directories). The one epoch without it began before the plugin was installed: its session says so and installs it mid-way | pass |
| C2 | 8 forces in 10 epochs; the 2 others had no prompt. **1 force landed on a message from another session**, the first turn after an automatic compaction. The next human prompt got none | **defect** |
| C3 | 7 of 7 forces on a human prompt answered per directory (5 of 5 in-claim). One answer left out 1 of 11 directories | pass |
| C4 | 3 in-claim epochs changed repo files in the forced turn. Each marked 6 to 8 directories yes (73 to 76 documents). Before the first change, the Read tool opened documents from 0 to 3 of them (0, 2 and 3 directories; 0 to 4 documents); counting Bash reads, natively loaded rule files and the root CLAUDE.md, 3 to 4. Lenient 0 of 3, strict 0 of 3 | **fail** |
| C5 | 2 of 2 Read-tool map reads labelled, every entry "unreviewed, not yet committed". **9 more reads of map entries went through Bash, unlabelled** (counted 10, then 5, before the corrections below); 8 map writes went through Bash | pass, see observations |
| C6 | 15 entries (8 appended through Bash). (a) 15 of 15 in format; (b) 0 with a session id, email or absolute path; (c) 11 verbatim, 4 not verbatim, all traced to the session: two joined statements of the owner, a yes to a question, and **two options the owner chose, whose descriptions (written by Claude) are quoted as the owner's words**. 0 unsourced | pass, see observations |
| C7 | 43 paths named after a change; 0 invented (one hit was a scratch file mentioned in passing, not a source) | pass |
| C8 | 0 hook errors | pass |
| C9 | 6 subagents; none received the index; none wrote a repo file | reported |

**Confound:** the trial's coordinating session told the user's session to leave the map uncommitted for the user's
review. The map stayed untracked through 13 commits, one of which excluded it by name. Whether Claude commits the map
unasked is not shown by this corpus.

**Observations, for the ledger:**
- *D22 (C2):* `UserPromptSubmit` also fires on a background subagent's report and on another session's message
  (Claude Code's hooks reference), and the plugin spends the epoch's force on the first such turn. A defect of the
  delivery, not of the decision: fixed in 06, 2i.
- *D22 (C4):* the forced answer marks whole directories yes, and the read stays partial. 2e found the same on P2 and
  D22's measure is the binding document read, not every yes directory, so C4 alone fires none of D22's triggers. Whether
  a rule in scope was missed for selection in these epochs was not judged.
- *D14 (C5):* 9 of 11 reads of map entries arrived through Bash, unlabelled, while every entry was uncommitted. 04 lists
  this channel as an accepted risk. D14's trigger "an injected entry is ever delivered without the unreviewed label",
  read literally, is met. The accepted risk turns out to be the common path.
- *D14 (C6):* an option the owner picks from Claude's question is captured with Claude's own option text as the owner's
  words. Nothing was invented, but the attribution is wider than the instruction's "in the words used".
- *D18 (C9):* subagents were used in 6 cases, the condition of the deferred `SubagentStart` trigger. None wrote a repo
  file.
- No compaction happened inside a turn with tools after it: all 9 compactions were automatic, at a prompt.

**Disclosed after the run:** C4's two open readings were fixed after the judgment pack had been printed and before
`c4.mjs` first ran. The primary reading is the Read tool, before the first write to a repo file. Every reading
reported (primary, any write, and the broad one with Bash reads, rule files and CLAUDE.md) gives 0 of 3, so the verdict
does not depend on the choice.

**Corrected after the run (2026-10-29), twice, C5's count of Bash reads.**
- *The first run* called a Bash command a map read when it mentioned `.project-map` and held a read verb anywhere,
  unless it looked like a write first. That gave 10.
- *A first correction* read only each command's first line and gave 5. It missed reads that end a longer command.
- *The commands read whole,* all 20 that name the folder: 9 show map entries. Each is one part of the command (between
  `|`, `;`, `&` or a line break) with a read verb that names a map file and does not redirect into the folder:
  - one `cat` of the whole file and one `grep` of its headings;
  - seven `tail`s of its end, each just after Claude wrote to it: three on their own, two closing a `cat >>` append,
    and two closing a Python edit.
- *The 11 that show none:* four appends, two folder listings, a file count, a size check, a commit that excludes the
  folder, a `cat` into a scratch file, and a Python script.
- `field.mjs` now counts by that rule; its re-run gives 9, the hand count, and every other count is unchanged. The
  first run's 10 held 5 false reads and missed 4 real ones. No map read went through the Grep tool. C5's verdict does
  not change.

## Later checks in the same repo

- **2026-11-03, 2i check 3 (the field re-check):** `field.mjs` on the sessions after the move to alpha.4. Result in
  [06](../../06-first-slice.md), "2i, check 3".
- **2026-11-03, step 17m (D22):** `field-scope.mjs`, (S-b) again beside Claude Code's own path delivery. Check and
  result in [DECISIONS.md](../../DECISIONS.md), D22.
- **2026-11-06, 2k's check 5:** both scanners on the sessions after the move to alpha.5. Result in
  [06](../../06-first-slice.md), "2k, check 5".

## 18b: the scanner on CLI 2.1.318 (registered 2026-11-06, before the change)

- *Why:* in 2k's check 5, CLI 2.1.318 recorded the `SessionStart` hook's command at a compaction as `command hook N`.
  - *C1* finds the plugin's start by its command, so it missed two starts. The result was corrected and disclosed
    there.
  - *C8* finds a plugin error the same way.
  - *C9* reads only `<session>/subagents/*.jsonl`. A workflow's agents sit in a folder below it, so it counted 1 of
    20. (06 says 21: the delegated reader counted the workflow's journal, which is a log and not an agent.)
  - *The build label* has said alpha.2 for every unit since 2026-10-29.
- *The changes:*
  1. *C1:* the plugin's start is a `SessionStart` hook success whose command names `hook.mjs` with `session-start`,
     or whose output holds the frozen instruction or the missing-Node message.
  2. *C8:* an error record is the plugin's when its command, or the error text it carries, names `hook.mjs`. Errors of
     any hook are counted too and printed beside it, so an error under a nameless command still shows.
  3. *C9:* agent transcripts (`agent-*.jsonl`) at any depth under the session's folder.
  4. *The build label:* the release the user's install ran, from the recorded moves.
     - alpha.2 from 2026-10-29 00:52:30Z;
     - alpha.3 from its tag's commit, 2026-10-29 19:51Z (its move was not recorded, and no session falls in that
       window);
     - alpha.4 from 20:26Z (the install record);
     - alpha.5 from 2026-11-03 17:05Z.
- *Pass:*
  - *On 2k's corpus* (the 2 sessions):
    - C1 4 of 4;
    - C2, C5, C6 and C7 equal the unchanged scanner's counts;
    - C8 0 plugin errors and 0 errors of any hook;
    - C9 20 subagents, none writing a repo file;
    - every unit labelled alpha.5.
  - *On every earlier main session in that repo* since 2026-10-26: each count other than the build label and C9
    equals the unchanged scanner's output. That output is saved to `research/raw/` before the change.

### 18b: result (2026-11-06): pass

- *2k's corpus:*
  - C1 is 4 of 4 (3 and 1), C9 is 20 subagents, none writing a repo file, and every unit is labelled alpha.5;
  - C8 is 0, and 0 for any hook;
  - C2, C5, C6 and C7 are unchanged.
- *The 4 earlier main sessions since 2026-10-26:* the only differences from the unchanged scanner's saved output are
  these:
  - the build label (alpha.4 for the 9 epochs after that move, where it said alpha.2);
  - C8's added count for any hook, 0 in each.

  C9 is unchanged, since they hold no nested agents.
- The before and after outputs are in `research/raw/` (gitignored).

## 2l: the alpha.6 move in the build label (2026-11-07)

- *Why:* the user's install moved to alpha.6 at 2026-11-06 22:08:21Z (the install record), and the scanner labelled
  later epochs alpha.5.
- *The change:* one entry in the move table, alpha.6 from that time.
- *Pass:* on a frozen copy of the one session that runs alpha.6, the scanner's output equals the unchanged
  scanner's in everything but the build label, and the epoch after the move is labelled alpha.6.
- *Result: pass.* Its two epochs are labelled alpha.5 (started 2026-11-06 16:32Z) and alpha.6 (resumed 2026-11-07
  11:50Z).

## Count 4 and after: C5 by output, and the loop (registered 2026-11-08, before the change)

- *Why:* count 3's miss, a `grep` with `|` inside quotes, was found by hand. `field.mjs` splits a command as the
  plugin did, so it missed the same forms. From alpha.8 (06, 2n) the plugin labels what a Bash command printed, and the
  scanner must not share that rule either.
- **C5b, by output.** For each main-session Bash call, the scanner looks in the result Claude saw for the map's
  entries. An entry is *seen* when one of its quote lines of at least 20 characters, without the `>` marker, or its
  heading text, is in that result. This is looser than the plugin's rule (the whole line, marker included), so the
  forms the plugin misses show up as misses here. The map's entries are the field repo's map files as they are at the
  count, plus the entries written in the session.
  - *Counted:* the calls that name the map folder and show an entry, and of their seen entries, those named in the
    call's `[project map]` context.
  - *Reported apart:* the calls that do not name the folder and show an entry (04's accepted risk).
  - *Each miss is read by hand:* a plugin defect (the result holds the entry's line as the file has it), an entry seen
    only in part (an accepted risk), or a scanner false hit. For alpha.8 epochs, a defect is C5's defect, as D24's
    amendment of 2026-11-08 says.
- *Pass for the change,* on count 3's frozen corpus:
  - every count the scanner printed at count 3 is unchanged;
  - C5b finds what was found by hand: 5 calls that name the folder show entries, 4 of them labelled. The miss is the
    `grep` at 00:32Z on 2026-11-08. One call that does not name the folder (a commit) shows an entry.
- **Primed epochs** follow D24's rule of 2026-11-08. They are marked by hand at each count, from the times the field
  session was asked, which 06 records.

### The loop, each count

1. *Freeze:* copy each main-session transcript of the field repo that changed since the last count, with its
   subagent folder, to `research/raw/2l-field/count<N>/`.
2. *Scan:* `node count.mjs <field repo> <frozen folder>` runs `field.mjs` and `field-scope.mjs` on the copies.
3. *Read:* the first human prompt of each new epoch (in-claim or not), C3 in each forced epoch, each C5b miss, and
   each C6c entry not found verbatim.
4. *Record:* 06, "D24's field count N", in counts only.
5. *Ask,* at most once per session, when the user asks or its work is done: the question below, by a cross-session
   message. Its answer stays outside the repo. The session is primed from then.
6. *Triage* each finding and each point of the answer (rule 3):
   - a defect is fixed under its decision: a check registered first, a new alpha, the user's install moved, and the
     session asked to run `/reload-plugins`;
   - an observation goes to its decision in the ledger;
   - a candidate goes to the map issue;
   - what is not this plugin's is said so.
7. The next count starts where this one froze.

*The question,* fixed so that answers compare across counts:

> Short answers, one line each. Do not change your work because of this question, and quote nothing from the map or
> your transcripts. Since <date>, how did the second-brain plugin work for you?
> (1) The directory question at your first prompt: did it change what you read?
> (2) The `[project map]` labels after a map read: useful, noise, or missing where you expected them?
> (3) Entries you added to `.project-map/`: about how many, and did any feel wrong to add?
> (4) What got in the way, or what did you need from it and not have?
> (5) Any hook error or odd output you saw?

## A second field repo (registered 2026-11-08, before the install)

- *Why:* the user asked for the plugin in their other active repo too. Its name stays out of tracked files, as the
  first one's does.
- The plugin is installed there at local scope, at the release the first repo runs, and moves with it.
- Its main-session transcripts from the install on are counted by the loop above, with `field.mjs` and
  `field-scope.mjs`, and reported apart. They are not D24's corpus, which names the first repo's sessions. A defect
  there is fixed under the same consequences.
