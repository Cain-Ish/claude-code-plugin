# second-brain Constitution

The frozen north star. Every change is measured against this.

Machine-enforced by the surface-budget ratchet (R8 in `scripts/validate-plugin.sh`, baseline
`.claude-plugin/surface-budget.json`), the single-source resolution guard
(`mcp/src/brain-paths.test.ts`), and the injection-gate satisfiability lock
(`mcp/src/tools/retrieval-guards.test.ts`).

Founding design (archive/docs branch):
`git show archive/docs:docs/superpowers/specs/2026-06-26-second-brain-constitution-and-diet-design.md`.
Current direction: `docs/plans/2026-08-20-rethink-delivery-layer.md`.

## What second-brain IS

The AI's **memory of the project**. The mental model a senior dev holds *before opening a file*:
WHAT exists, WHERE it lives, WHY, HOW it works, WHY-THIS-WAY — so Claude starts **oriented**, not
re-deriving by grep.

Three primitives, one measured contract between them:

1. **Capture** — session transcripts distilled into decision-guiding pages, without noise and
   without data loss.
2. **Storage** — `~/knowledge/wiki` + the typed bi-temporal graph. Durable, portable, ours.
3. **Delivery** — the right page reaching the model at the right moment, **and being read**.
   This is the product. Capture and storage are inputs to it.

Everything else is scaffolding and must justify itself against delivery.

## What belongs in memory

Four content classes, and only four. Each is something a senior dev carries between sessions and
cannot recover from the diff:

1. **Decisions** — what was chosen, what was rejected, and *why*. The rejected branch is the
   expensive half: without it the next session re-argues a settled question.
2. **Architecture and high-level design** — why-this-way. The shape of the system, its
   invariants, and the constraints that produced them.
3. **The code map** — what exists, where it lives, what breaks if it changes. Structure and blast
   radius, so orientation does not start with grep.
4. **Session recap** — what mattered in a session, distilled at the end of it, so nothing
   important is lost when the context window closes.

**The scope rule: a surface that does not produce, store, or deliver one of these four is not
memory, and does not belong in this plugin** — however good a tool it is. Generic code review,
agent orchestration, and model routing are the standing examples: real tools, wrong repo.


## The measured contract

**A page that is stored but never read has zero value.** The plugin's success metric is the
injection→read rate, logged as `gate=value-loop` rows in `audit-log.jsonl`
(`scripts/stop-extract.sh:194`).

Baseline at the time of writing: **83 items injected across 13 sessions, 0 reads.** A subsystem
that does not move this number is not load-bearing, and shipping one that cannot be measured is
not permitted. Retrieval gates must be *satisfiable at shipped defaults* and *corpus-size
invariant* — the class of bug where a threshold sits above its own mathematical ceiling is locked
out by `retrieval-guards.test.ts`, and outcomes are asserted at shipped defaults by
`tests/test-injection-gate.sh`.

## Token discipline (core, not a bolt-on)

Memory's job is to minimize the high-signal token set: **just-in-time retrieval** (store
identifiers, fetch on demand), **summarize-before-evict** compaction, and **cache-stable
injection** (volatile context goes LAST so the prompt-cache prefix stays warm). **Good memory IS
token optimization** — `knowledge_fetch` tiers, BM25 relevance, PreCompact.

The corollary: **an always-injected tier spends budget it has not earned.** DIRECTION, not current
rule (per "Prose promises need machine locks" below — no gate enforces this yet): the goal is to
delegate the hot tier (`PROJECT.md` / `USER.md`) to Claude Code's native memory, which the harness
already loads at no cost to us, and spend this plugin's budget only on retrieval that is proven to
be read. Tracked as Phase 1 of `docs/plans/2026-08-20-rethink-delivery-layer.md` (not started as of
2026-09-05). What is actually locked TODAY: `session-load.sh` unconditionally force-injects
`USER.md` (≤6000 B) + `PROJECT.md` (≤3000 B) every SessionStart under `BYTE_BUDGET=8000`/
`HARD_CAP=9500` — there is no native-memory gate and no `SB_*` kill switch for this tier (tracked:
`docs/audits/2026-09-05-deep-audit.md` D022/D077). Guidance:
`wiki/learnings/claude-mechanics-best-practices-2026-06`.

## What it IS NOT

A session log; a trivia dump; a graph for its own sake; pages that sit unread. **Not a home for
good tools that are not memory** — orchestration, model-routing, and generic review tooling belong
in their own repo, however useful they are.

## The test

**If a saved item does not actively guide a future decision, it does not belong.**
**If a stored item is never delivered and read, the delivery layer is broken — fix it or delete it.**

## Hard constraints

- **Fully autonomous** — zero required user interaction. Claude + plugin operate together
  automatically (capture, consolidate, inject, guard, tailor). Safety comes from reversible
  auto-consolidation + grounded guardrails + redundancy/importance-ranked forgetting (NOT raw
  usage frequency — that is the rich-get-richer hub-bias footgun), not a manual gate.
- **Untrusted-content isolation** — the plugin ingests untrusted text (transcripts, web, tool
  returns), distills it, and re-injects it; this is a memory-poisoning substrate. Consolidation
  must treat ingested content as DATA to summarize, never instructions to follow; the privileged
  writer consumes only structured, provenance-tagged output, never raw transcript (quarantine /
  dual-LLM). Least-privilege the background agents; the tool-return scanner is telemetry, NOT a
  trust boundary. Inject context just-in-time via the conversation layer, not the wiki body every
  turn. Grounding: `wiki/learnings/claude-agent-architecture-deep-2026-06`.
- **Cross-platform** — must work on **macOS, Windows (git-bash/MSYS), and Linux** (+ BSD CI).
  Developed primarily on Windows, shipped to all; correctness is verified by the portability,
  bundle-drift, and validate gates running cross-platform in CI. No heavy native dependency is
  added without a vetted cross-OS plan (e.g. a pure-JS/regex fallback, the way vector-deps were
  handled).
- **Tests must not disable the thing they test.** An invariant is preferably locked by arithmetic
  or a source scan, which no `SB_*` override can pin open; behavioural fixtures that set the
  constant under test to a value that cannot fail are not coverage. This rule exists because 918
  green tests hid a dead injection gate for the entire life of the feature.

## Governance (machine-enforced)

- **Surface-budget ratchet** — live counts (skills / agents / scripts / tests) may not GROW
  beyond `.claude-plugin/surface-budget.json` without a same-commit, git-blameable bump there;
  enforced by R8 in `scripts/validate-plugin.sh`. Ratchet DOWN freely as deletion removes surface.
- **Single-source resolution** — brain/knowledge dir resolution lives ONLY in
  `mcp/src/brain-paths.ts`; no file re-implements it (enforced by the source-scan in
  `mcp/src/brain-paths.test.ts` — closes the 0.33.17 stray-folder bug class across ~21 sites).
- **Prose promises need machine locks** — a constraint stated only in a doc is a wish. Anything
  this file asserts must name the gate that enforces it, or be marked as direction rather than
  rule.
