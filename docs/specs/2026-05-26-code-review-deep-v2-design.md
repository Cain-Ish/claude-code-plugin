# Design: `code-review-deep` v2 — best-model-for-code, Haiku-for-docs, arch hybrid, leak mitigation

**Date:** 2026-05-26
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session
**Supersedes (extends):** `docs/specs/2026-05-25-code-review-deep-design.md` (v1)

## Summary

v1 shipped a 4-pass deep review with a flat model strategy: **everything except
orchestration runs on Haiku**, including Pass 2 (the per-unit deep review — the
actual reasoning step). Two problems surfaced in real use:

- **Problem A — wasted fan-out on docs.** Documentation-only changes still spawn
  per-unit Haiku reviewers that run the *runtime-bug taxonomy* against prose, at the
  same model weight as real code.
- **Problem B — the deepest pass runs on the weakest model.** Pass 2 is where code
  understanding happens, and it is Haiku. v1's design log (decision #4) chose this
  deliberately and deferred a stronger-model "hybrid" to "a possible v2." This *is*
  that v2.

v2 makes three changes, modelled on the reference deep-reviewer skill/agents the user
validated ("those agents work good — add the same logic and flow"):

1. **Match the model to the work.** Code units review on the **inherited best model**
   (whatever the session runs — Opus today). Documentation units review on **Haiku**.
   Mechanical steps (decomposition, scoring) stay **Haiku**. There is **no priority
   tiering and no early-exit** — every change is reviewed; the lever is *which model*,
   not *whether*.
2. **Add an architectural hybrid pass (Pass 2b)** — one holistic `quality-reviewer`
   (Sonnet) over the union of critical+high files, rendered as a separate, un-scored
   **advisory** section. This is the deferred-v1 hybrid, scoped so it does not drown
   the bug review or balloon cost.
3. **Mitigate the ghost-agent RAM buildup now, gate the root fix** — a concurrency
   wave cap and lean sub-agent returns reduce peak resource use regardless of root
   cause; a documented diagnostic protocol + conditional fixes resolve the specific
   leak once the test machine reports back.

A correction this design records for posterity: the prior in-session critique claimed
Pass 2's Haiku was an ad-hoc override ("the skill doesn't force a model, I overrode to
haiku"). That was wrong. Haiku is pinned in the agent frontmatter
(`agents/code-review-unit-reviewer.md`, `agents/code-review-scorer.md`) and was a
documented v1 decision. v2 changes that decision on its merits.

## Goals

- Run the reasoning-heavy bug pass on the **best model available to the run**, so the
  pass where bugs hide is not throttled by a weak model.
- Keep documentation review **cheap** (Haiku) — docs don't need deep reasoning.
- Add architectural critique (coupling, leaky abstractions, misplaced
  responsibility) on the highest-risk surface, kept clearly separate from — and never
  confused with — diff-scoped bug findings.
- Cut the peak agent/RAM footprint of a run, and lay out a defensible path to the
  root-cause leak fix once evidence is in hand.

## Model strategy (the spine of v2)

| Step | Model | Mechanism |
|------|-------|-----------|
| Pass 0 orchestration | Sonnet (forked) **or** session model (inline) | fork-if-supported: a `deep-code-reviewer` orchestrator agent (Sonnet, `effort: high`) under `context: fork`; else inline in the session — see Orchestration below |
| Pass 0 mechanical helpers (eligibility, PR summary, CLAUDE.md discovery, Pass 4 re-check) | Haiku | Haiku agents — matches the reference's helper agents; keeps mechanical work off the expensive orchestrator |
| Pass 1 decomposition | Haiku | Haiku agent — mechanical grouping |
| Pass 2 **code** unit review | **inherited best model** | unit-reviewer frontmatter pin **removed** → inherits the session model; **no** per-call override |
| Pass 2 **doc** unit review | **Haiku** | orchestrator passes `model: haiku` override for `docs_only` units |
| Pass 2b architectural | Sonnet | `quality-reviewer` native frontmatter (advisory; deliberately not the top model — see risks) |
| Pass 3 scoring | Haiku | `code-review-scorer` frontmatter unchanged |

