# What the map is for when Claude pulls (2026-10-22)

**Why this note.** D22's leading route has no selector and pushes no rule text. Claude reads the repo's own
documents from an always-on index, after a forced decision per directory. Every earlier delivery decision assumed
the opposite: converted entries pushed by a hook. Rule 9 sends a false assumption back to the decisions resting on
it. This note lists them, with the ledger lines that create each tension, and what the evidence says for each part
of the map. It is written before D22 locks, and the compaction check's result decides one open point (section 4).
P1 and P2 are private repos, named by count only.

## 1. The premise that changed

- **Before:** "Claude always sees a small index and reads a branch of the map only when the task touches it"
  (charter). The ledger built that as push: the map's entries chosen by a selector and delivered by a hook within
  8 KB (D13, D22's question).
- **Measured:**
  - every push selector failed on reach (D22: attempt 1, runs 2 and 3, the high-recall count);
  - an unforced index failed (`p`);
  - a forced decision over an index of the documents worked on both build tasks (`pf`, P2 with the web on), reading
    39 to 147 KB of documents per session.
- **So:** the charter's sentence holds, but the branch Claude reads is the source document, and Claude is the
  selector.

## 2. The decisions this touches

| Decision | What it assumed | What changed | Trigger |
| --- | --- | --- | --- |
| D13 (entry and budget) | entries are the delivered unit, at most 8 KB per task; option (c), an always-on index Claude chooses from, rejected without a run | the delivered unit is the source document, read by Claude; the index is the always-on part | "A selector reaches D22's pass on the sources' own blocks": in substance, yes. Claude picked from the index and passed D22's end-to-end check on the sources' own text |
| D15 (onboarding converts everything) | push selection needs entries | the leading route uses no entry | none of its listed triggers; rule 9 (rethink 2 already marked it "Tension: worth depends on D22's route") |
| D18 (runtime and surface) | `SessionStart` carries 904 bytes; `PostToolUse` after a Read is D22's slot | `SessionStart` also carries the index (2 KB in P1, 6 KB in P2), on `startup` and `compact`; `UserPromptSubmit` carries the forced text; the Read slot is unused | none fired: the index hook ran in 16 to 45 ms |
| D14 and D16 (guards) | every delivery passes one guard function: the unreviewed label, the re-find | Claude reads documents directly, with no guard on that path; captured entries in `.project-map/` would be read the same way, unlabelled | none fired yet; a design gap to close in the architecture |
| D20 (adherence) | rule text delivered at the prompt; pattern checks written at onboarding | rule text arrives by Claude's read; nothing writes the checks (D15 makes none; D18: "Stop and D20's pattern checks are not built") | depends on the compaction check (D20's trigger: a rule lost after a compaction) |
| D21 (no inventory) | no index of what exists | the pull index uses the same script over document files | none: it routes to knowledge, it does not list code for reuse. The line needs stating |

## 3. Each part of the map under pull

- **The index.** Always on, mechanical, from git's file list. It is a routing aid, not D21's inventory.
  - Open: per-directory lines only, or a one-line description per document? Descriptions would cost a model pass at
    onboarding.
  - Open: how the index scales to hundreds of directories. The forced decision reads every directory marked yes, and
    at scale that over-reads (Gemini's review).
- **Captured knowledge (D14).** What a session decided and no document holds. Under pull it is one more set of
  Markdown files in the index. D14's unreviewed label then has to reach Claude another way: an index line that
  marks uncommitted map files, or a header in the file.
- **Converted entries (D15).** Not needed for delivery under pull. Remaining uses, each to be shown before it is
  kept:
  - re-pinning after a compaction, if what was read does not survive it (section 4);
  - D16's freshness, which labels entries whose source changed. Under pull, Claude reads the source itself, so there
    is nothing to drift;
  - the source of D20's checks, if onboarding writes checks from entries.
- **Checks (D20's net).** Still needed to *hold* Claude to a rule after the write. Nothing builds them yet.
  Onboarding's job could shrink to: build the index, and write checks for the rules that can be checked.

## 4. The compaction check decided the open point

- **Result:** `pfc` (the index re-sent after `/compact`, the forced decision once) lost P2's R7 in 2 of 5 sessions.
  `pfr` (the forced decision again at the first prompt after the compaction) held every in-scope rule on both tasks
  ([DECISIONS.md](../DECISIONS.md), V2-D22).
- **So re-reading is needed, and it is done by re-forcing, not by re-pinning entries.** Converted entries still have
  no delivery role.
- **The price** is tokens in the document-heavy repo: about three times push's, mostly subagent research. In P1 it
  is nothing.

## 5. Second opinion (Gemini, 2026-10-22)

Two attempts on Gemini's top model (Argon, high thinking) errored, once on this note in full and once in a fresh
chat. The answer below is from 3.1 Pro, on a short version of the brief (counts only). It is short, and it is
weighed as such.

- **Drop the verbatim conversion; keep at most a one-line description per directory.** The first half matches section
  3. Gemini's own falsifier for the second half has already run: the index that worked was raw directory and file
  names, with no descriptions. So descriptions are not needed at the measured scale.
- **Make the index hierarchical, with recursive lookup.** Not taken. The literature in rethink 2 found that a second
  routing level never helped, and a flat index worked at 45 directories. Scale is a reopen trigger on D22 instead.
- **Mark unreviewed captured files when Claude reads them.** Use the read hook (`PostToolUse` after a Read) to check
  the file's git status and add the label. Taken for the architecture step. It fits D18's existing slot.
- **Post-write checks by an LLM judge on the diff, with the rules Claude read.** Not taken now. A model call per write
  breaks D18's hook budget, and D20 chose data patterns and the project's own linters. It stays an option for
  `Stop`, where one call per session might fit, as a D20 question.

## 6. Next steps, after D22's lock (2026-10-22)

1. D13, reopened by rule 9 (its own trigger was written against the retired pass, so it is not claimed). Decide what
   an entry is for: captured knowledge and checks are the candidates. Decide whether the per-task delivery budget
   gives way to the index's always-on bytes.
2. D15, reopened by rule 9. Decide what onboarding produces under pull: the index, checks, entries, or a subset. Then
   the charter's onboarding sentence (the user's) is settled with it.
3. Close the guard gap (D14, D16) in the architecture: how an unreviewed captured entry is marked when Claude reads
   it.
4. Then write `04-architecture.md` from the locked set, and take the whole concept to the phase gate (devils-advocate
   and Gemini).
