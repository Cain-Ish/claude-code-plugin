# Auto-team orchestration (design) — virtual team-of-teams with an autonomous trigger

- **Date:** 2026-07-08
- **Status:** spec — direction approved (user, 2026-07-08: Option A + fully automated trigger/git/depth decisions)
- **Method:** 12-agent workflow `wf_b6d0fe3c-182` (6 code readers → 3 independent designers → 3 adversarial refuters; all three designs *viable-with-changes*). This spec is the merged grain+skill-first design with **every refuter-required change folded in**, plus the autonomy layer the user required. Full evidence: workflow journal + `tasks/wua5wfacz.output`.

## Problem

The plugin already runs three orchestration idioms — code-review-deep's wave fan-out, maintain's `DRAINED:/REMAINING:` batch/resume loop, dream's file-state background job — but each is duplicated prose, workers have no sanctioned way to cause more work to exist, no agent has orientation tools (`code_map`/`code_neighbors` granted to **zero** agents), and general development work (implement/refactor/migrate) gets no team at all. The user wants the plugin to run teams of agents on ordinary prompts, let workers cause sub-teams, feed every worker the existing skill library, and coordinate main-team ↔ sub-team work — **with zero required user interaction**.

## Platform facts (verified against live docs, 2026-07)

| Fact | Consequence |
|---|---|
| Subagents cannot nest; Agent tool is unavailable inside subagents | dispatch depth is hard-capped at 1 — sub-teams must be *virtualized* |
| Agent Teams: experimental (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`), and *also* forbids nested teams | not a build target; keep the recorded flip signal (GA + OAuth) |
| Subagent frontmatter honors `skills:`, `model:`, `maxTurns:`, `tools:`; ignores `memory:`/isolation | per-worker model tiering + turn bounds are real; worktree isolation is ours to build |
| OAuth blocks in-session recursive `claude` (repo's own CLAUDECODE guard) | no headless spawning anywhere in this design |
| Shared task lists exist only in agent-teams mode | our ledger is files, as everything else in this repo already is |

## The crux

**Workers request; the conductor materializes; hierarchy lives in the ledger.** A worker that hits work needing decomposition ends its report with `status:"split"` + a `request_team` spec. The conductor — the main-loop team skill, the **only** Agent-grant holder — validates the request as untrusted DATA against `policy.json`, registers child tasks with `parent_task` edges, and dispatches them as the next wave. Physical depth stays 1 forever; the team-of-teams tree exists in ledger provenance, which also makes every level crash-resumable from disk instead of anyone's context.

## Autonomy layer (what changed vs. the reviewed Option A)

The plugin decides three things itself, per prompt. This is the mission's FULLY-AUTONOMOUS hard constraint applied; safety comes from reversibility + machine-enforced caps, not human gates.

### A1 — when to run a team (auto-trigger)

- The team skill ships **model-invocable** (no `disable-model-invocation`). Its description carries the decision rule. WHEN: the task decomposes into ≥3 independent units, or spans ≥2 subsystems / ~≥5 files (checked at plan time against `code_map` + `code_neighbors`; if decomposition fails, fall back to solo and say so). WHEN-NOT: questions, debugging dialogue, single-file edits, conversational turns, anything the user marked quick.
- **Deliberate exception to undo-table row 13** (model-invocable catalog trimmed to 3): user decision 2026-07-08. Mitigation: tight WHEN-NOT list, kill switch `SB_TEAM=off`.
- **Containment-doctrine reading:** the doctrine (auto-consolidate spec, 2026-06-05) forbids the model deciding in-session to fire *out-of-band side-effecting work*. In-session `Agent` dispatch is inside the session's permission envelope and PreToolUse guard coverage — same class as code-review-deep today. Doctrine-compatible.
- **Mid-session escalation nudge:** extend `plan-first-nudge.sh` (same PreToolUse Write|Edit signal, same once-per-session advisory shape): when ≥`SB_TEAM_NUDGE_FILES` (default 4) substantive code-file edits accumulate in solo work, `additionalContext` suggests converting to a team run. Never blocks. Kill switch `SB_TEAM_NUDGE=off`. No new script, no new hook entry.

### A2 — how to handle git (deterministic matrix, conductor applies top-down)

| Situation | Behavior |
|---|---|
| not a git repo | read-only teams allowed; write tasks proceed solo (skill declines team mode loudly) |
| read-only team (review/analysis/research) | no branch, no git at all |
| write team, clean tree | `team/<run_id>` branch from HEAD in place; serialized commits via `team-run.sh commit`; gate pass → merge back to original branch, restore checkout, delete team branch; gate fail → restore original branch, keep team branch, banner |
| write team, dirty tree | `git worktree add` under `BRAIN_DIR` scratch (native git — no symlinks, MSYS-safe); gate pass → team branch kept + SessionStart banner "ready to integrate" (merging into a dirty checkout is impossible by construction); integration when the tree is clean |

Always: `init` records original branch + HEAD and restores on finish/abort; every commit is pathspec-scoped to the task's declared files, runs with `core.hooksPath` pointed at an empty dir, and carries `task_id` + `SB-Team: <run_id>` trailers.

### A3 — whether a team gets sub-teams (auto-depth)

Two channels, one budget: (a) the conductor may pre-plan depth-2 at decomposition (cluster count exceeds wave capacity, or heterogeneous skill-packs); (b) workers may emit `split` requests. Both consume the same guard-enforced dispatch quota. Defaults: `max_logical_depth: 2`, `max_dispatches: 30`, `wave_cap: 5`.

## Build

**B0 — substrate (shippable alone; every refuter endorsed these standalone).**
`code_map` + `code_neighbors` added to `tools:` of code-review-unit/history/premise-reviewer, quality-reviewer, raw-drainer (+ agent-grants test rows). `tests/test-no-agent-recursion.sh`: NO `agents/*.md` may grant Agent/Task/Skill — empty whitelist (converts the quality-reviewer.md comment into a machine lock). `skills/team/PROTOCOL.md` sibling: the single factored copy of the conductor idioms (≤5-slot wave scheduler, model-tiering table, two-strike unparseable-report rule, DATA banner, lean-return rules, status-stamping snippets). TEAM-REPORT v1 (below) + contract test.

**B1 — ledger: `scripts/team-run.sh` + `lib.sh` helpers.**
Layout: `BRAIN_DIR/projects/<slug>/teams/<run_id>/` — slug via `sb_resolve_slug` (lib.sh:656), never re-implemented precedence. Files: `plan.json` (task DAG), `policy.json` (depth/quota/role-whitelist/pinned verify command), `tasks/<id>.json` (dream-status lifecycle schema + `parent_task`, CAS jq transitions), `events.jsonl` (append-only, `.extraction-state.jsonl` shape, 3-fail poison pill). Verbs: `init | task-add | task-set | report-ingest | verify | commit | merge | reconcile | status`. `report-ingest` jq-schema-validates a TEAM-REPORT tail from stdin and CAS-updates the ledger — deterministic validation, not LLM prose compliance. `verify` runs **only** the command pinned into `policy.json` at plan time (discovered from package.json/CLAUDE.md) — never anything sourced from a worker report. Staleness: `sb_team_task_is_stale` with a threshold derived from a worst-case-wave budget proof in a comment (the lib.sh:1616-1624 pattern) — **no mid-wave heartbeat exists** (the conductor is blocked inside parallel dispatch), so mtime heartbeats are not the liveness signal. mkdir-lock guards per-verb critical sections only; no claim of whole-run single-flight. jq output via `-j`/printf (CRLF discipline).

**B2 — worker: `agents/team-worker.md`.**
`tools:` Read, Grep, Glob, Edit, Write + read-only MCP orientation (`code_map`, `code_neighbors`, `knowledge_search`, `knowledge_fetch`). **NO git, no web, no Agent/Task/Skill, no node-CLI glob** (raw-capture-cli is a memory-write channel — conductor is the sole distiller). `maxTurns: 40`. Standard untrusted-input DATA banner. No fixed `model:` (per-dispatch override). Role, skill-pack paths, task file, and parent/children digests arrive in the dispatch prompt. Review/verification roles reuse the existing reviewer/scorer agents (differentiated lenses — homogeneous-panel prior). team-worker stays **capturable** by subagent-capture.sh (NOT in SELF_AGENTS — compounding depends on it; locked by test).

**B3 — conductor: `skills/team/SKILL.md`** (<500 lines; PROTOCOL.md + `references/roles.md` siblings).
`allowed-tools`: Agent, Read, Grep, Glob, Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*), code_map, code_neighbors, knowledge_search, episodic_search, pin_to_project — **all git flows through team-run.sh verbs under the scripts/* glob**, so the grant list covers every phase (refuter flaw #4 closed). Phases: (0) recall — knowledge_search + episodic_search over prior team runs; (1) orient + decompose via code_map/code_neighbors into non-overlapping units; (2) apply the A2 git matrix via `team-run.sh init`; (3) assign role + skill-pack per task from roles.md — the conductor names **absolute SKILL.md paths discovered via Glob at plan time** (repo-local `.claude/skills/*`, installed packs), conditional on presence since sb-* is repo-local, not plugin-shipped; workers Read their packs themselves (lean conductor context); (4) wave dispatch ≤5 with model tiering; parse TEAM-REPORT tails via `report-ingest`; fulfill `split` requests within policy; re-dispatch parents fresh-context with distilled child digests; (5) verification — scorer refuter panel on critical outputs (tool-grounded re-check), `team-run.sh verify` for the pinned test command; (6) merge gate + learnings capture. Resume mode reconciles from the ledger and continues idempotently; interrupted runs surface via the session-load banner routed through the existing byte-budget RESERVE machinery.

**B4 — quota guard (the machine lock on runaway autonomy).**
Extend `persona-tool-guard.sh`'s existing Task|Agent matcher: when `subagent_type` is `second-brain:team-worker` and an active run exists, the guard appends to a **guard-owned counter** keyed by run_id + session_id and denies dispatch beyond `max_dispatches` — counting its own observations, never the conductor's ledger (a confused conductor that doesn't record still gets counted). Scoped strictly by subagent_type so code-review-deep/maintain dispatches are never throttled. Orphaned policy expires via the shared staleness predicate (a crashed run cannot brick the project). Not gated behind persona-rules.json presence (which fail-opens today). Liveness proof in CI: inject the violation — the N+1th dispatch must be denied.

**B5 — merge gate (corrected polarity).**
Merge when: **zero CONFIRMED (≥70 median) critical/high findings** from the reviewer panel on the branch diff, AND the policy-pinned test command is green, AND the merge is clean. Docs/mechanical variant: tests green + validate passes. A failing run leaves an un-merged branch — mainline needs no undo.

**B6 — compounding loop.**
Run-final phase distills worker `learnings` arrays + scorer verdicts + merge outcome into raw-capture items (conductor-invoked from the trusted main loop) and ≤3 `pin_to_project` entries per run (hot-tier byte-budget starvation guard). SubagentStop capture already archives worker finals for episodic search + dreams — zero new capture code. Phase 0 recall closes the loop: each new run plans with the previous runs' learnings.

## TEAM-REPORT v1 (the one return contract)

Every team-dispatched worker MUST end with a fenced JSON tail:

```json
{"v":1,"task_id":"…","status":"done|blocked|failed|split",
 "artifacts":["repo-relative paths"],"evidence":["test/cmd one-liners"],
 "request_team":{"goal":"…","tasks":[{"role":"…","skills":["SKILL.md paths"],"inputs":"…"}]},
 "learnings":[{"kind":"decision|gotcha|convention","text":"…"}]}
```

`request_team` only when `status:"split"`; skill paths in split requests are validated by `report-ingest` against the role whitelist + known skill roots (a poisoned report cannot direct children to Read arbitrary files). One unparseable tail → retry once → stop loud (maintain's two-strikes). Generalizes `DRAINED:/REMAINING:`; maintain may adopt it in M3.

## Security model (refuter fixes, enumerated)

1. **No parallel writers on one checkout:** v1 = parallel reads, serialized writes; git removed from workers entirely; commits serialized through `team-run.sh commit` (pathspec-scoped, hooks disabled) — kills both the index-race and the `.git/hooks` exfil channel.
2. **Trifecta never co-locates:** team-worker reads untrusted repo content + holds Write, therefore holds no network tools and no memory-write channel; wiki influence flows only through the raw inbox's reconciled, staged drain.
3. **Requests are DATA:** `split`/`request_team` is a capability *request* fulfilled by the trusted conductor under policy (schema + role whitelist + depth + quota), with the PreToolUse guard as the independent, fail-safe brake.
4. **Reversibility instead of gates:** branch-per-run, mechanical merge gate, worktree mode for dirty trees, original-branch restore on every exit path.
5. **Machine locks over prose:** no-Agent-grant test (empty whitelist), report-contract parser test (valid/malformed/CRLF-poisoned/split fixtures), guard-liveness violation-injection test, team-worker-in-capture test, agent-grants parity rows, and per feedback_test_fallback_branches: no-policy.json / empty-ledger / no-env default branches covered.

## Flags & budget

New flags (8-step checklist at build time): `SB_TEAM` (master, **default on** — autonomy mission; the reversibility rail is the consent), `SB_TEAM_NUDGE` (on), `SB_TEAM_NUDGE_FILES` (4), `SB_TEAM_MAX_DISPATCHES` (30), `SB_TEAM_MAX_DEPTH` (2), `SB_TEAM_WAVE_CAP` (5). Surface budget same-commit: skills 18→19, agents 9→10, scripts 52→53, tests 153→156 (3 new files; extensions to dispatch-resolution + agent-grants tests are edits, not files).

## Milestones

- **M0 substrate** — B0. Shippable alone; no behavior change.
- **M1 team runs** — B1+B2+B3+B5: conductor/ledger/worker/merge-gate, invocable as `/second-brain:team` for validation.
- **M2 autonomy** — A1–A3 wired: model-invocable description, nudge, git matrix, auto-depth, B4 guard, B6 compounding. `SB_TEAM` flips default-on here, not before.
- **M3 dedup migration** — code-review-deep/maintain/dream onto PROTOCOL.md + a drift test. Named milestone, not "later" — the dead/stalled-work ledger shows unattached thinning never ships.

## Non-goals / deferred

- **Option B team OS** (out-of-band headless conductors, unattended depth-2): revisit on the Agent-Teams-GA-under-OAuth flip signal or after M3. Its refuter findings (lock-budget contradiction, Windows containment gap, free-text goal injection) stand.
- Parallel write-workers via per-worker git worktrees.
- Cross-repo teams; teams minted by background jobs.

## Verification

Per milestone: full local gate chain (tsc, vitest, bundle-current, run-all, validate-plugin, portability) before push, per house rule. M2 additionally: guard violation-injection probe green, nudge fire/suppress matrix (threshold · kill switch · once-per-session), git-matrix behavior on clean/dirty/non-repo fixtures, and a live end-to-end team run on this repo with evidence in the PR.
