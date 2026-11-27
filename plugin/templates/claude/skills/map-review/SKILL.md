---
name: map-review
description: Reviews the team memory in .project-map/ with the user. It accepts or rejects a dream's proposals, promotes draft rules, skills and agents and changes to them, and settles entries due for review. Use when proposals, drafts or due entries wait and the user agrees to review them.
---
# Review the team memory

Work through each list with the user, one item at a time. Done when every list is empty or the user stops. Run its
commands with the Bash tool, never PowerShell.

1. **Proposals.** Entries with a `- proposed: dream <date>` line (grep `.project-map/`). Show each one, with the
   dream's reason if this session has the dream's report. Wait for the user's answer before any edit.
   - Accept: replace the line with `- origin: dream <date>` and add `- verified: <today> accepted in review`.
   - Reject: delete the entry if it is not yet committed. If it is committed, replace its `proposed` line with
     `- status: expired <today> by review: rejected`.
   - A committed entry that a dream gave a `- status:` line is a proposal about that line only. Accept: replace the
     `proposed` line as above. Reject: delete the status line and the `proposed` line, and leave the entry as it was.
2. **Drafts.** Files named `.claude/rules/*.md.draft`, `.claude/skills/*/SKILL.md.draft` and
   `.claude/agents/*.md.draft`. Show each one, and wait for the user's answer before any edit.
   - A draft beside a file of the same name without `.draft` is a change to that file: show it as a diff against
     the file (`git diff --no-index <file> <file>.draft`).
   - Its trial, before the question: read `.project-map/.trial/<name>.json` for the case file whose `artifact` is
     this draft. Say its verdict and counts. If it has no `blobs`, or `git hash-object <file>` of a file its `blobs`
     names no longer equals the id there, call it stale. "Not judged" means a session failed or the case that should
     not use it failed anyway: say so. With no verdict, call the draft untested.
   - A draft that is untested, stale or not judged is not offered for promotion: each is tested against a run without
     it before anyone keeps it. Offer only the line that tests it: `/second-brain:tailor show <name>`, or, with no
     case file `.project-map/evals/<name>.json`, `/second-brain:tailor cases <the draft's path>`, which writes its
     cases first.
   - Promote, on a current verdict and the user's yes: rename it without `.draft`,
     which replaces the file a change draft sits beside. Claude Code loads it from the next session.
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
   committed. Offer to commit only the files this review changed, and `.project-map/dreams.md` when it holds a dream's
   log line not yet committed (the next dream waits for that commit), so other work on the branch stays as it is:
   `git add <those files> && git commit -m "Review the team memory" -- <those files>`. Before it, show any change in
   those files that this review did not make (`git diff HEAD -- <those files>`), and commit a file that holds one
   only on the user's yes.