"Inherited best model" = the model the session is running (Opus 4.7 today, Sonnet if
the user runs it under Sonnet). This is faithful to "best available" and to the
reference agents, which inherit unless explicitly downgraded. We implement it by
**removing** the `model: haiku` pin from `code-review-unit-reviewer` so the default is
inherit, and **downgrading** only doc units (and the mechanical steps) to Haiku.

## Non-goals (v2 — YAGNI)

- **No priority-based model tiering.** Earlier drafts split critical/high→strong vs
  medium→Haiku; superseded by the simpler code-vs-docs split per the user directive.
- **No early-exit / skip for docs.** Docs are reviewed, just on Haiku. A docs-only PR
  still gets a (cheap) review.
- **No doc-specific checklist.** Doc units run the same taxonomy on Haiku, not a
  bespoke links/staleness linter. (Add later if Haiku-on-prose proves noisy.)
- **No new reviewer agents.** Code-vs-doc model selection is a frontmatter change +
  one per-call override; the architectural pass reuses `quality-reviewer`. (Fallback
  only if override proves unsupported — see Open risks.) The fork path *does* add one
  **orchestrator** agent (`deep-code-reviewer`) — not a reviewer — restoring the
  reference's structure.
- **No per-unit architectural fan-out.** Architecture is cross-cutting; it runs once
  over the union of critical+high files, not per unit.
- **No scoring / FP-recording of architectural notes.** Advisory prose, never written
  to the false-positive store.
- **No speculative leak fix.** Skill-level mitigations ship now; the root-cause fix is
  implemented only after the test-machine diagnostic identifies the cause.

## Relationship to v1 and existing capability

| Component | v1 disposition | v2 disposition |
|-----------|----------------|----------------|
| `skills/code-review-deep/SKILL.md` | 4 passes, flat Haiku | Edited: code-vs-doc model routing in Pass 2, new Pass 2b, wave cap, lean-return instruction, output section, leak protocol. Early-exit language removed |
| `agents/code-review-unit-reviewer.md` (Haiku) | per-unit worker | **`model: haiku` pin removed** → inherits best model. One-line "return findings only, no file bodies" tightening |
| `agents/code-review-scorer.md` (Haiku) | per-finding scorer | Unchanged (stays Haiku) |
| `agents/quality-reviewer.md` (Sonnet) | left out — "Sonnet fan-out costlier/slower; checklist architecture-heavy" | **Now wired in** as the single holistic Pass 2b reviewer |
| `~/.second-brain/review-false-positives.md` | FP store, scorer-read | Unchanged. Arch notes never appended here |
| `~/.second-brain/quality-rules.md` | read by quality-reviewer | Unchanged; complements the FP store in 2b |

## Orchestration — fork-if-supported (audit-driven)

The reference `code-reviewer-anthropic-local-deep` runs the entire review inside a
forked context via a dedicated `deep-code-reviewer` orchestrator agent (`context:
fork`, `model: sonnet`, `effort: high`). Our v1 port **dropped this** and orchestrates
inline in the session — so every per-unit sub-agent transcript accumulates in the
user's session, which is leak candidate **(c)**.

v2 restores it, gated on support:

- **Verify first** (plan step 0) that `context: fork` + an `agent:` entrypoint are
  honored for a second-brain skill on the installed Claude Code version.
- **If supported:** add a `deep-code-reviewer` orchestrator agent — `model: sonnet`,
  `effort: high`, tools `Read, Write, Agent, Bash(gh *), Bash(git *), Bash(grep *),
  Bash(find *)` plus `knowledge_search` + `episodic_search` MCP (Write + MCP are our
  second-brain additions the reference orchestrator lacks). The `SKILL.md` becomes a
  thin `context: fork` entrypoint delegating to it. Review context is isolated and
  discarded with the fork.
- **If unsupported:** keep inline orchestration + the wave cap + lean returns.
- A forked **Sonnet** orchestrator still spawns **best-model (Opus)** per-unit
  workers — sub-agent model is independent of the parent — so forking does not
  compromise best-model-for-code.

## Architecture — passes (deltas from v1 in **bold**)

