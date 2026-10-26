# How v2 decisions are made, checked and tracked

## Why this exists

v1 settled questions by argument. It wrote down the experiment that would decide its main question (concept S1: four
arms, 144 pre-registered runs) and never ran it, then built on the unsettled answer. Its audits re-checked the same
ground round after round. v2 runs a check at the moment it decides, and then stops re-deciding.

## The decision record

A record is a few bullets, not a form (see [DECISIONS.md](DECISIONS.md) for the shape). Id, question, status,
decider and parents sit in the ledger's status table; the bullets carry options, check and result, choice and
rejected, and reopen triggers. What each field means:

| Field | Rule |
| --- | --- |
| id | `V2-Dnn`, never renumbered or reused |
| question | One question that one check can answer. Two questions make two decisions |
| depends on | Parent decision ids. A decision cannot lock before its parents |
| decider | `evidence` (a probe, measurement or primary doc settles it) or `user` (a product or preference question) |
| options | At least two. Where it applies, one of them is "use what Claude Code already does" |
| check | Written **before** the result is known: what is run or read, and the pass condition. For a `user` decision, the check is the user's explicit answer, recorded with its date |
| result | What the check showed, with a link (probe folder, research note, doc URL) |
| choice / rejected | The chosen option, and each rejected option with its reason. The rejected half is what stops re-arguing |
| reopen if | Observable events that reopen the decision, for example "a Claude Code release changes when path rules load". Nothing else reopens it |
| attempts | Number of failed checks (rule 4) |
| status | `OPEN` → `CHECKING` → `LOCKED` or `REJECTED`; `DEFERRED` (with a trigger); `LOCKED` → `REOPENED` only when a trigger fires; `BLOCKED` after three strikes |

## Rules

1. **Check when deciding.** A decision is LOCKED only after its check passes. "We will validate later" means
   DEFERRED, not LOCKED, and nothing may depend on a deferred decision.
2. **Pre-register.** The pass condition is written before the check runs. Changing it after seeing the result counts
   as a failed attempt.
3. **Locked means settled.** Later work cites the id and builds on it. Reviews, new sessions and agents do not
   re-verify a LOCKED decision. They may only point at a reopen trigger that fired, with the observation.
   Disagreement without a fired trigger goes in the decision's issue as a comment and changes nothing.
4. **Three strikes, then go up a level.** When a check fails, change the option or the approach and try again. After
   the third failed attempt (a fourth only if the third was a near miss with a known cause), stop. Mark the decision
   BLOCKED and reopen its parent decision, or the assumption that made every option fail. The same rule applies to
   any loop in this project (a probe, a fix, a design): three or four failed runs mean the framing is wrong, not the
   execution.
5. **Smallest check that can fail.** Prefer a primary-doc citation, then a probe (minutes), then a prototype
   (hours), then an eval (days). Use a bigger check only when a smaller one cannot tell the options apart.
6. **Order by leverage.** Next, decide the open decision whose answer changes the most other decisions.
7. **One home per fact.** Decisions live only in `DECISIONS.md`, research notes in `research/`, probes in `probes/`.
   GitHub issues hold the discussion and point at the ledger; they do not copy it.
8. **Review at the phase boundary, not per decision.** At the end of the concept phase, the `devils-advocate`
   workflow runs once over the whole concept. Each surviving finding either fires a reopen trigger (it is new
   evidence) or is recorded as an accepted risk. The review does not re-verify locked decisions.
9. **Step gate.** Work goes in small steps, one commit each. A step ends only when its commit body answers three
   lines: `Produced:` what this step made; `Doubted:` what was questioned and how it was settled, always including
   "is this over-built? what can be deleted?" and the assumptions the step rests on, each with how it was verified (a
   check that ran, a primary source) or marked unverified, and whether the result still serves the main idea in the
   charter. A step that finds an assumption false or the main idea lost goes back to the decision that rested on it
   (rule 4), even when its own check passed (user, 2026-10-20). `Next needs:` what the next step needs, and whether
   it is in place. A step whose next step is not ready is not done. `git log` on branch `v2` is the step journal.
10. **Second opinion where it pays.** For a contested decision, or at the phase gate, ask a different model
    (Gemini 4 Argon, through the Antigravity CLI: `agy -p` in plan mode, run in an empty folder that holds only the
    brief file; user, 2026-10-26) to attack the proposal. Give it only text that is public in this repo anyway. Its
    answer is evidence to weigh, not a vote.

## Where things live

All paths are on branch `v2`. The repo is public: tracked files hold no secrets, session ids, absolute local paths,
email addresses or transcript quotes.

| What | Where |
| --- | --- |
| The brief | `docs/v2/00-charter.md` |
| This process | `docs/v2/01-process.md` |
| Decision ledger | `docs/v2/DECISIONS.md` |
| v1 post-mortem | `docs/v2/02-v1-postmortem.md` |
| Next steps, open questions | The map issue (see below) |
| Step journal (produced / doubted / next needs) | Commit bodies on branch `v2` |
| Distilled research (sourced, scrubbed) | `docs/v2/research/YYYY-MM-DD-<topic>.md` |
| Raw research material | `docs/v2/research/raw/` (gitignored, local only) |
| Probes | `docs/v2/probes/<decision-id>-<name>/README.md`, plus small scripts |
| Discussion | One GitHub issue per decision, a child of the map issue |
| Status | The map issue (label `wayfinder:map`) and the milestone "v2 concept" |

## Session protocol

- **Start:** read `00-charter.md`, the status table in `DECISIONS.md` and the map issue. Take the frontier: the first
  OPEN decision whose parents are all LOCKED and that nobody is assigned to.
- **During:** one decision at a time. Write the check before running it. Save research to `research/` as it is
  found, not at the end of the session.
- **End:** update the decision record, tick the step and update "Decisions so far" and "Fog" in the map issue, and
  commit with the step gate in the body (rule 9).

## GitHub mapping

This follows the wayfinder conventions in [../agents/issue-tracker.md](../agents/issue-tracker.md).

- **One map issue** (labels `wayfinder:map`, `v2`; milestone "v2 concept") holding Next steps (checkboxes),
  Decisions so far (one line each, pointing at the ledger) and Fog (open questions). Step details live in commit
  bodies, not in the issue.
- **No child issues by default.** A ledger copied into issues drifts. Open one only when a decision needs a
  discussion the ledger cannot hold (an outside contributor, a long thread), titled `[V2-Dnn] <question>`, and close
  it when the decision locks.
