# Design: `code-review-deep` history/regression lens

**Date:** 2026-05-27
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session
**Extends:** `docs/specs/2026-05-27-code-review-deep-v2.1-gate-fix-design.md` (v2.1)
**Target release:** 0.19.0

## Summary

An audit of the upstream single-pass reference (`code-reviewer-anthropic-local`)
against our deep skill found a bug class our pipeline **structurally cannot see**.
The reference fans out five role-based lenses; lens #3 runs `git blame` + `git log`
to catch bugs *in light of history* — a change that reverts a prior fix,
re-introduces a previously-corrected bug, or contradicts the documented reason a
line exists. Our per-unit reviewer's tools are `Read, Bash(git diff *)` only — no
`blame`, no `log` — and no checklist item asks for history. The orchestrator has
`git log`/`git blame` granted but uses only `log` for the change summary.

This is the same failure *shape* as the v2.1 gate inversion, one level out: not
"found but discarded" but "never had the capability to find." v2.1 fixed the gate;
this adds the missing capability.

The fix is a dedicated **history/regression lens**: one agent that walks history
over the changed code, modelled on the reference's lens #3, producing scored bug
findings (not advisory notes). A regression is a real bug, so its findings flow
through the same dedup → scoring → confirmed/lower-confidence path as everything
else.

## Goals

- Catch the regression bug class: reverts of prior fixes, re-introduced known bugs,
  changes contradicting the historical reason a line exists.
- Keep it cost-bounded: one agent per run, not per unit.
- Keep the per-unit reviewer focused (it stays `Read` + `git diff`).
- Ensure the gate can actually *confirm* a regression finding — apply the v2.1
  lesson to tools, not just model.

## Non-goals (YAGNI)

- **No per-unit history scan.** History is cross-cutting; one lens over the union,
  not N reviewers each running blame/log (chosen over augmenting the unit-reviewer).
- **No advisory treatment.** Regression findings are bugs — scored and reported, not
  a separate advisory section like the architectural notes.
- **No history lens on docs.** Prose has no regression history worth blame-walking.
- **No new git tooling beyond log/blame.** Read-only history is sufficient.
- **No port of the single-pass reference's other lenses** (human PR-review-comment
  read, inline-comment compliance) — those are separate audit findings (B, C),
  deferred.

## Architecture

### New agent — `agents/code-review-history-reviewer.md`

- **Frontmatter:** `name`, `description`, `color`, `effort: high`, **no `model:` pin**
  (inherits the session/best model, like the unit-reviewer). Tools:
  `Read, Bash(git diff *), Bash(git log *), Bash(git blame *)` (read-only git — same
  trust posture as `quality-reviewer`).
- **Input (from the orchestrator):** the union of all non-skipped **code**
  (`docs_only: false`) unit files; the base ref `origin/<base>`; the change summary;
  the combined project conventions (CLAUDE.md + wiki); and the episodic prior-review
  note.
- **Task:** for the changed code, use `git blame`/`git log` on the touched lines and
  their surrounding context to find:
  - changes that **revert or re-introduce** a previously-fixed bug (the prior fix is
    visible in history),
  - changes that **contradict the historical reason** a line exists (e.g. removing a
    guard a past commit added deliberately),
  - repeated mistakes history shows were already corrected elsewhere.
- **Output:** the **same structured finding schema** as the unit-reviewer, with a new
  category value `regression`. Scope strictly to lines changed since `origin/<base>`
  — pre-existing issues on untouched lines are out of scope. Lean returns (cite
  `file:line` and the relevant commit short-SHA; never paste file bodies).

### Scorer change — `agents/code-review-scorer.md`

Add `Bash(git log *), Bash(git blame *)` to the scorer's tools (currently
`Read, Bash(git diff *)`). **Rationale (the v2.1 lesson, applied to tools):** to
confirm a claim like "this reverts the fix in commit `abc123`," the scorer must read
history. Without the tools it cannot verify regression findings, would score them
low, and they would fall into the lower-confidence band — the same
"can't-confirm-what-was-found" failure, one level down. Add a one-line scorer
instruction: *for `regression`/history findings, verify with `git log`/`git blame`
that the claimed prior fix or commit exists and that this change reverts or
contradicts it.*

