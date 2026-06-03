# SP-0 — Persona Behavioral Protocol (the Four Principles)

**Status:** approved design (2026-06-03). Promoted ahead of SP-1 as the persona core.

**One-liner:** Give the persona a small, canonical set of coding-collaboration principles (distilled from Karpathy's Dec-2025 failure-mode post) and — crucially — deliver them the way a static CLAUDE.md *can't*: a source-of-truth file, loaded as standing context, re-surfaced once when coding actually begins, and backed by violation-triggered gates. The point is to counter the four recurring agent failure modes (silent wrong assumptions, over-complication, collateral edits, weak/imperative goals) without re-creating noise.

## 1. Problem / motivation

Karpathy (paraphrased): modern coding agents make *subtle conceptual* mistakes — they "make wrong assumptions and run with them," "don't push back / surface inconsistencies / present tradeoffs," "overcomplicate and bloat abstractions," "don't clean up dead code," and "change/remove orthogonal code/comments they don't understand." His key caveat: **"All of this happens despite a few simple attempts to fix it via instructions in CLAUDE.md."** Prose drifts under task pressure.

The plugin's differentiator over a CLAUDE.md is its *delivery layer*: a per-prompt persona hook (`persona-context.sh`), violation gates (`stop-verify-gate`, `quality-gate`, …), and a skill loaded at conversation start (`using-second-brain`). So the fix is not "more prose" — it's the same four principles delivered with salience + enforcement.

## 2. The Four Principles (canonical content)

A new file `skills/using-second-brain/principles.md` is the single source of truth:

1. **Think Before Coding** — don't assume; surface tradeoffs; push back; stop when confused. *State load-bearing assumptions and verify the riskiest from code/wiki before acting; present interpretations when ambiguous; name what's unclear instead of guessing.*
2. **Simplicity First** — minimum code that solves the problem; nothing speculative. *No unrequested features/abstractions/config/flexibility; no error-handling for impossible cases. Test: "would a senior engineer call this overcomplicated?" If 200 lines could be 50, rewrite.*
3. **Surgical Changes** — touch only what the task requires; clean up only your own mess. *Don't "improve" adjacent code/comments/formatting; match existing style; remove only the imports/vars your change orphaned; mention pre-existing dead code, don't delete it. Test: every changed line traces to the request.*
4. **Goal-Driven Execution** — define success criteria, loop until verified. *Transform imperative → verifiable ("add validation" → "write tests for invalid inputs, then pass them"); state a brief numbered plan with a verify-check per step. Strong criteria let the model loop independently.*

The file also carries a **compact form** (the four names + one imperative line each, ≤6 lines) used by the hook for re-surfacing.

## 3. Delivery (the plugin's edge — three layers, silence-by-default)

| Layer | Mechanism | When it fires |
|---|---|---|
| **Standing context** | `using-second-brain/SKILL.md` references `principles.md` (full) | conversation start (the skill is "use when starting any conversation") |
| **Re-surface (salience)** | `persona-context.sh` injects the **compact** form **once per session**, on the first *substantive coding* prompt (intent-gate already classifies substantive; add a coding-verb check). Deduped via the existing per-session memo so it never repeats. | first coding intent only |
| **Enforcement (violation-triggered)** | gates that speak ONLY on a detected violation (this is the "earned interrupt" applied to behavior) | at the mistake |

**Gate mapping (reuse first, add one):**
- *Goal-Driven* → **already enforced** by `stop-verify-gate.sh` (forces verification before "done"). No change.
- *Simplicity First* → **one new light gate** `scripts/simplicity-gate.sh` (PostToolUse on Edit/Write/MultiEdit): when a single change adds more than `SB_SIMPLICITY_GATE_LINES` (default 150) lines, emit an advisory `additionalContext` nudge — "large change: is there a naive-correct version ~half the size? consider /simplify or code-simplifier." Advisory only (never blocks), kill switch `SB_SIMPLICITY_GATE=off`. Mirrors `quality-gate.sh`'s shape.
- *Surgical Changes* → **injection + standing context only** for v1. Reliable structural detection of "orthogonal edit / removed-comment-I-shouldn't-have" is genuinely hard and a fuzzy gate would false-positive constantly (violating Simplicity First in our own design). **Explicitly deferred**: documented as a future gate once a low-false-positive signal exists. Logged as a non-goal so a future session doesn't think it was missed.
- *Think Before Coding* → injection + standing context + the existing engagement gate. No new structural gate (assumption-detection is also fuzzy).

So: **1 new gate, 1 new file, 1 hook addition, 1 skill reference.** Nothing else.

## 4. Components (files touched)

- **NEW** `skills/using-second-brain/principles.md` — the canonical Four Principles (full + compact form).
- `skills/using-second-brain/SKILL.md` — reference the principles file (1 short section) so they're standing context.
- `scripts/persona-context.sh` — on the first substantive *coding* prompt of a session, inject the compact principles (memo-deduped, byte-budgeted, kill switch `SB_PRINCIPLES_INJECT=off`).
- **NEW** `scripts/simplicity-gate.sh` — PostToolUse advisory large-diff nudge.
- `hooks/hooks.json` — register `simplicity-gate.sh` under PostToolUse (alongside `quality-gate.sh`).
- **NEW tests**: `tests/test-simplicity-gate.sh`, `tests/test-persona-principles.sh` (file exists + all four present + compact form + skill references it + hook injects on coding-intent, not on trivial, deduped).

## 5. Configuration / kill switches

- `SB_PRINCIPLES_INJECT=off` — disable the per-session re-surface.
- `SB_SIMPLICITY_GATE=off` — disable the large-diff nudge; `SB_SIMPLICITY_GATE_LINES` (default 150) — its threshold.
- `SB_PERSONA_GATE=off` (existing) — already disables the whole persona layer including these.

## 6. Error handling / non-disruption

- All additions are **advisory** — none block a tool call or the Stop event (the simplicity gate emits `additionalContext`, never a `deny`). Matches the safety posture of the existing PostToolUse hooks.
- Fail-soft: a missing `principles.md` or a parse error → the hook/skill no-ops (no crash, no block).
- The re-surface is **once per session** and gated on coding intent → near-zero added noise/cost (respects SP-1's noise-reduction goal and the persona's silence-by-default design).

## 7. Boundaries (important)

- The Four Principles are **universal coding-collaboration behavior** → they live in the **behavioral** layer (`using-second-brain` + `principles.md` + hooks), **never** the user's identity `persona-card.md` (which we just de-leaked to be the user's own generic seed). WHO-the-user-is and HOW-Claude-behaves stay separate.
- **No new CLAUDE.md.** A repo CLAUDE.md only helps someone working *on the plugin*; the persona is injected into *every* user session — that's where the leverage is.

