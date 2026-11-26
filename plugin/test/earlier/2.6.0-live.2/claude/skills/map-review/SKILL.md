---
name: map-review
description: Reviews the team memory in .project-map/ with the user. It accepts or rejects a dream's proposals, promotes draft rules, skills and agents and changes to them, and settles entries due for review. Use when proposals, drafts or due entries wait and the user agrees to review them.
---
# Review the team memory

Work through each list with the user, one item at a time. Done when every list is empty or the user stops.

1. **Proposals.** Entries with a `- proposed: dream <date>` line (grep `.project-map/`). Show each one, with the
   dream's reason if this session has the dream's report.
   - Accept: replace the line with `- origin: dream <date>` and add `- verified: <today> accepted in review`.
   - Reject: delete the entry if it is not yet committed. If it is committed, replace its `proposed` line with
     `- status: expired <today> by review: rejected`.
   - A committed entry that a dream gave a `- status:` line is a proposal about that line only. Accept: replace the
     `proposed` line as above. Reject: delete the status line and the `proposed` line, and leave the entry as it was.
2. **Drafts.** Files named `.claude/rules/*.md.draft`, `.claude/skills/*/SKILL.md.draft` and
   `.claude/agents/*.md.draft`. Show each one.
   - A draft beside a file of the same name without `.draft` is a change to that file: show it as a diff against
     the file (`git diff --no-index <file> <file>.draft`).
   - Its trial, before the question: read `.project-map/.trial/<name>.json` for the case file whose `artifact` is
     this draft. Say its verdict and counts. If `git hash-object <the draft>` or `git hash-object <the case file>` no
     longer equals its `artifactBlob` or `casesBlob`, call it stale. "Not judged" means a session failed or the case
     that should not use it failed anyway: say so, and offer nothing on it. With no verdict, call the draft untested,
     and name the line that tests it: `/second-brain:tailor show <name>`, or, with no case file
     `.project-map/evals/<name>.json`, `/second-brain:tailor cases <the draft's path>`, which writes its cases first.
   - Promote: rename it without `.draft`, which replaces the file a change draft sits beside. Claude Code loads it
     from the next session.
   - Discard: delete it. Its case file and checks (`.project-map/evals/<name>.json`, `.project-map/evals/checks/`)
     still name it: ask whether to delete them too, or keep them for a new draft at the same path.
   - A live skill, agent or rule whose own trial, not stale, says "adds nothing" or "hurts": offer to remove it.
     Remove it only on the user's yes.
3. **Due entries.** Entries whose `- review:` date has passed, and the stale entries a `/second-brain:status` report
   in this session listed. Ask whether each one still holds.
   - It holds: set `- verified:` to today with how it was confirmed, and set a new `- review:` date or remove the line.
   - It changed: update the quote or the source to what holds now, and set `- verified:` to today.
   - It ended: add `- status: expired <today> by review: <what still holds>`.
4. Show `git diff --stat`. Tell the user that committing is the review: an entry counts as reviewed once it is
   committed. Offer to commit only the files this review changed, so other work on the branch stays as it is:
   `git add <those files> && git commit -m "Review the team memory" -- <those files>`.
