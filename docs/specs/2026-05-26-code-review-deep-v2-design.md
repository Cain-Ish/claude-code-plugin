# Design: `code-review-deep` v2 — tiered models, architectural hybrid, leak mitigation

**Date:** 2026-05-26
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session
**Supersedes (extends):** `docs/specs/2026-05-25-code-review-deep-design.md` (v1)

## Summary

v1 shipped a 4-pass deep review with a flat model strategy: **everything except
orchestration runs on Haiku**, including Pass 2 (the per-unit deep review — the
actual reasoning step). Two problems surfaced in real use:

- **Problem A — wasted fan-out on docs.** Documentation-only changes still spawn
  per-unit Haiku reviewers that run the *runtime-bug taxonomy* (null handling,
  races, cross-file contracts) against prose. v1 only skips whitespace / import
  reorder / version bumps; docs are tagged `low` but still reviewed.
- **Problem B — the deepest pass runs on the weakest model.** Pass 2 is where code
  understanding happens, and it is Haiku. v1's design log (decision #4) chose this
  deliberately and deferred a Sonnet "hybrid" to "a possible v2." This *is* that v2.

v2 makes three changes:

1. **Tier Pass 2 by unit priority** — critical/high units review on Sonnet,
   medium on Haiku, docs-only units skip the bug pass, and an **early-exit** fires
   when every unit is docs-only. The scorer (Pass 3) stays Haiku.
2. **Add an architectural hybrid pass (Pass 2b)** — one holistic `quality-reviewer`
   (Sonnet) over the union of critical+high files, rendered as a separate,
   un-scored **advisory** section. This is the deferred-v1 hybrid, scoped so it does
   not drown the bug review or balloon cost.
3. **Mitigate the ghost-agent RAM buildup now, gate the root fix** — a concurrency
   wave cap and lean sub-agent returns reduce peak resource use regardless of root
   cause; a documented diagnostic protocol + conditional fixes resolve the specific
   leak once the test machine reports back.

A correction this design records for posterity: the prior in-session critique
claimed Pass 2's Haiku was an ad-hoc override ("the skill doesn't force a model, I
overrode to haiku"). That was wrong. Haiku is pinned in the agent frontmatter
(`agents/code-review-unit-reviewer.md`, `agents/code-review-scorer.md`) and was a
documented v1 decision. v2 changes the decision on its merits, not because v1 had a
bug.

## Goals

- Run the reasoning-heavy bug pass on a model strong enough for it, **without**
  paying Sonnet cost on changes that don't warrant it.
- Stop spending any review budget hunting runtime bugs in documentation.
- Add architectural critique (coupling, leaky abstractions, misplaced
  responsibility) on the highest-risk surface, kept clearly separate from — and
  never confused with — diff-scoped bug findings.
- Cut the peak agent/RAM footprint of a run, and lay out a defensible path to the
  root-cause leak fix once evidence is in hand.

## Non-goals (v2 — YAGNI)

- **No new reviewer agents.** Tiering reuses `code-review-unit-reviewer` with a
  per-dispatch model override; the architectural pass reuses `quality-reviewer`.
  (Fallback only if model override proves unsupported — see Open risks.)
- **No per-unit architectural fan-out.** Architecture is cross-cutting; it runs
  once over the union of critical+high files, not once per unit.
- **No scoring / FP-recording of architectural notes.** They are advisory prose,
  not confidence-ranked findings, and are never written to the false-positive store.
- **No speculative leak fix.** Skill-level mitigations ship now; the root-cause fix
  is implemented only after the test-machine diagnostic identifies the cause.
- **No `--force` override for the docs-only early-exit** in v2. If a docs-only deep
  review is ever wanted, add the flag then.

## Relationship to v1 and existing capability

| Component | v1 disposition | v2 disposition |
|-----------|----------------|----------------|
| `skills/code-review-deep/SKILL.md` | 4 passes, flat Haiku | Edited: tiering in Pass 2, new Pass 2b, early-exit, wave cap, output section, leak protocol |
| `agents/code-review-unit-reviewer.md` (Haiku) | per-unit worker | Reused; model chosen at dispatch. One-line "return findings only, no file bodies" tightening |
| `agents/code-review-scorer.md` (Haiku) | per-finding scorer | Unchanged |
| `agents/quality-reviewer.md` (Sonnet) | left out — "Sonnet fan-out costlier/slower; checklist is architecture-heavy" | **Now wired in** as the single holistic Pass 2b reviewer. Its architecture-heavy checklist is exactly what 2b wants |
| `~/.second-brain/review-false-positives.md` | FP store, scorer-read | Unchanged. Arch notes never appended here |
| `~/.second-brain/quality-rules.md` | read by quality-reviewer | Unchanged; complements the FP store in 2b |

## Architecture — passes (deltas from v1 in **bold**)

### Pass 0 — eligibility + context load
Unchanged from v1 (resolve scope/base/SHA, eligibility + sync guard, CLAUDE.md
discovery, change summary, second-brain reads, load FP store).

