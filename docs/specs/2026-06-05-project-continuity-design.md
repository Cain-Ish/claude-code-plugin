# SP-E — Project Continuity (design)

- **Date:** 2026-06-05
- **Status:** spec → built (0.24.24). Closes the autonomous-knowledge-loop roadmap (A–E).
- **Sub-project:** E (A ✅ capture · B ✅ consolidate · C ✅ dream-lifecycle · D ✅ retention · E project-continuity).

## Two concrete defects (both visible in the dogfood PROJECT.md)

### 1. PROJECT.md was budget-starvable (the USER.md sibling bug)

`session-load.sh` appends the project's **hot tier** (PROJECT.md) with `sb_append "$PROJ_CONTENT" "PROJECT.md" 0` — no `force` — **after** ~9 conditional banners. The 0.24.16 fix gave USER.md a `force` arg (bypass the byte budget) precisely because it's priority-1 context; PROJECT.md is *equally* priority-1 (the project's goal/state/decisions/blockers) but never got it. So a degraded multi-banner SessionStart could spend the budget and **silently drop the entire project context**. **Fix:** `sb_append "$PROJ_CONTENT" "PROJECT.md" 4000 force` — forced like USER.md, capped at 4000B so PROJECT.md + USER.md (6000) can't breach Claude Code's ~10K hook-output ceiling.

### 2. `[degraded]` breadcrumbs polluted Recent decisions

When the LLM extractor is unavailable, `stop-extract.sh`/`pre-compact.sh` wrote a `[degraded] LLM extraction unavailable; session touched: …` note into the delta's `recent_decisions`, so it landed in PROJECT.md's **## Recent decisions** (capped at 5). A multi-day outage filled all 5 slots with degraded noise, pushing **real** decisions off — exactly the state of the dogfood PROJECT.md (5 consecutive `[degraded]` lines). **Fix:** route the breadcrumb to a **sidecar** `projects/<slug>/pending-extraction.log` (dated, deduped-per-day, bounded to 50 lines) and emit an empty delta, so Recent decisions stays clean. The transcript is still archived, so the **out-of-band drainer (SP-A) mines the real knowledge later** — the sidecar just logs the gap. This is correct *because* SP-A now exists: degraded sessions are recoverable, so the breadcrumb is a transient note, not a decision.

## Built (0.24.24)

- `session-load.sh` — PROJECT.md `force` + 4000B cap (with the rationale comment; the old "always included" comment was aspirational).
- `stop-extract.sh` + `pre-compact.sh` — the degraded breadcrumb → `pending-extraction.log` sidecar; empty delta; dedup grep now targets the sidecar.

## Deferred (lower value / fuzzier)

- A first-class `## Plans` / `## State` PROJECT.md schema + a write-side byte cap. The read-side cap (the `force` 4000) + the degraded routing already bound the injected size; a structured Plans/State schema is a larger prompt/merge change with unclear payoff and is left as a future refinement.
- A SessionStart "N sessions pending extraction" count from the sidecar — redundant with the capture-health banner (which already warns about undrained transcripts).
- Cleanup of the *existing* `[degraded]` lines in a user's PROJECT.md — manual (delete them) or a one-shot; SP-E only prevents NEW pollution.

## Verification

- **Linux-CI:** `test-session-load-usermd-budget.sh` — PROJECT.md sb_append passes `force` + a finite cap (the structural sibling of the USER.md assertion). `test-stop-extract.sh` — the `[degraded]` breadcrumb lands in the sidecar (dedup'd per day, scratch-paths stripped) and PROJECT.md decisions stay clean of `[degraded]`.
- **Operator (Pi):** the dogfood PROJECT.md stops accruing `[degraded]` lines in decisions; existing ones can be deleted by hand; PROJECT.md is never dropped from SessionStart.

## Rollout

Additive; gated; version bump + migration row. No MCP change. The sidecar appears lazily on the first degraded session; PROJECT.md force/cap is behaviour-preserving for a normal-sized PROJECT.md (it just can no longer be dropped).
