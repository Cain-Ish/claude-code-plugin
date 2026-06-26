# second-brain Constitution

The frozen north star. Every change is measured against this. Enforced by the surface-budget
gate (`tests/test-surface-budget.sh`) and the single-source resolution guard
(`mcp/src/brain-paths.test.ts`). Full design:
`docs/superpowers/specs/2026-06-26-second-brain-constitution-and-diet-design.md`.

## What second-brain IS

The AI's **memory of the project** + support skills/agents + an optional cost-router wrapper.
The mental model a senior dev holds *before opening a file*: WHAT exists, WHERE it lives, WHY,
HOW it works, WHY-THIS-WAY — so Claude starts **oriented**, not re-deriving by grep.

Mission triad:
1. **Orientation** — the project mental model (what/where/why/how/why-this-way + a code map).
2. **Compounding personalization** — learned best practices (global + per-project) that become
   ACTIVE guardrails, so Claude grows tailored to the user with use.
3. **Support + cost** — persona agents that keep focus / ask the right questions / enforce
   guardrails while coding, + an optional cost-router.

## What it IS NOT

A session log; a trivia dump; a graph for its own sake; pages that sit unread.

## The test

**If a saved item does not actively guide a future decision, it does not belong.**

## Hard constraints

- **Fully autonomous** — zero required user interaction. Claude + plugin operate together
  automatically (capture, consolidate, inject, guard, tailor). Safety comes from reversible
  auto-consolidation + grounded guardrails + usage-ranked forgetting, not a manual gate.
- **Cross-platform** — must work on **macOS, Windows (git-bash/MSYS), and Linux** (+ BSD CI).
  Developed primarily on Windows, shipped to all; correctness is verified by the portability,
  bundle-drift, and validate gates running cross-platform in CI. No heavy native dependency is
  added without a vetted cross-OS plan (see spec §9 — e.g. the orientation layer's tree-sitter
  must have a pure-JS/regex fallback, the way vector-deps were handled).

## Governance (machine-enforced)

- **Surface-budget ratchet** — live counts (skills / agents / scripts / tests) may not GROW
  beyond `docs/surface-budget.json` without a same-commit, git-blameable bump there; enforced
  by `scripts/validate-plugin.sh` (R8). Ratchet DOWN freely as the diet (spec P4) removes surface.
- **Single-source resolution** — brain/knowledge dir resolution lives ONLY in
  `mcp/src/brain-paths.ts`; no file re-implements it (enforced by the source-scan in
  `mcp/src/brain-paths.test.ts` — closes the 0.33.17 stray-folder bug class across ~21 sites).
