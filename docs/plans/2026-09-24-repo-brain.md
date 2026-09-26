# Repo Brain — the per-repo working agreement, delivered from the knowledge base

**Status: APPROVED (2026-09-24).** Slice 0 in progress on `feat/2026-09-24-repo-brain`.
Decisions D1/D2 pinned to PROJECT.md the same day. Builds on
`docs/plans/2026-08-20-rethink-delivery-layer.md` and supersedes its Phase 1.1.

**Goal:** every repo Claude works in has a brain Claude knows how to find, use, and update after
finished work — and whether it is used is a measured number, not a hope.

---

## What the user asked for

Per repo: (a) code map, (b) intent behind the code, (c) decisions, (d) direction, (e) hard rules,
(f) soft rules / conventions, (g) lessons — bugs, dead ends, error→fix — so mistakes are not
repeated, and (h) a work protocol: think before implementing; "smartest model for thinking, one
lower for implementation, lower than that for scanning files, running bash and the simplest work";
token economy. The buddy statusline is the visible layer that shows the user what passes between
Claude and the brain. Skills, agents and rules remind Claude at session start. Reuse ECC
(affaan-m/ECC, MIT) where its authoring is better than ours.

## Why prose is not enough (measured before designing)

- **0 haiku dispatches in 46-78 Agent calls** while `output-styles/dev-focused.md`'s tier table was
  active. All 4 Explore dispatches were pushed *up* to sonnet.
- **Stored lessons recurred.** The exec-bit class recurred 4 times after it was in memory.
- **Non-ritual push reads = 0 of 47** over the last 4 sessions, once the project-anchor fetch that
  the using-second-brain skill itself prescribes is excluded.
- **The ruler was broken** (fixed in Slice 0): Agent telemetry matched only `Task`; value-loop
  counted only the first Stop's window then deleted the manifest (audit D180); the ritual anchor
  counted as a read; per-prompt injections were never in the denominator.

Conclusion: value comes from delivery at the moment of need plus machine locks, measured honestly.

## Decisions

- **D1 — class 5 "Working agreement" + protocol lock.** `CONSTITUTION.md` grows a fifth class (hard
  rules machine-checked, conventions delivered on touch, the work protocol). Class-5 surfaces may
  inject budgeted cards, return `warn|ask|deny`, and write telemetry; they never dispatch, never
  edit user settings, never add Stop blocks. One opt-in exception: `SB_DELEGATION_REWRITE`
  (default off) sets the Agent tool's `model` via PreToolUse `updatedInput`.
  *Rejected:* clarify-only (tiering stays an output style — the thing measured as not followed);
  a model router / auto-dispatch (undo rows 9-10, the deleted `team` skill; main-model switching is
  impossible).
- **D2 — the knowledge base is the only home.** Nothing is compiled into `<repo>/.claude/rules`,
  `~/.claude/rules`, `CLAUDE.md` or native `MEMORY.md`. Delivery is plugin hooks plus pull tools.
  Supersedes rethink Phase 1.1. *Rejected:* a native-first projection into git-excluded
  path-scoped `.claude/rules` files (user directive: the KB stays the home); pull-only (too weak for
  hard rules).

## Research that shaped the design

**Anthropic docs** (code.claude.com, engineering posts): CLAUDE.md and rules are advisory — "to block
an action regardless of what Claude decides, use a PreToolUse hook"; keep files under 200 lines,
bloat lowers adherence. Built-in Explore and Plan skip CLAUDE.md; SessionStart context is
parent-only; hooks fire inside subagents. Subagent model resolution: per-call > frontmatter >
`CLAUDE_CODE_SUBAGENT_MODEL` > inherit. `effort:` exists on skills and agents. "Lacked knowledge →
bigger model; lacked effort → raise effort; default effort for most tasks." Opus lead + Sonnet
workers beat solo Opus by 90.2% on Anthropic's research eval at ≈15× chat tokens; subagents return
1-2k-token summaries. The think/ultrathink keyword ladder is not in current official docs — encode
depth as `effort`.

