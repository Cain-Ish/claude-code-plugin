# Design: `code-review-deep` v2.1 — fix the gate, not the finder

**Date:** 2026-05-27
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session
**Extends:** `docs/specs/2026-05-26-code-review-deep-v2-design.md` (v2)

## Summary

v2 made the per-unit reviewer run on the best available model (Opus today) while
leaving the confidence scorer pinned to Haiku. In real use the reference GitLab
deep-review skill (`code-reviewer-anthropic-local-deep`) surfaces *critical* bugs
that our `code-review-deep` misses. Reading both pipelines end to end, the gap is
**not in how we hunt — it is in how we gate.**

The reference runs its per-unit reviewer and its confidence scorer at the **same
model weight** (both Haiku): a Haiku scorer can re-derive and confirm a Haiku
reviewer's finding. v2 upgraded only the reviewer to Opus and left the scorer on
Haiku, creating a **capability inversion**: a weak scorer is asked to verify a
strong reviewer's subtle finds, cannot reconstruct the reasoning, and (per its own
rubric) scores them 25–50 = "might be real, unverified." Pass 3 then **drops the
16–69 band entirely**, so the bug vanishes with no trace. The harder and more
subtle the bug — exactly the cross-file finds we tell the reviewer are "highest
value" — the more reliably it dies at the gate. Counterintuitively, raising only
the reviewer's model can *lower* the reported count.

Two secondary mechanisms widen the gap over time:

- The **false-positive auto-record ratchet** (Pass 4) writes every ≤15 kill as a
  *permanent* suppression pattern. A single bad kill silently buries that class of
  bug forever. The reference has no FP store at all.
- The reference orchestrates inside a **forked Sonnet context at `effort: high`**;
  ours orchestrates inline at the session default.

This design fixes the gate and surfaces what it was eating, without sacrificing
v2's enhancements (best-model reviewer, second-brain reads, advisory architectural
pass, wave cap, lean returns).

## Goals

- The gate (scorer) operates at the reviewer's level, so it can confirm — rather
  than discard — the reviewer's subtle critical finds.
- No real finding disappears without a trace: the previously-dropped 16–69 band is
  surfaced as a clearly-labeled, lower-confidence section, separate from the
  numbered confirmed bugs.
- The pipeline stops silently and permanently suppressing classes of bug.
- Make the gap *observable*: the surfaced band is the instrument that tells us, on
  the next real run, whether a miss was a gate problem (shows up in the band) or a
  reviewer problem (never appears at all).

## Non-goals (YAGNI)

- **No fork orchestration.** `context: fork` + `agent:` skill delegation is an
  unimplemented Claude Code feature (`anthropics/claude-code#17283`); on the
  installed CC version (2.1.152) the keys are silently ignored. The v2 plan already
  recorded `FORK = no`. Shipping it would no-op and mislead. Tracked as a deferral,
  not attempted. Leak mitigation stays the v2 wave cap + lean returns.
- **No orchestrator `effort: high`.** It lives on the (unavailable) forked
  orchestrator. N/A while inline.
- **No reviewer-side rework** (decomposition, checklist, coverage). If the surfaced
  band proves the misses are reviewer-side, that is a separate follow-up design.
- **No removal of the FP store.** It stays; it just no longer auto-populates.
- **No change to the reviewer model, second-brain reads, arch pass, wave cap, or
  lean returns.**

## Verified capability assumptions (carried from the v2 plan + this design)

- `MODEL_OVERRIDE = yes` — omitting `model:` on a dispatched agent inherits the
  session/parent model; a per-call `model:` overrides frontmatter. (Source: v2 plan
  Task 0, code.claude.com/docs/en/model-config.md.) This is the mechanism for the
  scorer fix: removing the scorer's `model: haiku` pin makes it inherit Opus.
  **Caveat:** if `CLAUDE_CODE_SUBAGENT_MODEL` is set it overrides both — routing
  assumes it is unset.
- `FORK = no` — see Non-goals.
- `EFFORT_ON_DISPATCH = TBD` — whether a dispatched agent honors an `effort:`
  frontmatter key is **not yet confirmed**. Resolved by a verify-first step
  (below) before change #2 lands.

## Changes

### Change 1 — Scorer inherits the session model (primary fix)

- **File:** `agents/code-review-scorer.md`
- **Edit:** delete the `model: haiku` frontmatter line so the scorer inherits the
  session model (Opus today), matching the unit-reviewer (which already inherits).
- **Why:** removes the capability inversion. A matched-weight scorer can verify the
  reviewer's subtle finds instead of scoring them "unverified" and feeding the drop.
- **Trade-off (accepted):** one inherited-model (Opus) call per *unique* finding.
  Cost lands on a small, short-prompt pass (one finding + the cited files), not the
  fan-out. Dedup in Pass 3 already bounds the count of unique findings scored.

### Change 2 — Unit-reviewer reasons harder (`effort: high`), verify-first

- **File:** `agents/code-review-unit-reviewer.md`
- **Edit:** add `effort: high` to the frontmatter (model still inherits — unchanged).
- **Gate:** land this **only if** the verify-first step confirms a dispatched agent
  honors `effort:`. If unconfirmed, drop change #2 and ship the other three; record
  the verdict in the implementation plan.
- **Why:** deepens the finder independently of fork. Complements the gate fix —
  more genuine finds, now that the gate can confirm them.

### Change 3 — Surface the 16–69 "uncertain" band

