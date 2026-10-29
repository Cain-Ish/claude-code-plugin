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
| C1 | Arrival (D12) | each epoch start carries the plugin's `SessionStart` context, holding the frozen capture instruction's first sentence | every epoch; a miss is a defect |
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
| C5 | 2 of 2 Read-tool map reads labelled, every entry "unreviewed, not yet committed". **5 more reads of map entries went through Bash, unlabelled** (10 before the correction below); 8 map writes went through Bash | pass, see observations |
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
- *D14 (C5):* 5 of 7 reads of map entries arrived through Bash, unlabelled, while every entry was uncommitted. 04 lists
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

**Corrected after the run (2026-10-29), C5's count of Bash reads.** The scanner called a Bash command a map read when
it mentioned `.project-map` and held a read verb anywhere in the line. Shaping D14's candidate hook meant reading the
commands themselves, and 5 of the 10 showed no map entry: a folder listing piped to `head`, a file count over several
folders, a size check beside a `grep` of another file, a commit that excludes the folder, and a `cat` into a scratch
file. `field.mjs` now needs the read verb and the folder in the same command; the re-run gives 5 reads, the hand count,
and every other count is unchanged. The 5: one `cat` of the whole file, one `grep` of its headings, and three `tail`s
of its end, each just after Claude appended to it. No map read went through the Grep tool. C5's verdict does not change.