**Ecosystem** (AGENTS.md, Copilot, Cursor, Windsurf, Kiro, Cline, Continue, Aider, spec-kit, BMAD,
Serena, claude-mem, Basic Memory, Letta, MADR): load modes converge on always / path-glob /
agent-requested / manual. Auto-memory is being demoted to staging (Cursor removed Memories; Windsurf
says promote to rules). IFScale: best models plateau near 68% adherence at 500 concurrent
instructions. Lessons and a work protocol are first-class nowhere else.

**ECC 2.2.1/2.2.2** — ADOPT: every agent pins `model:`; `commands/plan.md` CONFIRM gate with a
Pattern Grounding table; `rules/common/development-workflow.md` step 0 "Research & Reuse
(mandatory)"; `verification-loop` READY / NOT READY report; `agents/code-explorer.md` fixed return
template; the Delegation Completion Contract ("your final message IS the deliverable"). ADAPT:
`rules-distill` (deterministic collect → LLM judge → approve), cross-project promotion (same rule in
≥2 repos at ≥0.8), codebase-onboarding phases. SKIP: session files, context-budget audits,
`MAX_THINKING_TOKENS` (budget_tokens is deprecated on 4.7+), editing `settings.json`.

## Live probes (Claude Code 2.1.281, 2026-09-24)

Isolated headless runs (`--setting-sources project` + a probe-only `--settings` file, nonce echo).
Evidence files: session scratchpad `probes/`.

| Probe | Result | Design consequence |
|---|---|---|
| P1 SubagentStart `additionalContext` reaches the subagent | **PASS** Explore, general-purpose; **FAIL** Plan (reproduced twice; hook fires, context never arrives) | Role cards via SubagentStart for Explore/general-purpose/custom agents. Plan needs another path — default: PreToolUse on `Agent` tells the parent to put the repo's HARD rules in the Plan prompt |
| P2 PreToolUse `updatedInput` rewrites the Agent `model` | **PASS** — subagent ran on `claude-haiku-4-5` although called with sonnet; control ran sonnet | `SB_DELEGATION_REWRITE` is buildable (opt-in) |
| P3 skill frontmatter `model: haiku` / `effort: low` | **FAIL** — every message in the turn stayed on sonnet | Skill-level pins are not a lever; tier a skill's work by delegating to a pinned agent (`context: fork`) |
| P4 Agent `tool_input` when no model is given | `model` key **absent**; tool name `Agent`; key `subagent_type` | Guard computes the effective model: frontmatter pin, else inherit the main model |
| P5 `additionalContext` on `Read` from PreToolUse / PostToolUse | **PASS** both | Path-triggered JIT delivery works without writing any file |

## Design

```
STORAGE (KB — only home)                DELIVERY (plugin hooks, budgeted, measured)
wiki pages (project facet, ai-blocks) ─┐  SessionStart  : repo card ≤2 KB (replaces the PROJECT.md hot tier)
graph edges (supersedes, relates)      │                  + protocol card ≤1.2 KB
codemap/map.md                         ├─ SubagentStart : role card per agent_type (SCOUT/DO/THINK) + top HARD rules
projects/<key>/rules.json (layered)    │  PreToolUse    : path-triggered JIT — first Read/Edit under a glob injects
projects/<key>/PROJECT.md              │                  its lessons/conventions/decisions (once per session+item)
projects/<key>/jit-index.json (derived)┘  UserPromptSubmit: existing grounded retrieval (unchanged)
                                          Pull          : knowledge_* / code_* / repo-scout agent
ENFORCEMENT  protocol-guard.sh (Agent tier warn · opt-in model rewrite · search-before-create warn)
             persona-tool-guard (layered rules) · plan-first-nudge · stop-verify-gate
UPDATE       Stop extraction → wiki → rebuild jit-index · pin_to_project(decisions|conventions) → rebuild now
MEASURE      value-loop (fixed) · gate=delegation · gate=jit · buddy_react used:[ids] (claims, precision-scored)
BUDDY        delivered · used · routed · guard · remembered
```