- **File:** `skills/code-review-deep/SKILL.md` (Pass 3 partition + Pass 4 output)
- **Pass 3:** keep the three-bucket partition, but the 16–69 "uncertain" bucket is
  **retained for output** instead of dropped:
  - `report` (≥70): numbered "confirmed" findings — unchanged headline list.
  - `low-confidence` (16–69): rendered in Pass 4 as a separate labeled section
    (was: dropped entirely).
  - `killed-hard` (≤15): not shown (and, per change #4, no longer auto-recorded).
- **Pass 4:** the output order is fixed as (1) numbered confirmed findings (≥70),
  (2) the lower-confidence section, (3) the advisory architectural notes (if Pass 2b
  ran). Render the lower-confidence material under a section titled
  **"Lower-confidence findings (unverified — may be false positives)"**, visually
  distinct from the numbered confirmed list and from the architectural notes, so the
  three are never confused. For `--comment`, post it under that same labeled subhead.
- **Why:** a real critical bug scored 60 stops vanishing; and the section is a
  diagnostic — it makes visible what the gate was eating, distinguishing gate misses
  (appear here) from reviewer misses (never appear).
- **Noise control:** ≥70 still drives the headline list, so the confirmed review
  does not get noisier; the lower-confidence material is explicitly fenced off.

### Change 4 — Remove the false-positive auto-record ratchet

- **File:** `skills/code-review-deep/SKILL.md` (Pass 4 false-positive write-back)
- **Edit:** stop auto-recording the killed-hard (≤15) bucket as false-positive
  patterns. Keep recording **only user-confirmed dismissals** (the "Mark any shown
  finding as a false positive?" path).
- **Why (asymmetry):** a wrong auto-suppression hides a real bug *indefinitely*; a
  *missing* FP entry merely means the finding is re-judged next run — cheap now that
  the scorer is matched-weight. The reference has no auto-population at all.
- **Kept:** the FP store, the scorer's reading of it, and user-dismissal recording.

## Relationship to v2

| Component | v2 | v2.1 |
|-----------|----|----|
| `agents/code-review-unit-reviewer.md` | inherits best model; lean returns | **+ `effort: high`** (verify-first) |
| `agents/code-review-scorer.md` | pinned Haiku | **`model: haiku` removed → inherits** |
| `skills/code-review-deep/SKILL.md` Pass 3 | 16–69 dropped | **16–69 retained for output** |
| `skills/code-review-deep/SKILL.md` Pass 4 | auto-records ≤15 as FP | **auto-record removed; user dismissals only** + new lower-confidence section |
| Reviewer model, 2nd-brain reads, arch pass, wave cap, lean returns | — | unchanged |
| Fork orchestration | deferred (`FORK = no`) | still deferred — one-line pointer to #17283 |

## Verify-first (implementation plan Task 0)

Dispatch `claude-code-guide`: *"In the current Claude Code release, does a dispatched
sub-agent honor an `effort:` frontmatter key (e.g. `effort: high`)? Cite the docs."*
Record `EFFORT_ON_DISPATCH = yes|no`. `yes` → change #2 lands; `no` → drop change #2.

## Testing

Extend `tests/test-code-review-deep.sh` (structural contract, not LLM output):

- Scorer has **no** `model:` frontmatter line (inherits). (Replaces the existing
  `code-review-scorer is Haiku` assertion, which this design reverses.)
- Unit-reviewer has `effort: high` — **only asserted if `EFFORT_ON_DISPATCH = yes`**;
  otherwise assert it is absent.
- The orchestrator renders a lower-confidence section distinct from the numbered
  confirmed list (grep for the section label) and the 16–69 bucket is no longer
  described as "dropped entirely."
- Pass 4 no longer auto-records killed-hard findings: the "Auto-record the
  killed-hard bucket" instruction is gone; the user-dismissal recording remains.

Do not build/typecheck/run the app in the review itself — CI handles that.

## Release plumbing

Matching the v2 plan's Task 6 pattern: bump `.claude-plugin/plugin.json`, add a
`skills/upgrade/SKILL.md` migration row (prompt-only change, no user state to
migrate), update the README catalog line, and run the standing deep-review release
gate (`/second-brain:code-review-deep` on the branch, no `--comment`) — which also
dogfoods this very change.

## Open risks

- **`effort:` support unconfirmed** — mitigated by the verify-first gate; change #2
  is droppable with no impact on the other three.
- **Scorer cost on large changes** — every unique finding now scores on Opus.
  Bounded by Pass 3 dedup and short scoring prompts; if it bites, a future per-run
  cap on scored findings can be added.
- **Most-provable-cause risk** — this fixes the gate. If a real run's
  lower-confidence section is empty *and* the reference still finds a critical bug
  ours misses, the cause is reviewer-side (decomposition/coverage) — a separate
  design. The surfaced band is the instrument that decides this.

## Decision log

1. Fix the gate, keep the finder's edge — chosen over a full reference port that
   would drop Opus reviewers and second-brain integration.
2. Scorer **inherits** the session model (matches the reviewer) — chosen over a
   Sonnet pin, to fully eliminate the capability inversion.
3. The 16–69 band is **surfaced** as a separate lower-confidence section — chosen
   over lowering the ≥70 threshold (which would noise up the headline list).
4. FP auto-record **removed**; user dismissals **kept** — the suppression asymmetry
   favors re-judging over permanent silent suppression.
5. `effort: high` on the reviewer — included **verify-first**; droppable.
6. Fork orchestration — **deferred** on `anthropics/claude-code#17283`; documented,
   not attempted.