### Skill changes — `skills/code-review-deep/SKILL.md`

- **New Pass 2c (per-unit-parallel, scored):** dispatch exactly ONE
  `Agent(subagent_type: "second-brain:code-review-history-reviewer")` over the deduped
  union of all non-skipped **code** unit files. Runs **concurrently with Pass 2 / Pass
  2b** — depends only on Pass 1's unit list, not on findings. **Trigger:** ≥1
  non-skipped code unit; skipped on docs-only changes. Its findings are **scored**
  (Pass 3), not advisory.
- **Wave-cap accounting:** Pass 2b (arch) and Pass 2c (history) each occupy one wave-1
  slot. Update the existing Pass 2b sentence so wave 1 holds **at most 3
  unit-reviewers + the architectural reviewer + the history reviewer** (≤5 concurrent
  total). The ≤5 cap is unchanged.
- **Pass 3:** unchanged mechanics — history findings dedup against unit findings (a
  bug found by both → keep the better-explained) and are scored like any other
  finding. Note that the scorer may now use `git log`/`git blame` to verify
  regression findings.
- **Categories:** the output may include `regression` alongside the existing
  categories.

### Data flow

```
Pass 1 (decompose) ─┬─► Pass 2  unit reviewers (per code/doc unit)        ─┐
                    ├─► Pass 2b quality-reviewer (advisory, crit+high)    ─┤ (concurrent,
                    └─► Pass 2c history-reviewer (scored, all code files) ─┘  wave-capped ≤5)
                                                                            │
   Pass 2 + 2c findings ──► Pass 3 dedup + score (scorer w/ log+blame) ──► confirmed / low-confidence
   Pass 2b notes ─────────────────────────────────────────────────────► advisory section (unscored)
```

## Testing (`tests/test-code-review-deep.sh`)

Structural contract, not LLM output:

- `code-review-history-reviewer` exists, has `name`/`description`, **no** `model:`
  pin (inherits), has `effort: high`, and its tools grant `git log` **and**
  `git blame`.
- The orchestrator **dispatches** `code-review-history-reviewer` (add to the
  dispatch want-list and the `subagent_type` resolve loop).
- The scorer's tools now grant `git log` **and** `git blame`.
- A Pass 2c section exists and triggers on code units (grep for the pass + the
  history dispatch).
- The wave cap is still asserted (`at most 5`); the updated wave-1 composition note
  is present.

Do not build/typecheck/run the app in the review itself — CI handles that.

## Release plumbing

- Bump `.claude-plugin/plugin.json` → `0.19.0`.
- Add a `skills/upgrade/SKILL.md` migration row (prompt/agent/test-only — no state
  migration).
- Update the README catalog line to mention the git-history regression lens.
- Run the standing deep-review release gate after the plugin cache refreshes to
  0.19.0 (so it dogfoods the new lens).

## Open risks

- **History lens cost on large changes.** One agent over the union of all code files
  could be a large blame/log walk. Bounded to a single agent (not per-unit) and
  scoped to changed lines; if it bites, a future cap (critical+high only, or a
  per-file blame budget) can be added. Accepted for now per the "all code files"
  scope decision.
- **Scorer history-verification depth.** The scorer now has the tools, but verifying
  a deep revert chain is itself reasoning work; mitigated because the scorer now
  inherits the best model (v2.1). Findings it still can't confirm land in the
  surfaced lower-confidence band — not dropped.
- **Dedup quality.** A logic bug found by both a unit reviewer and the history lens
  must dedup to one finding; relies on Pass 3 dedup keeping the better-explained one.
  Existing behavior; the new category just adds another source.

## Decision log

1. **Dedicated history lens**, not augmenting the per-unit reviewer — cost-bounded
   (one pass) and keeps the unit-reviewer focused; matches the reference's lens #3.
2. **Scope = all non-skipped code files** (not critical+high only) — regressions hide
   in medium/low files too, and one agent is bounded regardless of count.
3. **Findings scored as bugs**, not advisory — a regression is a real bug.
4. **Scorer gains `git log`/`git blame`** — the v2.1 lesson applied to tools: the gate
   must be able to confirm what the new lens finds, or it repeats the inversion.
5. **Separate release 0.19.0** off main (after v2.1/0.18.0 landed) — one concern per
   release.