- **Per-repo key = git common-dir**, so worktrees share one brain (today's cwd slug shards them —
  20+ `witcherrpg-N` directories).
- **Untrusted content:** card and JIT text are ai-block fields only (claim / action / symptom / fix),
  passed through `sanitize.ts`, ≤160 chars per line, inside the existing DATA banner;
  `held-untrusted` pages are excluded; HARD rules come only from `rules.json`, never from page text.
  Locked by a source scan plus an injection fixture.
- **`jit-index.json`** is a derived cache in BRAIN_DIR mapping path globs to item ids, built from
  pages whose ai-blocks or text name repo paths (checked against `git ls-files`). One jq read per
  session; the per-call check is a bash glob match (Windows spawn tax).

| Class | Source of truth | Delivered by | Lock |
|---|---|---|---|
| a code map | codemap | card top-10 hubs; JIT "≥N importers → code_neighbors first" | search-before-create warn |
| b intent | wiki concepts (project facet) | JIT "Why:" lines → slug | — |
| c decisions | wiki decisions (+ rejected) | card top-5 active; JIT if path-bound | superseded drop out |
| d direction | PROJECT.md `## Direction` (goal, non-goals, priorities "through YYYY-MM-DD") | card head | plan-first-nudge Gate B |
| e hard rules | layered `rules.json` | card "HARD (enforced)" + role cards | persona-tool-guard deny/ask |
| f soft rules | `## Conventions` + convention-tagged pages | JIT by glob | optional warn |
| g lessons | wiki issues / learnings | JIT: symptom → fix (slug) | recurrence → rule candidate |
| h protocol | `skills/using-second-brain/protocol.md` + repo overrides in `rules.json` | protocol card + role cards | Agent warn / opt-in rewrite; plan/verify gates |

**Skills and agents — surface budget flat (rewrite or rename, no net adds):**
- `using-second-brain` becomes the protocol home, with a sibling `protocol.md` (the card source).
- `audit` → `rules`: show rules by layer, distill / promote / demote (rules-distill presentation).
- `search-conversations` → `repo-scout` (haiku, effort low): memory first, then Grep; code-explorer
  template plus a Gaps section.
- Every agent pins `model:` and `effort:`, locked in `validate-plugin.sh`.
- `setup` gains a bounded onboarding intake (ECC codebase-onboarding phases) seeding direction,
  conventions and hard rules.

## Slices — each gated by a pre-registered number

**Slice 0 — probes, fix the ruler, record decisions.**
Probes P1-P5 (done, above). `stop-extract.sh` value-loop becomes cumulative per session: the
manifest survives every Stop, a `.value-loop-state-<sid>.json` accumulates, and one row per Stop
carries the running total — `gate=value-loop injected= read= prior= hits= ritual= pulled= agents=
tiers= turn= sid=`; the session total is the last row per `sid`. Agent telemetry matches
`Agent|Task`. The project anchor is written as `kind:anchor` and reported as `ritual=`.
`persona-context.sh` per-prompt hits join the manifest. RED-first fixture in
`tests/test-telemetry-loop.sh`. Constitution amended (class 5, protocol lock, D2).