### Pass 0 — eligibility + context load
Unchanged from v1 (resolve scope/base/SHA, eligibility + sync guard, CLAUDE.md
discovery, change summary, second-brain reads, load FP store).

### Pass 1 — decomposition (Haiku) — **+ docs flag**
Group changed files into units and priority-tag them as in v1
(critical / high / medium / low). Priority tags are **retained** — they drive the
Pass 2b trigger and the wave-cap ordering — but they **no longer select the Pass 2
model**. **Addition:**

- **`docs_only` flag per unit:** `true` when *every* file in the unit matches a
  documentation pattern — `*.md`, `*.mdx`, `*.txt`, `*.rst`, `docs/**`, or a
  comment-only diff. Config files (`*.json`, `*.yaml`, `*.toml`, dotfiles) are **not**
  docs — they're code-side units reviewed on the best model, because config bugs are
  real (wrong default, malformed schema).
- Emit JSON per unit: `{"name","files","priority","skip","docs_only"}`.
- Skip filter unchanged (100%-deleted files, whitespace/import-reorder/version-bump).
  **No early-exit** — all non-skipped units proceed to Pass 2.

### Pass 2 — per-unit review (parallel) — **model by code-vs-docs + wave cap + lean returns**
Dispatch the **same** `code-review-unit-reviewer` per non-skipped unit:

| Unit kind | Model | Override |
|-----------|-------|----------|
| code (`docs_only: false`) | inherited best model | **none** (inherits orchestrator) |
| docs (`docs_only: true`) | Haiku | `model: haiku` passed at dispatch |

- **Mechanism:** removing the frontmatter pin makes the default *inherit*; the
  orchestrator only ever *downgrades* (docs → Haiku). See Open risks for the fallback
  if a target Claude Code version ignores per-call overrides.
- **Wave cap:** dispatch in waves of **at most 5 concurrent** agents, not all-15-at-
  once. Order: critical/high code units first, then medium/low, then docs (Haiku).
  Bounds peak agent count and RAM regardless of the leak's root cause.
- **Lean returns:** tighten the unit-reviewer instructions to *return only the
  structured findings with `file:line` references — never paste file bodies or large
  excerpts back to the orchestrator.* Bounds the context the orchestrator accumulates
  across units and runs.

Findings schema, taxonomy, and `is_migrated_code` are unchanged from v1.

### Pass 2b — architectural pass (NEW — parallel, advisory)
- **Trigger:** at least one `critical` or `high` unit exists (after the skip filter).
  Otherwise skipped.
- **Dispatch:** **one** `quality-reviewer` (Sonnet) over the **deduped union of all
  critical+high unit files**. Runs **concurrently with Pass 2** — depends only on
  Pass 1's unit list, not on Pass 2's findings — so it shares the wave budget but adds
  no serial latency.
- **Input:** the base ref, the change summary, and the critical+high file set, with an
  instruction to focus its architectural checklist on the *changed* surface.
- **Output handling:** its `CRITICAL` / `WARNING` / `INFO` prose is collected verbatim
  and rendered in Pass 4 as a distinct **"Architectural notes (advisory)"** section.
  It is **not** deduped against bug findings, **not** scored, **not** filtered by
  confidence, and **never** written to the FP store.

### Pass 3 — dedup + scoring + filter (Haiku) — unchanged
Operates on **bug findings only**. Architectural notes bypass this pass entirely.

### Pass 4 — output + FP write-back — **+ arch section**
- **Output order:** (1) numbered bug findings as in v1, then (2) the "Architectural
  notes (advisory)" section if Pass 2b ran.
- **`--comment`:** the arch notes are posted under a clearly labeled **"Architectural
  notes (advisory — not blocking)"** subhead, visually separated from the numbered bug
  list, so a reader never mistakes an architectural opinion for a confirmed bug.
- **FP write-back:** unchanged — auto-records only hard-killed (score ≤15) **bug**
  findings + user dismissals. Architectural notes are never recorded as FPs.

## Port-fidelity fixes (audit vs the reference skills/agents)

Auditing the v1 port against the three reference skills + three agents surfaced these
divergences to fix in v2 (separate from the intentional enhancements — second-brain
reads, FP store, best-model, arch pass — and from the correctly-matched `<70`
threshold and faithful per-unit/scorer agents):

