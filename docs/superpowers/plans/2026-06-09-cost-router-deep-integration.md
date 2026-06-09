# cost-router Plugin (Deep Integration) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `cost-router` — a separately-installable Claude Code plugin (same repo, 2nd marketplace entry) that routes work across model tiers (Opus = plan/design, Sonnet = implement, Haiku = mechanical) to cut Opus token spend, deeply integrated with the second-brain plugin via a shared Opus-budget ledger and a routing-outcome learning loop.

**Architecture:** The reliable "force" is **per-dispatch `model:` routing** inside an `/orchestrate` skill (empirically proven on this gateway — agents dispatched `model:'sonnet'` ran on Sonnet; GitHub #43869 does NOT apply here) plus three model-pinned agents, plus the native `opusplan` alias for the main loop offered by a **consent-based setup**. We deliberately **do NOT** ship a blanket `CLAUDE_CODE_SUBAGENT_MODEL` floor, because it is highest-precedence and would override second-brain's deliberate per-agent Haiku/Sonnet pins (upgrading its Haiku agents to Sonnet = more cost; or downgrading its Sonnet workers = capability loss). Cross-plugin integration is by **file-format contract, not code dependency**: a shared Opus-budget JSON ledger and a routing-events JSONL that second-brain reads. Each plugin ships its own tiny reader/writer; neither imports the other; both degrade gracefully when the other is absent.

**Tech Stack:** Claude Code plugin manifest (`.claude-plugin/plugin.json` + `mcpServers`-style wiring N/A here), skills/agents/commands/hooks, POSIX-ish bash (must pass `tests/test-script-portability.sh` — bash 3.2 / BSD-safe), `jq`, the repo's existing shell test harness (`tests/*.sh`, `tests/run-all.sh`), TypeScript for the one second-brain MCP touch.

---

## Empirically established facts (do not re-litigate)

- **Per-dispatch `model:` routing works here.** Verified via session transcripts: `model:'sonnet'` agents ran `claude-sonnet-4-6`; no-override agents inherited `claude-opus-4-8`; the built-in Haiku agent ran `claude-haiku-4-5`. This is the load-bearing mechanism — it is proven.
- **Pricing (official, 2026-06-09):** Opus 4.8 `$5/$25` per Mtok; Sonnet 4.6 `$3/$15`; Haiku 4.5 `$1/$5`. **Opus:Sonnet = 1.67×, Opus:Haiku = 5×.**
- **Plugin `settings.json` only supports `agent` and `subagentStatusLine` keys — NOT `env`.** So a plugin cannot silently inject `CLAUDE_CODE_SUBAGENT_MODEL`. The setup skill writes to the *user's* `~/.claude/settings.json` with consent instead.
- **second-brain already tiers its agents** (`search-conversations`=haiku; `dream-runner`/`quality-reviewer`/`knowledge-maintainer`=sonnet; `persona-think`=opus, budget-gated). cost-router must respect, not clobber, these.

---

## Plugins touched & versioning

1. **cost-router** — NEW plugin at `cost-router/`, new entry in `.claude-plugin/marketplace.json`, own version **0.1.0**.
2. **second-brain** — MODIFIED (shared-ledger read in `persona-think`; routing-events capture step). Per release discipline: bump `0.24.35 → 0.24.36` in `.claude-plugin/plugin.json` + the second-brain `marketplace.json` entry + a migration row in `skills/upgrade/SKILL.md`. MCP server version only bumps if a tool/schema changes — it does not here (persona-think change is internal accounting), so **server stays 2.6.7**.

Branch: `feat/cost-router-plugin` (stacked on `fix/0.24.35-mcp-plugin-root-resolution`). Commit per task.

---

## Cross-plugin contracts (file-format coupling only)

### Contract A — Shared Opus-budget ledger
- **Path:** `${COST_ROUTER_LEDGER:-${SB_BRAIN_DIR:-$HOME/.second-brain}/opus-budget.json}` — defaults into second-brain's brain dir so both plugins land on the same file; overridable.
- **Schema (single JSON object, daily-reset):**
  ```json
  {
    "date": "2026-06-09",
    "opus_cost_usd": 0.42,
    "opus_calls": 7,
    "cap_usd": 5.0
  }
  ```
- **Semantics:** before any Opus dispatch, a caller checks `opus_cost_usd < cap_usd` (cap from `COST_ROUTER_OPUS_CAP_USD`, default `5.0`). After the call, it adds the call's cost (tokens × Opus rates). If `date` ≠ today, reset to today with zeroed counters before reading/writing. Over budget → caller falls back to Sonnet (orchestrate) or warns/declines (persona-think).

### Contract B — Routing events (learning loop)
- **Path:** `${COST_ROUTER_EVENTS:-${SB_BRAIN_DIR:-$HOME/.second-brain}/cost-router-events.jsonl}` — append-only JSONL.
- **One object per line:**
  ```json
  {"ts":"2026-06-09T18:00:00Z","task":"add retry to uploader","tier":"DO","models":["sonnet"],"units":3,"escalated":false,"outcome":"ok","committed":true}
  ```
- **Producer:** cost-router `/orchestrate` (via `scripts/route-log.sh`).
- **Consumer:** second-brain capture step aggregates recent events into a wiki page `cost-routing-patterns.md` (under the knowledge dir) summarizing which task shapes needed escalation to Opus. The `/orchestrate` and `/model-route` classifiers read that page (if present) to bias future decisions. Absent file → no-op, no error.

---

## File Structure

```
cost-router/
├─ .claude-plugin/plugin.json     # manifest, version 0.1.0
├─ README.md                      # toggle = install/uninstall; documents contracts A & B
├─ agents/
│  ├─ cr-planner.md               # model: opus   — design/plan only, never edits files
│  ├─ cr-implementer.md           # model: sonnet — implements one specified unit
│  └─ cr-scout.md                 # model: haiku  — reads/searches/verifies
├─ commands/
│  └─ model-route.md              # /cost-router:model-route <task> — advisory tier + rationale
├─ skills/
│  ├─ orchestrate/SKILL.md        # the core: classify → plan(Opus?) → execute(Sonnet/Haiku) → verify
│  └─ setup/SKILL.md              # consent: offer opusplan; detect second-brain; second-brain-aware floor warning
├─ hooks/hooks.json               # SessionStart: routing-status + Opus-budget remaining notice
└─ scripts/
   ├─ opus-budget.sh              # Contract A read/record/enforce helper
   └─ route-log.sh               # Contract B append helper

tests/                            # repo-level (run by tests/run-all.sh)
├─ test-opus-budget.sh            # Contract A unit tests (TDD)
├─ test-route-log.sh             # Contract B unit tests (TDD)
└─ test-cost-router-validate.sh   # `claude plugin validate ./cost-router` is green + structural guards

second-brain (modified):
├─ mcp/src/tools/persona-think.ts # check + record shared Opus ledger (Contract A)
├─ scripts/cost-router-capture.sh # NEW: aggregate Contract B events → cost-routing-patterns wiki page
├─ hooks/hooks.json               # add cost-router-capture.sh to Stop (guarded: only if events file exists)
├─ .claude-plugin/plugin.json     # 0.24.35 → 0.24.36
├─ .claude-plugin/marketplace.json# second-brain entry 0.24.35 → 0.24.36
└─ skills/upgrade/SKILL.md        # migration row 0.24.36
```

---

## Tasks

### Task 1: cost-router manifest + marketplace entry

**Files:**
- Create: `cost-router/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json` (add 2nd entry)
- Create: `cost-router/README.md`

- [ ] **Step 1 — Write `cost-router/.claude-plugin/plugin.json`:**
```json
{
  "name": "cost-router",
  "description": "Routes work across model tiers — Opus for planning/design, Sonnet for implementation, Haiku for mechanical work — to cut Opus token spend. Ships an /orchestrate skill (per-dispatch model routing), model-pinned agents, an advisory /model-route classifier, and a consent-based setup. Install to enable cost routing; uninstall to disable. Integrates with second-brain (shared Opus budget + routing learning) when present.",
  "version": "0.1.0",
  "author": { "name": "second-brain" },
  "license": "MIT",
  "keywords": ["cost-optimization", "model-routing", "opus", "sonnet", "haiku", "orchestrator", "token-budget", "tar"]
}
```
- [ ] **Step 2 — Add the marketplace entry** to `.claude-plugin/marketplace.json` after the second-brain entry:
```json
    {
      "name": "cost-router",
      "source": "./cost-router",
      "description": "Model-cost router — Opus plans, Sonnet implements, Haiku does mechanical work, to cut Opus spend. Install to enable cost routing; uninstall to disable.",
      "version": "0.1.0"
    }
```
- [ ] **Step 3 — Write `cost-router/README.md`** documenting: the toggle (install/uninstall), the three tiers, Contracts A & B (paths + schemas above), and the deliberate no-blanket-floor decision.
- [ ] **Step 4 — Validate:** `claude plugin validate ./cost-router` → expect pass (after agents/skills exist; may warn until Task 2-4). Commit.

### Task 2: the three model-pinned agents

**Files:** Create `cost-router/agents/cr-planner.md`, `cr-implementer.md`, `cr-scout.md`

- [ ] **Step 1 — `cr-planner.md`** (Opus, plans only):
```markdown
---
name: cr-planner
description: Use for design, architecture, planning, decomposition, and ambiguous-requirements reasoning. Produces a decomposed implementation plan + task graph; does NOT write code or edit files. Opus-tier — invoke sparingly, only for genuine design work.
model: opus
---
You are the PLANNER in a cost-routing orchestrator. You run on Opus because the work that reaches you is genuinely hard: architecture, trade-offs, ambiguous requirements, decomposition.

Produce a CONCRETE plan: an ordered list of small, independently-implementable units. For each unit give (a) what to change, (b) the files involved, (c) the verification criterion, (d) the model tier to implement it (sonnet for code, haiku for mechanical). Surface load-bearing assumptions and risks.

You do NOT write code or edit files — your plan is handed to cheaper Sonnet/Haiku agents. Keep it tight: smallest change that solves it, no speculative units. Return lean output (cite file:line; never paste large file bodies).
```
- [ ] **Step 2 — `cr-implementer.md`** (Sonnet, implements one unit):
```markdown
---
name: cr-implementer
description: Use to implement a single well-specified code unit from a plan — write/edit code following the spec exactly, then run the unit's verification. Sonnet-tier; the default for coding deliverables.
model: sonnet
---
You are the IMPLEMENTER in a cost-routing orchestrator. You run on Sonnet — the right tier for the vast majority of coding work.

You receive ONE well-specified unit: what to change, which files, and the verification criterion. (1) Make exactly that change — minimal, matching surrounding style; do not touch orthogonal code. (2) Run the unit's verification (tests/lint/typecheck) if specified. (3) Return a lean result: what changed (file:line), verification outcome, blockers. Do not paste large file bodies.

If the unit is under-specified or you hit a genuine design fork, STOP and report it for the planner rather than guessing.
```
- [ ] **Step 3 — `cr-scout.md`** (Haiku, mechanical):
```markdown
---
name: cr-scout
description: Use for mechanical, deterministic work — reading files, grep/search, enumeration, change summaries, running tests/lint/typecheck and reporting results, gathering context. Haiku-tier; never use a bigger model for verifiable mechanical work.
model: haiku
---
You are the SCOUT in a cost-routing orchestrator. You run on Haiku — fast and cheap, for work with a deterministic ground truth.

You handle: file reads, grep/search, listing, change-summaries, running tests/lint/typecheck and reporting pass/fail, gathering context. Return only the requested facts, structured and lean (cite file:line; never paste large bodies). You do not make design decisions or write production code.
```
- [ ] **Step 4 — Validate** `claude plugin validate ./cost-router`; commit.

### Task 3: `scripts/opus-budget.sh` (Contract A) — TDD

**Files:** Create `cost-router/scripts/opus-budget.sh`; Test `tests/test-opus-budget.sh`

- [ ] **Step 1 — Write the failing test** `tests/test-opus-budget.sh` (isolated `BRAIN_DIR`/ledger in a temp dir; assert: fresh ledger reports 0 spent and not-over-budget; recording a cost accumulates; exceeding cap reports over-budget; a stale `date` resets counters). Use the repo's existing test style (temp dir + `trap rm -rf`). Cover ≥4 assertions.
- [ ] **Step 2 — Run, verify RED:** `bash tests/test-opus-budget.sh` → fails (script missing).
- [ ] **Step 3 — Implement `opus-budget.sh`** with functions `ob_path`, `ob_today_spent`, `ob_record <cost_usd>`, `ob_over_budget` (cap from `COST_ROUTER_OPUS_CAP_USD:-5.0`), daily reset by comparing stored `date` to `date -u +%F`. Pure bash + jq; atomic write via temp+mv; bash-3.2/BSD-safe (no `date -d`; portable temp). Sourced as a lib AND runnable as a CLI (`opus-budget.sh spent|record <c>|over`).
- [ ] **Step 4 — Run, verify GREEN.**
- [ ] **Step 5 — `tests/test-script-portability.sh`** stays green. Commit.

### Task 4: `scripts/route-log.sh` (Contract B) — TDD

**Files:** Create `cost-router/scripts/route-log.sh`; Test `tests/test-route-log.sh`

- [ ] **Step 1 — Failing test:** appending an event writes one valid JSON line with the contract fields; multiple appends accumulate; events path honors `COST_ROUTER_EVENTS` and defaults under `BRAIN_DIR`. RED first.
- [ ] **Step 2 — Implement** `route-log.sh rl_emit <task> <tier> <models-csv> <units> <escalated> <outcome> <committed>` → appends one `jq -c -n` object to the events path. Create parent dir if missing. Never error if dir unwritable (best-effort log).
- [ ] **Step 3 — GREEN; commit.**

### Task 5: `/orchestrate` skill (the core)

**Files:** Create `cost-router/skills/orchestrate/SKILL.md`

- [ ] **Step 1 — Write the skill** (full body) with: the tier taxonomy table (THINK→Opus/`cr-planner`, DO→Sonnet/`cr-implementer`, SCOUT→Haiku/`cr-scout`); the protocol (classify → plan-only-if-needed → execute each unit via the Task tool **passing `model:` explicitly**, parallelizing independent units → verify cheap → escalate-on-failure-per-unit → announce routing); the rules (orchestrator stays light; lean returns; never Opus for reads/search/verify; consult `cost-routing-patterns` wiki page if present; check `opus-budget.sh over` before dispatching `cr-planner` and fall back to Sonnet if over budget; call `route-log.sh rl_emit` at the end). `allowed-tools: Read Grep Glob Bash Task TodoWrite`.
- [ ] **Step 2 — Validate** `claude plugin validate ./cost-router`; commit.

### Task 6: `/model-route` advisory command

**Files:** Create `cost-router/commands/model-route.md`

- [ ] **Step 1 — Write the command** that classifies `$ARGUMENTS` (or the current request) → recommends Haiku/Sonnet/Opus with the heuristic (Haiku=deterministic/low-risk; Sonnet=implementation, the ~80% default; Opus=design/ambiguous/cross-cutting/security/failed-first-attempt) + confidence + cheaper fallback. Reads `cost-routing-patterns` page if present. No dispatch. Commit.

### Task 7: `/cost-router:setup` skill (consent floor + opusplan)

**Files:** Create `cost-router/skills/setup/SKILL.md`

- [ ] **Step 1 — Write the skill** that: (a) detects whether second-brain is installed (look for `~/.claude/plugins/cache/second-brain` or a second-brain agent dir); (b) OFFERS to set `model: opusplan` in the user's `~/.claude/settings.json` (Opus in plan-mode, Sonnet in execute) — with explicit consent, showing the diff first; (c) re the blanket `CLAUDE_CODE_SUBAGENT_MODEL` floor: if second-brain (or any per-agent-tiering plugin) is detected, **warn it would override per-agent model pins and recommend AGAINST it**; only offer it for users with no tiering plugin; (d) smoke-test after writing (spawn a `model:'sonnet'` probe agent / re-read settings) and report the effective state. Never writes settings without a shown diff + confirmation. Commit.

### Task 8: `hooks/hooks.json` (routing-status notice)

**Files:** Create `cost-router/hooks/hooks.json`

- [ ] **Step 1 — SessionStart hook** (matcher `startup|resume|clear|compact`) that prints a one-line status: routing tiers + Opus budget remaining (via `opus-budget.sh`) — suppressible via `COST_ROUTER_BANNER=off`. Keep output < the 10K hook ceiling. Validate hooks.json with the repo's hooks conventions (no matcher on no-matcher events). Commit.

### Task 9: second-brain — shared Opus ledger in persona-think (Contract A)

**Files:** Modify `mcp/src/tools/persona-think.ts`; Test `mcp/test/persona-think.test.ts` (or extend existing)

- [ ] **Step 1 — Failing test:** persona-think, before an Opus call, reads the shared ledger and, when over `cap_usd`, returns a degraded/declined result (or routes to a cheaper tier) instead of calling Opus; after a call it records the cost. RED first (mock the ledger path via env).
- [ ] **Step 2 — Implement:** read/record the Contract-A ledger (same path/schema) around the Opus call; graceful no-op if the ledger dir is absent. Keep the existing `SB_PERSONA_*` budget behavior but make the shared ledger authoritative for the daily Opus total.
- [ ] **Step 3 — GREEN;** `npm --prefix mcp test` passes. Rebuild the bundle if the repo ships `mcp/dist`. Commit.

### Task 10: second-brain — routing-events capture (Contract B)

**Files:** Create `scripts/cost-router-capture.sh`; Modify `hooks/hooks.json` (Stop); Test `tests/test-cost-router-capture.sh`

- [ ] **Step 1 — Failing test:** given a synthetic `cost-router-events.jsonl`, the capture script produces/updates a `cost-routing-patterns.md` summary under an isolated knowledge dir; absent events file → no-op exit 0. RED first.
- [ ] **Step 2 — Implement** `cost-router-capture.sh`: read recent events, aggregate counts by tier/outcome/escalation, write a short markdown summary (bounded size) to the wiki. Isolated by `BRAIN_DIR`/knowledge-dir env. bash-3.2/BSD-safe.
- [ ] **Step 3 — Wire** into `hooks/hooks.json` Stop, guarded so it's a no-op when the events file is absent (zero cost when cost-router not installed).
- [ ] **Step 4 — GREEN;** `tests/test-real-kb-isolation.sh` + `test-script-portability.sh` stay green. Commit.

### Task 11: second-brain version bump + migration row

**Files:** Modify `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (second-brain entry), `skills/upgrade/SKILL.md`

- [ ] **Step 1 — Bump** second-brain `0.24.35 → 0.24.36` in plugin.json + its marketplace entry (cost-router entry stays 0.1.0).
- [ ] **Step 2 — Migration row 0.24.36** describing: shared Opus-ledger read in persona-think + the cost-router-events capture step (both no-ops when cost-router absent); "no MCP server change (server stays 2.6.7)"; no per-user state migration. Commit.

### Task 12: cost-router validation test + full verification

**Files:** Create `tests/test-cost-router-validate.sh`

- [ ] **Step 1 — Write** a test that runs `claude plugin validate ./cost-router` (skip-with-message if the CLI is unavailable) and asserts structural invariants (plugin.json valid JSON + has name/version; the 3 agents carry the expected `model:` pins; orchestrate skill exists). 
- [ ] **Step 2 — Run** `tests/run-all.sh` → expect all green (existing 104 + new). 
- [ ] **Step 3 — `claude plugin validate ./cost-router`** and the second-brain validator both green. Commit.

---

## Verification & release

- Full `tests/run-all.sh` green; `claude plugin validate ./cost-router` green; second-brain `scripts/validate-plugin.sh` green.
- Deep-review gate (`/second-brain:code-review-deep`) on the branch before PR (per release discipline).
- Two PRs: this one (`feat/cost-router-plugin`) is stacked on the MCP PR; rebase onto main after MCP merges so the diff is cost-router + the 0.24.36 second-brain changes only.

## Risks & smoke-tests (verify, do not assume)

1. **opusplan in setup overrides the user's session model** — only on explicit consent + shown diff; reversible (uninstall + revert settings).
2. **Per-dispatch `model:` routing** — proven this session, but add a one-shot smoke in setup that dispatches a `model:'sonnet'` probe and confirms (guards against a future regression of #43869-type).
3. **Ledger contention** — two plugins writing one JSON file: use temp+mv atomic writes; last-writer-wins on the daily counter is acceptable (cost tracking is approximate, the cap is a soft guard).
4. **No blanket `CLAUDE_CODE_SUBAGENT_MODEL`** when second-brain present — enforced in setup; documented in README.

## Self-Review

- **Spec coverage:** packaging (Task 1) ✓; full orchestrator = orchestrate skill + 3 agents + model-route + setup + hooks + budget (Tasks 2–8) ✓; deep integration = shared ledger (Task 9) + learning loop (Task 10) ✓; version discipline (Task 11) ✓; verification (Task 12) ✓.
- **Placeholder scan:** agent/manifest/command bodies are given in full; scripts are TDD with defined function names (`ob_*`, `rl_emit`); skill bodies specify exact protocol + tools.
- **Type/name consistency:** ledger path/schema (Contract A) and events path/schema (Contract B) are referenced identically in cost-router (producer) and second-brain (consumer) tasks; function names consistent across tasks.