**Slice 1 — working agreement v1.** `protocol.md` card injected at SessionStart with tiers resolved
from `model-ladder.json` + `sb_resolve_model`. New `scripts/protocol-guard.sh`:
`agent` mode (PreToolUse `Agent|Task`: warn on a THINK-class job at the fast tier, a SCOUT-class job
at the deep tier, Explore above fast, an unpinned agent with no model; an audit row on every call;
`SB_DELEGATION_REWRITE` opt-in) and `subagent` mode (SubagentStart role cards; skips
`second-brain:*`; Plan handled per P1). Agent `model:`/`effort:` pins + validate lock.
`tests/test-protocol-guard.sh` built from real baseline shapes, PLUS a source scan: no script
under `scripts/` writes to `.claude/rules`, `CLAUDE.md`, or `MEMORY.md` (grep for those path
literals in write/redirect positions) — the lock CONSTITUTION.md's "only home" DIRECTION promises.
Budget: scripts +1, tests +1.
*Success over 10 sessions:* ≥80% of dispatches carry a job-matched model; ≥60% of SCOUT-class jobs
run at the fast tier (baseline 0); zero THINK-class jobs at fast; verify-gate blocks do not rise.
*Kill:* more than 70% of warns ignored → mute and rethink the classifier.

**Slice 2 — repo card + JIT from the KB.** `## Direction` and `## Conventions` sections and
`pin_to_project(section:conventions)`; the `jit-index.json` builder (TS in `mcp/src/tools/`,
reusing `project-moc.ts` and `sanitize.ts`); PreToolUse Read/Edit JIT (`protocol-guard.sh jit`);
the repo card replaces the forced PROJECT.md/USER.md block at equal or smaller size.
*Success:* JIT-delivered items fetched or cited in ≥10% of deliveries (baseline 0 of 47
non-ritual); hot-tier bytes down. *Kill:* under 5% over 10 sessions → drop push for that class,
keep pull.

**Slice 3 — per-repo rules + learning loop.** Layers: plugin default → user delta → user×repo
(`projects/<key>/rules.json`); `lock:true` rules can only tighten. The `rules` skill; candidates
auto-arm as warn/soft at count ≥3; ask/deny need approval; cross-repo promotion at ≥2 repos and
≥0.8. Search-before-create warn (codemap + `git ls-files` basenames).

**Slice 4 — scout + buddy.** The `repo-scout` agent; buddy kinds `routed|used|rule`;
`buddy_react used:[ids]` scored for claim precision (a claimed id with no matching fetch or edit
is a false claim, never a read).

## Reuse, don't rebuild

`mcp/src/model-resolve.ts` + `sb_resolve_model` (tier → alias, availability cache);
`model-ladder.json` (`protocol_names` becomes live data); `project-moc.ts`, `sanitize.ts`,
`atomic-write.ts`, `brain-paths.ts`; `buddy-events.ts` `writeBuddyEvent`; `sb_manifest_add`;
persona-tool-guard's verdict ranking; `merge-persona-signals.sh` candidate counts;
`pin-to-project.ts`.

## Do not build

A router, auto-dispatch or main-model switching; writes into `MEMORY.md`, `.claude/rules` or
`CLAUDE.md`; new MCP tools; per-class stores (dead schema); a bigger SessionStart block; MUST
banners; any ranking by use counts; skill-level `model:` pins (P3).

## Coordination

`feat/2026-09-24-buddy-capybara` (0.52.0) has uncommitted edits to `persona-context.sh`,
`plan-first-nudge.sh` and the server/buddy files, and another session is releasing it. This branch
was cut from `origin/main` in a separate worktree; expect a small merge in `persona-context.sh`.
Open question for 0.52.0: `SB_BUDDY_REACT` defaults ON in that tree, while the buddy plan §5 says
off.

## Verification

- Every new lock is proven RED on pre-fix code first.
- Gates before any push, judged by exit codes: `npm ci` → local `tsc --noEmit` → vitest →
  `tests/test-bundle-current.sh` → `tests/run-all.sh` → `scripts/validate-plugin.sh` →
  portability guards → `scripts/build-plugin.sh --check`.
- Each slice boundary: `devils-advocate` plus every applicable reviewer in parallel.
- Live: 5-10 real sessions per slice, read `gate=value-loop|delegation|jit` rows from
  `~/.second-brain/audit-log.jsonl` against the numbers above.