1. **Dropped `context: fork` + orchestrator agent** (highest — leak-relevant). See
   Orchestration above. The reference isolates review context; v1 inlined it, feeding
   the RAM buildup.
2. **Unrealized Haiku delegation in Pass 0/1** (`SKILL.md:25`). The skill says "use an
   agent (Haiku) for the mechanical parts where noted" but **no step is actually
   delegated** — eligibility, CLAUDE.md discovery, and the PR summary read as inline
   orchestrator work, so they run on the expensive session model and bloat session
   context. The reference dispatches a discrete Haiku agent for each (eligibility 1.1;
   CLAUDE.md + summary 1.2 in parallel; unit-ID 1.3). v2: make each mechanical helper
   an explicit Haiku agent dispatch.
3. **Emoji contradiction** (`SKILL.md:81` vs `:93`). The template is labelled "(no
   emojis)" but contains `🤖`. The deep reference bans emojis and uses a plain
   "Generated with [Claude Code]" footer. v2: drop the `🤖` (the eligibility self-scan
   keys on the text "Generated with [Claude Code]", not the emoji, so removal is safe).
4. **Inconsistent skipped-count phrasing** (`SKILL.md:85` "Z skipped as trivial" vs
   `:95` "Z skipped"). The reference uses "Z skipped as trivial" in both branches.
   v2: align.
5. **Lost `effort: high`** — the reference orchestrator sets it; the inline skill has
   no equivalent. v2: set it on the forked orchestrator (fork path); N/A inline.
6. **Stale description** (`SKILL.md:3`) — "deep-reviews each with a parallel Haiku
   agent" becomes inaccurate once code units use the best model. v2: update to
   "code units on the best model, docs on Haiku."

## Leak mitigation — ghost agents / RAM buildup

**Observed (test machine, not the dev box):** after 2–3 `code-review-deep` runs, RAM
fills with "ghost agents." At rest on the dev box: no zombies, no detached shells,
normal RAM — so the buildup occurs *during/after* runs, not as a persistent
cross-session OS-process leak.

**Mechanism candidates (Claude Code subagents are not normally standalone OS
processes):**

- **(a) Recursive `claude --bare` extractors.** The second-brain Stop/PreCompact hook
  spawns an extractor per Stop event **in API-key mode** (in OAuth mode it queues).
  A heavy fan-out skill generates many agent/Stop events → many extractor processes.
  **Not a `code-review-deep` bug** — the skill triggers the hook's lifecycle. Prime
  suspect if the test machine has `ANTHROPIC_API_KEY` set.
- **(b) Orphaned MCP / node servers.** A `server.bundle.js` per session never reaped,
  accumulating across sessions.
- **(c) Parent-context bloat.** The orchestrator retains every sub-agent transcript
  (up to 15 units × whole-file reads × multiple runs). Inherent to fan-out; largely
  harness-controlled. Note: code units now run on the **best/largest model**, so each
  retained transcript is heavier than under v1's all-Haiku — making the lean-returns
  mitigation *more* important in v2, not less.

**Ship now (cause-agnostic):** the **wave cap** (≤5 concurrent) and **lean returns**
(no file bodies) from Pass 2 directly reduce peak agent count and retained context.

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
  layer — tracked as a follow-up, not in `SKILL.md`.
- **(b):** reap orphaned MCP/node servers on session end / detect-and-kill stale
  `server.bundle.js` whose parent claude has exited.
- **(c):** accept as inherent; wave cap + lean returns are the mitigation. Revisit only
  if material after (a)/(b) are ruled out.

## Degradation
Unchanged from v1: if subagent dispatch is unavailable, fall back to a single-context
review over the full diff (no fan-out, no parallel scoring, no Pass 2b) and say so. The
fallback runs on the session model. Second-brain reads + FP write-back still apply.

## Changed / new files

