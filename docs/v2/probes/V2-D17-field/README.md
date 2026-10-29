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
