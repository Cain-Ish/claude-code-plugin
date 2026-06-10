---
name: orchestrate
description: Cost-routing orchestrator. Classifies the task into tiers, plans with Opus only when genuinely needed (budget-gated), implements each unit via Sonnet/Haiku agents with explicit per-dispatch model routing, verifies cheaply, escalates on failure, and logs routing outcomes.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Grep Glob Bash Task TodoWrite
argument-hint: "<task description>"
---

# Orchestrate

Route `$ARGUMENTS` across model tiers to minimise Opus spend while preserving quality.

## Tier taxonomy

| Tier | Agent | Model | When |
|------|-------|-------|------|
| THINK | `cr-planner` | Opus | Architecture, design, ambiguous requirements, decomposition. Use sparingly. |
| DO | `cr-implementer` | Sonnet | Code implementation — the ~80% default for all coding deliverables. |
| SCOUT | `cr-scout` | Haiku | File reads, grep/search, enumeration, test/lint runs, change summaries. |

## Protocol

### Step 0 — Consult routing history

If the `cost-routing-patterns.md` wiki page exists (written by second-brain's capture hook at `${SB_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}/wiki/state/cost-routing-patterns.md`), read it briefly. Use its escalation patterns to bias tier classification for similar task shapes.

### Step 1 — Classify the task

Read `$ARGUMENTS`. Classify using these heuristics:

- **SCOUT only** (Haiku): purely mechanical, deterministic, no judgment needed — reads, greps, test runs, listing.
- **DO only** (Sonnet): well-specified implementation, clear files, known pattern. The default for ≥80% of tasks.
- **THINK → DO** (Opus plan, then Sonnet execute): genuinely ambiguous requirements; cross-cutting architecture; security/correctness trade-offs; task that failed a first DO attempt. Do NOT default here — bias toward DO.

Output your classification and a brief rationale (1–2 sentences) before proceeding.

### Step 2 — Check Opus budget (if THINK needed)

Before dispatching `cr-planner`, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/opus-budget.sh" over
```

If it exits 0 (over budget): skip THINK, downgrade to DO with a note to the user that the daily Opus budget is exhausted. Log `escalated: false` in route-log (budget blocked). If it exits non-zero (under budget): proceed with THINK.

### Step 3 — Plan (THINK tier, if needed and budget permits)

Dispatch `cr-planner` via the Task tool **passing `model: 'opus'` explicitly**:

```
Task(subagent_type: 'cr-planner', prompt: "<task context and full requirements>", model: 'opus')
```

Collect the plan: ordered units, each with (a) what to change, (b) files, (c) verification criterion, (d) recommended tier.

If the plan is longer than 8 units, challenge scope and trim before proceeding.

### Step 4 — Execute units (DO / SCOUT)

For each unit from the plan (or the original task if no planning step):

- **SCOUT work** (reads, searches, test-runs): dispatch `cr-scout` with `model: 'haiku'`:
  ```
  Task(subagent_type: 'cr-scout', prompt: "<unit spec>", model: 'haiku')
  ```
- **DO work** (code changes): dispatch `cr-implementer` with `model: 'sonnet'`:
  ```
  Task(subagent_type: 'cr-implementer', prompt: "<unit spec with verification criterion>", model: 'sonnet')
  ```

**Parallelize independent units** — dispatch them in a single fan-out if they touch different files/components.

The orchestrator itself stays light: do not write code here. Your job is routing and coordination.

### Step 5 — Verify (SCOUT)

After DO units complete, dispatch a SCOUT agent to run the unit's verification criterion (tests, lint, typecheck):

```
Task(subagent_type: 'cr-scout', prompt: "Run <verification commands> and report pass/fail. Cite file:line for any failures.", model: 'haiku')
```

### Step 6 — Escalate on failure

If a DO unit fails verification and the failure is a genuine design issue (not a typo): escalate by dispatching `cr-planner` (subject to budget check from Step 2) with the failure context. Then re-execute the revised unit. Limit escalation to **1 retry per unit**. If still failing, surface to the user.

If a DO unit fails because the unit was under-specified: send back to planner with the ambiguity, not the implementer.

### Step 7 — Announce routing

After all units complete, print a brief routing summary:

```
Routing: THINK(Opus)×1 + DO(Sonnet)×3 + SCOUT(Haiku)×2
Opus ledger: $<output of opus-budget.sh spent> recorded today (persona_think writes it; cr-planner dispatches are not yet metered — say "no Opus spend recorded" when 0)
Outcome: 4/4 units verified ✓
```

### Step 8 — Log routing outcome

Append to the routing events log:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/route-log.sh" emit \
  "<task-slug>" \
  "<tier: THINK|DO|SCOUT>" \
  "<models-csv: e.g. sonnet,haiku>" \
  "<units-count>" \
  "<escalated: true|false>" \
  "<outcome: ok|partial|failed>" \
  "<committed: true|false>"
```

This is best-effort — do not fail the orchestration if route-log.sh errors.

## Rules

1. **Orchestrator stays light.** Do not write code, edit files, or run long bash commands yourself. Delegate all implementation and verification to the appropriate tier agent.
2. **Lean returns.** Request agents to cite file:line and never paste large file bodies.
3. **Never Opus for reads/search/verify.** SCOUT (Haiku) handles all deterministic work.
4. **Budget is a soft cap.** If over budget, downgrade gracefully; never fail the task silently.
5. **Log every dispatch.** The routing log feeds the learning loop — keep it accurate.