### Pass 1 — decomposition (Haiku) — **+ docs flag, + early-exit**
Group changed files into units and priority-tag them as in v1
(critical / high / medium / low). **Additions:**

- **`docs_only` flag per unit:** `true` when *every* file in the unit matches a
  documentation pattern — `*.md`, `*.mdx`, `*.txt`, `docs/**`, `*.rst`, or a
  comment-only diff. Config files (`*.json`, `*.yaml`, `*.toml`, dotfiles) are **not**
  docs — they stay `low` and keep the infra/config taxonomy, because config bugs are
  real (wrong default, malformed schema).
- Emit JSON per unit: `{"name","files","priority","skip","docs_only"}`.
- **Early-exit:** if every non-skipped unit has `docs_only: true`, **skip Passes 2,
  2b and 3** and jump to Pass 4 with the message:

      Change is documentation-only (<N> units, <M> files). Skipped deep bug review.

  followed by the one-line change summary. (Output still goes through Pass 4 so
  `--comment` and formatting are consistent.)

### Pass 2 — per-unit bug review (parallel) — **tiered model + wave cap + lean returns**
Dispatch the **same** `code-review-unit-reviewer` per non-skipped, non-`docs_only`
unit, with the model chosen by priority:

| Unit priority | Model |
|---------------|-------|
| critical | Sonnet |
| high | Sonnet |
| medium | Haiku |
| low (config) | Haiku |
| `docs_only` (any priority) | **skipped — not dispatched** |

- **Dispatch mechanism:** the orchestrator passes a per-call `model` override to the
  `Agent`/Task dispatch, which takes precedence over the agent's frontmatter
  `model: haiku`. No second agent file. (See Open risks for the fallback if a target
  Claude Code version does not honor the override.)
- **Wave cap:** dispatch in waves of **at most 5 concurrent** agents, not all-15-at-
  once. Order: critical/high (Sonnet) first, then medium/low (Haiku). Bounds peak
  agent count and RAM regardless of the leak's root cause.
- **Lean returns:** tighten the unit-reviewer instructions to *return only the
  structured findings with `file:line` references — never paste file bodies or large
  excerpts back to the orchestrator.* Bounds the context the orchestrator accumulates
  across units and runs.

Findings schema, taxonomy, and `is_migrated_code` are unchanged from v1.

### Pass 2b — architectural pass (NEW — parallel, advisory)
- **Trigger:** at least one `critical` or `high` unit exists (after the docs/skip
  filter). Otherwise skipped.
- **Dispatch:** **one** `quality-reviewer` (its frontmatter is already Sonnet) over
  the **deduped union of all critical+high unit files**. Runs **concurrently with
  Pass 2** — it depends only on Pass 1's unit list, not on Pass 2's findings, so it
  shares the wave budget but adds no serial latency.
- **Input:** the base ref, the change summary, and the critical+high file set, with
  an instruction to focus its architectural checklist on the *changed* surface (it
  may follow imports for context but reports on the change).
- **Output handling:** its `CRITICAL` / `WARNING` / `INFO` prose is collected
  verbatim and rendered in Pass 4 as a distinct **"Architectural notes (advisory)"**
  section. It is **not** deduped against bug findings, **not** scored by the Haiku
  scorer, **not** filtered by confidence, and **never** written to the FP store.

### Pass 3 — dedup + scoring + filter (Haiku) — unchanged
Operates on **bug findings only**. Architectural notes bypass this pass entirely.

### Pass 4 — output + FP write-back — **+ arch section**
- **Output order:** (1) numbered bug findings as in v1, then (2) the "Architectural
  notes (advisory)" section if Pass 2b ran. The docs-only early-exit produces only
  the early-exit message + summary.
- **`--comment`:** the arch notes are posted under a clearly labeled
  **"Architectural notes (advisory — not blocking)"** subhead, visually separated
  from the numbered bug list, so a reader never mistakes an architectural opinion for
  a confirmed bug.
- **FP write-back:** unchanged — auto-records only hard-killed (score ≤15) **bug**
  findings + user dismissals. Architectural notes are never recorded as FPs.

## Leak mitigation — ghost agents / RAM buildup

**Observed (test machine, not the dev box):** after 2–3 `code-review-deep` runs, RAM
fills with "ghost agents." At rest on the dev box there are no zombies, no detached
shells, normal RAM — so the buildup occurs *during/after* runs, not as a persistent
cross-session OS-process leak.

**Mechanism candidates (Claude Code subagents are not normally standalone OS
processes):**

- **(a) Recursive `claude --bare` extractors.** The second-brain Stop/PreCompact
  hook spawns an extractor per Stop event **in API-key mode** (in OAuth mode it
  queues instead). A heavy fan-out skill generates many agent/Stop events → many
  extractor processes. **Not a `code-review-deep` bug** — the skill merely triggers
  the hook's lifecycle. Prime suspect if the test machine has `ANTHROPIC_API_KEY` set.
- **(b) Orphaned MCP / node servers.** One `server.bundle.js` per session that never
  gets reaped, accumulating across sessions.
