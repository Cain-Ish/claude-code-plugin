---
name: recurring-breaks
description: Breaks that came back across decision checks of docs/v2/06-first-slice.md steps; read before judging a new step
metadata:
  type: project
---

- A step's registered promises go missing from its record: 4c (the step table's smoke, absent from its checks), 4h (decision-checker before each decision-touching fix; section 4's agy verifier on hook changes; line count "down, or each added line named"), 4j (section 4's copy rule: no in-place note as 4b/4c carried), 7a (section 6's "For the next release": setup.mjs lines 2 and 111 stale comments, not carried), 8a (the same setup.mjs comments again; check 1's "a failing case per finding" missing for D-4 and F-1), 8c (N1's "corrections" and subagent-transcript counts narrowed with no reason given; 8a's CI-on-three-systems check dropped; no "D31 holds" line like 8a's), 8c's build (the README's steering how-to registered, not built; pruning built with no case or mutation), 8d's draft (retirement, assigned by N3, the agreed list and 8c's "Not here", dropped silently; 8c's no-hook-output check, "D31 holds" block, README line and mutate's "exits non-zero" not carried). Check the registration's How list, the section's Rules, and the previous section's "for the next release" items, not only its Checks list.
- A skill step that runs after a turn boundary (a user's yes, a background wait) loses the skill's one-turn `allowed-tools` grant: S7 attempt 1 (dream finish), then 7a's amendment (tailor asks, then `trial.mjs run` after the yes). Ask where the grant comes from in the new turn.
- A build that differs from its registration's wording is offered as "deviations" without the attempt order (8a: H3, H4, H5). Ask whether each assertion was written before its first run; rule 2 turns on that, and the diff cannot show it.
- The diff handed in can lag the candidate (8c: SKILL.md step 2's steering exclusion on disk, absent from the patch). Read the candidate's changed files whole, not only the hunks.
- The copy rule (project CLAUDE.md: a plugin/ change runs from a copy until its checks pass) recorded nowhere: 4j, then section 6 (2.5.1). Sections 5 and 6 carry no Rules block; grep the section for "in place|from a copy" every time.
