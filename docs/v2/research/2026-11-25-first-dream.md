# The first dream in this repo (2026-11-25, plugin 2.5.1, Windows)

The first real `/second-brain:dream` run on this repo's own sessions, and the review after it. This note is the starting point
for the plugin's next fixes and field checks. Sources: the run itself, `scripts/dream.mjs` of 2.5.1 (`finish`,
`restore`) and the dream skill's text. Counts only: no transcript quotes.

## Result

- **Read:** 8 sessions, 2026-10-23 to 2026-11-25. 8 analyzer subagents.
- **Proposed:** 2 entries in `.project-map/decisions.md` (`reuse-existing-no-overengineering`, `skip-linux-for-now`)
  and 1 skill draft (`field-check`). None dropped by finish's checks.
- **Review:** both entries accepted, the skill promoted to `.claude/skills/field-check/SKILL.md`.
- **Left out:** about 20 analyzer candidates.
  - Most were v2 ledger choices (D14, D18, D22, D24, D29) or plan changes already in `06-first-slice.md`. In this repo,
    decisions live in `DECISIONS.md`, so they had a home already.
  - The rest were one-off approvals.
  - One product direction (setup runs once, then the plugin keeps itself up to date) was not found in those words in the
    charter or the ledger.
- **Topic files no session read:** none.

## Findings

1. **Finish is not atomic.**
   - Finish writes the proposals and the log line, and only then removes the run folder. On Windows the removal
     failed (EPERM), because another process held a folder inside `.project-map/.dream-run/`.
   - Finish threw before it saved its state and released the lock, and printed no report.
   - The skill's advice for a failure is abort, which would have reverted the proposals. Recovery took reading
     the code.
2. **A retried finish is safe only before review, and nothing says so.**
   - A retry puts the watched files back from the snapshot, then applies the proposals again. So it undoes any
     review edits made since.
   - Restore removes a draft's file but not its folder, so the retry writes the draft to `<name>-2/`, unless that
     folder is deleted first.
   - Done in that order (folder deleted, retry before review), the retry's result equalled the first one, byte for byte.
3. **Who held the folder.**
   - One holder: a background job of another Claude session in this repo, with its working folder in
     `.dream-run`.
   - A second handle, on `proposals/skills`, outlasted that job. Its holder was never identified: Resource Monitor
     showed none, and the folder was free on the next try.
   - An in-repo probe that wrote a `SKILL.md` did not lock its folder. So the first guess, that Claude Code locks skill
     folders it writes, is not supported.
   - Any process that sits in the run folder can stop a finish. Several sessions sharing one repo make that likely.
4. **Finish adds `disable-model-invocation: true` to every skill draft. The skill's text does not say so,** so the
   review offered a "Claude may call it on its own" choice that cannot happen.
5. **Digest lines carry no dates.** Each entry's date had to be inferred from the digest's range and from git history.
6. **Label noise.**
   - The read hook printed the same label block after every shell call that showed map entries.
   - That included the run's own staged proposals, which carry no review state, so their labels mean nothing.
7. **Cost.**
   - The 8 analyzers used about 610k tokens in all, for 2 entries and 1 draft.
   - Most of their candidates belonged to the ledger or the plan.
   - In a repo whose decisions live elsewhere, the analyzer could be told that home, and skip those candidates.
8. **One turn did not hold.**
   - The skill asks for every step in one turn. Here the analyzers ran in the background, and each one reported back
     as a new turn.
   - Finish ran several turns later and was not refused. The skill's warning that its grant ends with the turn did not
     bite in this mode.

## What to carry into the next release

- Make finish's cleanup failure recoverable:
  - remove the run folder last, or tolerate its failure;
  - always save state and release the lock;
  - print the report.
- Tell the user, in the report and in the skill, that a retry must come before review.
- Make a retry clear the folder of a draft it is about to rewrite.
- State the `disable-model-invocation` rule in the skill text.
- Put a date on each digest line, or on each user line.
- Keep the label hook off `.dream-run/`, and repeat a label block only when it changed.
- Give the analyzer the repo's decision home (here `docs/v2/DECISIONS.md`), so ledger items are not proposed for the map.