- **(c) Parent-context bloat.** The orchestrator retains every sub-agent transcript
  (up to 15 units × whole-file reads × multiple runs). Inherent to fan-out;
  largely harness-controlled.

**Ship now (cause-agnostic):** the **wave cap** (≤5 concurrent) and **lean returns**
(no file bodies) from Pass 2 directly reduce peak agent count and retained context —
they help under all three causes.

**Diagnostic protocol (run on the test machine right after 2–3 runs):**

```bash
# (a) recursive extractor processes — prime suspect
ps -eo pid,ppid,etimes,rss,args | grep -E "claude --bare|claude -p" | grep -v grep
echo "${ANTHROPIC_API_KEY:+API-KEY mode (hook SPAWNS)}${ANTHROPIC_API_KEY:-OAuth mode (hook QUEUES)}"

# (b) orphaned MCP/node servers
ps -eo pid,ppid,etimes,rss,args | grep server.bundle.js | grep -v grep

# (c) parent-context bloat — watch the single claude PID's RSS climb run-over-run
ps -eo pid,rss,args | grep -E "claude --dangerously|claude$" | grep -v grep
```

**Gated root fix (implement the branch the diagnostic confirms):**

- **(a):** throttle/serialize Stop-hook extractor spawns (cap concurrent
  `claude --bare`, or coalesce queued extractions). Lives in the second-brain hook
  layer, tracked as a follow-up to this spec — not in `SKILL.md`.
- **(b):** reap orphaned MCP/node servers on session end / detect-and-kill stale
  `server.bundle.js` whose parent claude has exited.
- **(c):** accept as inherent; the wave cap + lean returns are the mitigation. Revisit
  only if it remains material after (a)/(b) are ruled out.

## Degradation
Unchanged from v1: if subagent dispatch is unavailable, fall back to a single-context
review over the full diff (no fan-out, no parallel scoring, no Pass 2b) and say so.
The fallback runs on the session model. Second-brain reads + FP write-back still apply.

## Changed / new files

| Path | Kind | Change |
|------|------|--------|
| `skills/code-review-deep/SKILL.md` | orchestrator skill | Pass 1 docs flag + early-exit; Pass 2 tiering table + wave cap; new Pass 2b; Pass 4 arch section + `--comment` subhead; leak protocol note |
| `agents/code-review-unit-reviewer.md` | Haiku/Sonnet worker | One-line "return findings only, no file bodies" tightening. **No frontmatter model change** (model is set at dispatch) |
| `agents/quality-reviewer.md` | Sonnet critic | Reused as-is. No change required (verify its checklist instructions read sensibly when handed a changed-file set) |
| (follow-up, gated) second-brain hook layer | runtime | Extractor throttle / MCP reap — only if diagnostic points to (a)/(b) |

## Testing

Extend the existing frontmatter/wiring test (the one added in the v1 release gate) to
assert:

- Pass 2 tiering: critical/high → Sonnet, medium → Haiku, `docs_only` → not dispatched.
- Docs-only early-exit fires when all non-skipped units are `docs_only`.
- Wave-cap constant present and ≤5.
- Pass 2b triggers iff ≥1 critical/high unit; runs exactly one `quality-reviewer`.
- Architectural notes are excluded from scoring and from FP write-back.
- Unit-reviewer instructions contain the "no file bodies" return constraint.

Do not build/typecheck/run the app in the review itself — CI handles that (carried
from v1).

## Open risks

- **Model-override support (highest).** v2 assumes the Claude Code Task/Agent
  dispatch honors a per-call `model` override beating frontmatter (true in the dev
  harness). **Verify against the installed CC version in the plan.** If unsupported,
  fall back to two thin agent files (`code-review-unit-reviewer-sonnet` /
  `-haiku`) and select by priority — more files, same behavior.
- **quality-reviewer roaming.** It has `Bash/Grep/Glob` and can wander beyond the
  diff. Mitigated by passing the changed-file set + a "report on the change"
  instruction; acceptable because the section is explicitly advisory.
- **Cost creep on large changes.** Many critical/high units → many Sonnet calls.
  Mitigated by the wave cap and by medium/low staying Haiku. If it bites, a future
  cap on Sonnet-tier units can be added.
- **Advisory-vs-bug confusion.** A reader treating an architectural `INFO` as a
  required fix. Mitigated by the separate, explicitly-labeled section and the
  non-blocking `--comment` subhead.

## Decision log

1. Tier Pass 2 by unit priority (critical/high → Sonnet, medium/low → Haiku),
   scorer stays Haiku. Reverses v1 decision #4 on its merits.
2. Docs-only units skip the bug pass; all-docs change early-exits before fan-out.
3. Architectural hybrid = one holistic `quality-reviewer` over critical+high files,
   advisory and separate — not per-unit, not scored, not FP-recorded.
4. Model selection via per-dispatch override, not new agent files (fallback noted).
5. Leak: ship wave cap + lean returns now; gate the root-cause fix on the
   test-machine diagnostic; extractor/MCP fixes live outside `SKILL.md`.