## 8. Testing (TDD)

1. `test-persona-principles.sh` — `principles.md` exists; contains all four principle headings + the "test:" line for each; a compact form is present; `using-second-brain/SKILL.md` references it.
2. `persona-context.sh` — on a coding-intent prompt with no prior injection this session, output includes the compact principles; on a trivial prompt ("thanks"), it does not; a second coding prompt in the same session does NOT re-inject (memo dedupe); `SB_PRINCIPLES_INJECT=off` suppresses it.
3. `test-simplicity-gate.sh` — a >threshold Edit emits the advisory nudge (no `deny`/block); a small Edit does not; `SB_SIMPLICITY_GATE=off` suppresses; malformed input → exit 0, no output (fail-soft); mawk-safe / cross-platform (no bash-4, no backslash-path issues).
4. Existing persona-context + hook tests stay green.

## 9. Cross-platform

Markdown file (portable); two bash touchpoints follow the existing mawk-safe / `$SB_*` / fail-soft patterns and the `test-script-portability.sh` guard applies. No child-process path passing, no Windows-specific concerns.

## 10. Non-goals (deferred, on record)

- A structural **Surgical-Changes detector** (orthogonal-edit / removed-comment flag) — deferred until a low-false-positive signal exists; v1 delivers the principle via injection + standing context only.
- A structural **assumption-detector** for Think-Before-Coding — same reasoning.
- Reshaping the broader skill/command surface — that is SP-5.