| Path | Kind | Change |
|------|------|--------|
| `skills/code-review-deep/SKILL.md` | orchestrator skill | Pass 1 docs flag (no early-exit); Pass 2 code-vs-doc model routing + wave cap; new Pass 2b; Pass 4 arch section + `--comment` subhead; leak protocol note |
| `agents/code-review-unit-reviewer.md` | inherited/Haiku worker | **Remove `model: haiku` frontmatter** (default→inherit). One-line "return findings only, no file bodies" tightening |
| `agents/code-review-scorer.md` | Haiku scorer | Unchanged |
| `agents/quality-reviewer.md` | Sonnet critic | Reused as-is. Verify its checklist instructions read sensibly given a changed-file set |
| (follow-up, gated) second-brain hook layer | runtime | Extractor throttle / MCP reap — only if diagnostic points to (a)/(b) |

## Testing

Extend the existing frontmatter/wiring test to assert:

- `code-review-unit-reviewer` has **no** `model:` frontmatter (inherits).
- Pass 2 routing: `docs_only` units dispatched with a Haiku override; code units with
  no override.
- **No** early-exit path remains (docs-only changes still produce a review).
- Wave-cap constant present and ≤5.
- Pass 2b triggers iff ≥1 critical/high unit; runs exactly one `quality-reviewer`.
- Architectural notes are excluded from scoring and from FP write-back.
- Unit-reviewer instructions contain the "no file bodies" return constraint.

Do not build/typecheck/run the app in the review itself — CI handles that.

## Open risks

- **Per-call model override support (highest).** v2 needs the Claude Code Task/Agent
  dispatch to honor a per-call `model: haiku` override for doc units (and to inherit
  when omitted). True in the dev harness. **Verify against the installed CC version in
  the plan.** If unsupported, fall back to two thin agent files
  (`code-review-unit-reviewer` = inherit for code; `code-review-unit-reviewer-docs` =
  pinned Haiku) selected by `docs_only` — more files, same behavior.
- **`context: fork` support (the second verify-first item).** The fork orchestration
  path needs `context: fork` + an `agent:` entrypoint honored for a second-brain skill.
  Verify in the plan; fall back to inline + wave cap + lean returns if unsupported
  (the user's chosen hedge).
- **Cost on large code changes.** Every code unit now runs on the best model (Opus),
  not Haiku. Mitigated by the wave cap (peak ≤5) and by docs/mechanical staying Haiku.
  If cost bites, a future per-run Opus-unit cap can be added.
- **Heavier retained context.** Best-model transcripts are larger than Haiku's,
  amplifying candidate-(c) bloat. Lean returns are the counter; keep them strict.
- **Architectural pass model.** Pass 2b stays on `quality-reviewer`'s native Sonnet
  rather than the top model, to bound cost on an advisory pass. If arch depth proves
  lacking, revisit letting it inherit.
- **quality-reviewer roaming.** It has `Bash/Grep/Glob` and can wander beyond the diff.
  Mitigated by passing the changed-file set + a "report on the change" instruction;
  acceptable because the section is explicitly advisory.
- **Advisory-vs-bug confusion.** Mitigated by the separate, explicitly-labeled section
  and the non-blocking `--comment` subhead.

## Decision log

1. Model follows the work: **code units → inherited best model, doc units → Haiku**,
   mechanical steps (decompose/score) → Haiku. Reverses v1 decision #4 on its merits
   and supersedes the earlier priority-tiering draft.
2. No early-exit and no skip for docs — docs are reviewed, just cheaply on Haiku.
3. Architectural hybrid = one holistic `quality-reviewer` (Sonnet) over critical+high
   files, advisory and separate — not per-unit, not scored, not FP-recorded.
4. Model selection via frontmatter-pin-removal (default inherit) + a Haiku downgrade
   for docs, not new agent files (fallback noted).
5. Leak: ship wave cap + lean returns now; gate the root-cause fix on the test-machine
   diagnostic; extractor/MCP fixes live outside `SKILL.md`.
6. Orchestration: **fork-if-supported** — restore the reference's `context: fork` +
   `deep-code-reviewer` orchestrator (Sonnet, `effort: high`) when supported, isolating
   review context and addressing leak-(c); inline + mitigations otherwise.
7. Fix port-fidelity bugs from the audit: realize the Haiku delegation in Pass 0/1,
   drop the contradictory `🤖`, align the skipped-count phrasing, restore `effort:
   high`, refresh the stale description.
