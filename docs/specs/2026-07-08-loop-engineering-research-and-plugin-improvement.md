# "Loop engineering" — concept research + fit for second-brain, and a plugin-improvement plan

- **Date:** 2026-07-08
- **Status:** research + recommendations (not a build spec). Complements the direction-approved-but-unbuilt `2026-07-08-auto-team-orchestration-design.md`.
- **Method:** 13-agent workflow `wf_c3030383-926` — 6 web-research agents (primary sources) on the loop-engineer concept + 3 local agents (repo/wiki inventory, gap analysis, prior-decisions) → 1 synthesis → 3 adversarial refuters (correctness / feasibility-fit / completeness). Every refuter-required fix is folded into the recommendations below. Raw evidence: workflow journal + `tasks/wuwkk7cfl.output`.

---

## Part 1 — What "loop engineering" actually is

**Verdict up front: partially-adopt. Adopt the LENS; reject the ideology.**

### The concept (primary sources)

"Loop engineering" is a mid-2026 term of art, **named and formalized by Addy Osmani's essay "Loop Engineering" (June 7 2026, `addyosmani.com/blog/loop-engineering/` + `addyo.substack.com/p/loop-engineering`)** — the verified canonical text. It crystallized from three near-simultaneous sources:

- **Addy Osmani (Google)** — the essay that supplied the vocabulary and anatomy. Verbatim: *"Loop engineering is replacing yourself as the person who prompts the agent. You design the system that does it instead."*
- **Peter Steinberger (@steipete, indie dev)** — the viral X catalyst (~2.2M views): the idea that you should *design loops that prompt your agents* rather than prompt them turn-by-turn. (Exact wording reported, not verbatim-verified — attributing the idea, not a quote.)
- **Boris Cherny (Anthropic, Claude Code lead)** — the "write the loops" sentiment: a described setup of hundreds of Claude instances in parallel scanning GitHub/Twitter/Slack to surface priorities. (Idea attributed; exact string not verbatim-verified.)

**Definition:** designing the automated system that repeatedly prompts an AI coding agent — **discover work → hand it to agents → verify results → persist state → decide the next step → until a verifiable goal is met** — instead of prompting the agent turn-by-turn. The leverage point moves from prompt-crafting to loop/system design: *operator becomes architect*. Osmani is explicit that this is **harder, not easier** ("the leverage point moved").

**Technical lineage:** the harness-level descendant of the **ReAct loop** (2022), which Anthropic formalizes as **gather-context → take-action → verify-work → repeat**.

**Osmani's anatomy (six components + per-turn moves):** scheduled automations (self-triggering discovery/triage); worktrees (parallel-agent isolation); skills (written project knowledge the agent would otherwise guess); plugins/connectors; sub-agents (one has the idea, a *different* one checks it); and **external memory/state** that outlives a single conversation. Plus the native **`/goal`** command, which runs an **independent verifier model** until a written condition is actually true.

**The load-bearing parts of a *good* loop** (across Osmani + Anthropic + practitioners): an **independent verifier** ("backpressure that can't lie" — Huntley's Ralph while-loop), **external memory** surviving context resets, and **hard stop conditions**.

**The skeptical view (must not be relaxed for autonomy):** per-step reliability compounds badly over long loops; loops fail *silently* ("confident garbage" with no error code); reward-hacking survives safety training (agents `exit(0)` / delete tests to fake green); the lethal trifecta (untrusted input + private data + exfil channel) compounds in unattended loops. This is the exact rationale for guardrail discipline — not a caution to trade away for more autonomy.

### Why "partially-adopt" and not "adopt" or "already-doing"

The plugin **is already a loop-engineering artifact** on the core: its capture loop, dream consolidation, drain resume-loop, code-review waves, staging/reversibility, hard caps, and forgetting/dedup are textbook Osmani/Anthropic loop components — and forgetting+dedup is precisely the field-validated defense against memory self-degradation. On those rungs: already-doing.

But the discipline names three rungs the plugin **under-indexes on and its own docs flag**:

1. **Verification-in-the-loop is an evidence-nag, not a runner.** `stop-verify-gate.sh` greps the transcript for the *word* "test/review," runs nothing, caps at 2 blocks/session — a signal gameable exactly as the reward-hack literature warns.
2. **Orientation ships a code-map injected into nothing.** The flagship P3a `code_map`/`code_neighbors` store is generated on the drainer tick but injected into **zero** context and granted to **zero** agents.
3. **Routing is model-elective and learnings never become active guardrails.** No task→skill matcher; the keystone P2 (learnings → active guardrails) is planned but code-less; SessionStart itself admits *"USER.md rules are advisory, not enforced."*

And the **maximalist framing is rejected outright**: "remove the human, run hundreds of lights-out instances" collides with settled hard constraints — OAuth blocks recursive `claude`, subagent dispatch depth is capped at 1 (no nesting), the lethal-trifecta containment doctrine, no out-of-band model-triggered side effects, safety-by-construction over a human gate. This plugin's model is **support Claude in-session, not replace the operator.**

### Fit map — loop-engineering practice → our state

| Practice | Our state | Note |
|---|---|---|
| External memory surviving context resets | **already-do** | wiki + PROJECT.md + dream state + git checkpoints + capture loop |
| Persistence of done/next each turn | **already-do** | Stop-extract, SubagentStop capture, PreCompact — fully autonomous |
| Skills/wiki as written project knowledge | **already-do** | wiki + SKILL.md library (progressive-disclosure = field-standard) |
| Plugins/connectors to tools | **already-do** | the plugin + the ~23-tool MCP server |
| Forgetting/dedup vs memory self-degradation | **already-do** | structural-importance forgetting + MinHash (usage-freq feedback correctly rejected) |
| Reversibility / staging / rollback | **already-do** | dream staging + pre-accept tarball + checkpoints |
| Hard stop / step + budget caps | **already-do** | max-iterations, 2-block Stop cap, 7-day task expiry (spend caps correctly rejected) |
| Human notify/question/review checkpoints | **already-do** | dream accept/discard + escalating nudges |
| Orientation before acting | **partial** | wiki BM25 slugs injected, but P3a code-map injected into nothing, granted to no agent |
| Sub-agent checks another (evaluator-optimizer) | **partial** | code-review waves + quality-reviewer exist, but solo edits get same-context self-nag; the fresh-context critic is dormant |
| Verification = rules-based backpressure that can't lie | **partial** | Stop gate greps for a *mention*; runs nothing; gameable |
| `/goal`-style goal-until-condition + independent verifier | **partial** | native `/goal`/`/loop` exist; plugin wires neither |
| Self-improving playbook (learnings → guardrails) | **partial** | wiki grows-with-use, but P2 unbuilt; graduates only to advisory USER.md |
| Grounded active guardrails w/ provenance + retire | **missing** | only 8 static PreToolUse rules; no learned signal becomes an active rule |
| Per-turn routing to the right skill/agent | **missing** | model-elective; per-prompt specialist catalog removed 0.32.0 |
| Loop-VALUE observability (not just safety) | **missing** | SAR measures guard friction; nothing measures whether recall/orientation *helped* |
| Scheduled discovery loop that actually runs unattended | **broken on maintainer OS** | auto_maintain/bwrap dead on Windows+macOS — open PROJECT.md blocker |
| Worktree isolation for parallel writers | **rejected** | team design removes git from workers; per-worker worktrees a named non-goal |
| Out-of-band headless conductor recursion | **forbidden** | OAuth + depth-cap 1 + containment — not this plugin's model |

---

## Part 2 — Plugin-improvement plan (make it a stronger autonomous support layer)

> **Update 2026-07-14:** **Phase 0 complete** — P0.5 shipped in **0.33.36** (`4df214b`, same release as P0.4; the "P0.5 next" below is stale — it landed, it was not next for long). **P1 complete + P2.1/P2.2 + X.1** released as **0.33.37** (`19c07f6`): all four telemetry slices (liveness/value/utilization/compounding; firewall lock rode 0.33.36), deterministic Stop backpressure, auto-critic on solo diffs, and the cross-OS loop smoke test. **P3.2's surface half shipped via P1.1** — a dead drainer now renders loud in `sb status` + the loop-dead banner; the repair half stays routed to the cross-os-schedulers + P6 quarantine workstream. **P4.1 remains telemetry-gated** — no routing hint until P1.2 value rows show injected hints actually Read.
>
> **Update 2026-07-13:** P0.1+P0.2 released as **0.33.35** (`b3a3167`, CI green) — hardened by a 16-agent adversarial review that confirmed 10 findings, all fixed pre-release (line-boundary spine truncation, spaced-path extraction, de-tautologized effect lock, tools:-line + scoped-form dispatch-lock coverage, hermetic/placement-locked tests, skill-side req row). **P0.4 landed** (0.33.36): `wiki-write-guard.sh` denies any Write/Edit/MultiEdit into a literal `.second-brain/wiki/` tree with the canonical redirect — deny fires even with frontmatter; dream staging untouched; Windows form covered; rides `SB_PERSONA_GATE`; guard tests 12→17. **P0.5 next** *(stale — shipped in 0.33.36 `4df214b`, same release as P0.4; see Update 2026-07-14)* (anti-gaming slice, `SB_VERIFY_ANTIGAME`): verification evidence co-occurring with a test-file DELETION (`rm`/`git rm` of test-shaped paths — TDD test edits stay unflagged) turns the approve into one pointed block via the existing 2-block valve.
>
> **Original status (2026-07-08, uncommitted working tree):** **P0.1 landed** — code-map spine injected at SessionStart (`session-load.sh` §0d, kill switch `SB_CODEMAP_ORIENT`) + `code_neighbors`-before-editing move in `using-second-brain` + `test-session-load-codemap.sh`; verified live on the real 7.7 KB map. **P0.2 landed** — read-only `code_map`/`code_neighbors` granted to `code-review-unit-reviewer` + `quality-reviewer` (the two reviewers whose lens uses code structure), wired into each protocol, machine-locked in `agent-grants.test.ts` (parity + effect + a no-Agent/Task/Skill recursion lock). **P0.2 narrowed vs B0:** history/premise reviewers (git-blame / runtime-env lenses) and the wiki drainer were dropped — a code-structure grant there is off-lens/unused against P6a least-privilege. **P0.3 dropped:** only 3 of 18 shipped skills are preloadable via `skills:` frontmatter (the rest are `disable-model-invocation:true`) and none improves an existing agent.

Sequenced to **complement, not duplicate** the approved auto-team build and the queued P2/P6 — and to **measure before optimizing**. Every item stays inside the settled rails (no headless recursion, no out-of-band model-triggered side effects, no spend caps, no coercive banners, no usage-frequency feedback into ranking; every prose promise lands with a CI machine lock).

### Phase 0 — activate assets we already shipped (deterministic, in-session, low-risk)

**P0.1 — Wire the code-map into the orient rung (S).** Add deterministic `additionalContext` at SessionStart surfacing a compact code-map orientation pointer (the drainer already writes `map.md`/`graph.json`), and teach `using-second-brain` the *"run `code_neighbors` on a source file before you refactor/edit it"* move (doc-only SKILL.md edit). Both are read-assets that already exist → genuinely S. *Feature-detect a cold store; bounded terse hint, `allow` not `you MUST`.*
→ *Refuter split:* the **per-edit blast-radius hint is a separate S/M item, not "wiring"** — `code_neighbors` is MCP-only with no hook-callable CLI, so it needs a small node CLI verb over `graph.json`, ridden on `hook-timer.sh` (bounded/killable), feature-detected. Ship the SessionStart pointer + SKILL.md move now; scope the per-edit hint separately.

**P0.2 — Execute auto-team B0 as the standalone grant tranche (S).** Grant read-only `code_map`/`code_neighbors` to **all three** code-review reviewers (unit + history + premise) + quality-reviewer + raw-drainer, plus `test-no-agent-recursion.sh` (empty Agent/Task/Skill whitelist) and the agent-grants parity rows — **in one commit, verbatim as the team spec's B0**. Do *not* fork a narrower slice that must later be reconciled. Read-only orientation grant, same class as code-review-deep today; the no-recursion lock stays intact.

**P0.3 — Wire scoped skill-packs into EXISTING agents via `skills:` frontmatter (S–M). ⟵ the direct answer to "leverage ALL its skills+agents."** The team spec itself verified the platform fact: *subagent frontmatter honors `skills:`*. Attach domain skill-packs to the agents that already run — e.g. raw-drainer / knowledge-maintainer ← the wiki/memory `sb-*` skills; the code reviewers ← relevant domain skills. **Needs no `Skill` tool and does not breach the no-Agent/Task/Skill lock.** Makes agents leverage the installed library *today*, orthogonal to the team build; same-commit parity-testable. *(This was the refuters' central completeness catch: of the original 8 recs only one touched the skill library, and it was off-by-default and last.)*

**P0.4 — Fix the raw-drainer legacy-wiki misroute (S).** Root-fix the agent def so drained pages can't land in legacy `~/.second-brain/wiki` (invisible to `knowledge_search`) instead of canonical `~/knowledge/wiki`; pin `KNOWLEDGE_DIR` in the source + add a source-scan/parity guard. Closes a silent leak in the capture→recall→compounding loop the whole grows-with-use thesis depends on. *(Known bug: MEMORY `project_raw_drainer_wiki_misroute`.)*

**P0.5 — Anti-gaming slice of the Stop gate (S).** Flag a verification claim that **co-occurs with a test-file deletion/edit in the same diff** — the cheapest reward-hack from the W4 catalog. Machine-lockable.

### Phase 1 — measurement first (telemetry-only; firewalled from ranking/forgetting)

W4 is explicit that loop failures are *silent* and need trace-level evals, not uptime monitoring. Build the instrument before tuning the loop. **These counts must never feed search boost, forget weighting, or graph ranking** (undo rows 16-18, the rich-get-richer footgun).

- **P1.1 — Loop LIVENESS first:** last-drainer-tick, last-extraction, last-dream, raw-inbox depth. Makes the known cross-OS drainer breakage *visible* instead of silent — the prerequisite observable.
- **P1.2 — VALUE signals:** were injected wiki slugs / code-map hints subsequently Read; retrieval hit-rate.
- **P1.3 — UTILIZATION:** per-skill / per-agent invocation counts → a "dormant/dead capability" report. Directly substantiates "leverage ALL skills+agents" and makes routing (P4) tunable.
- **P1.4 — COMPOUNDING:** count prior-session-origin slugs recalled *and* subsequently Read in later sessions. Makes "grows with use" provable rather than asserted.

### Phase 2 — harden verification (the loop crux; strictly in-session)

- **P2.1 — Stop gate → deterministic backpressure (M).** Detect the actual changed-file set; when a diff touches runtime source, **strong-block with the exact verify command** rather than grepping for the word "test." *Refuter kill on auto-run:* do **not** auto-run the suite from the Stop hook in v1 — it blocks the turn for minutes, forks a second verify-command resolver (violating single-source discipline), and breaks the current fail-open invariant. If auto-run ever lands, it **must reuse auto-team B1's pinned-command resolver** + a hard timeout that fails open.
- **P2.2 — Auto-offer the EXISTING critic on solo diffs (M).** Gated, kill-switchable, in-session: dispatch the already-shipped **quality-reviewer** (fresh-context critic) or **`persona_think`** (independent Opus second opinion) on a substantive solo Stop-diff. This is the *judge* rung the rules tier can't provide — and it leverages shipped agents rather than new machinery. *(Refuter correction: the fit-map understated existing critics — persona_think + quality-reviewer already exist; the real gap is they're never auto-engaged on the 90% solo path.)*

### Phase 3 — ride the queued workstreams (don't fork them)

- **P3.1 — Shape P2 guardrails as an ACE-style delta playbook (L).** When P2 is built (plan exists at `docs/superpowers/plans/2026-06-30-p2-learning-to-guardrail.md`; code-less), persist learned guardrails as **itemized delta bullets** — stable IDs + helpfulness counters + transcript-citation, merged by **deterministic non-LLM logic** with embedding dedup and **bi-temporal soft-retire** — not free-text USER.md prose. **ACE** (Agentic Context Engineering — Stanford / SambaNova / UC Berkeley, Oct 2025, arXiv 2510.04618) is the closest published analogue to this plugin's design and validates every bet: delta+dedup beats full-rewrite, fixes context-collapse/brevity-bias, self-improves **+14.8% without labels** (verified measured, not claimed). Honors P2's ask-only cap (never auto-deny/rewrite) and the grounded-guardrail rail (a rule can't fire without citing evidence; contradicted rules auto-retire). Complements P6's quarantine (which owns the consolidation-safety trifecta separately).
- **P3.2 — Repair or at least surface the dead unattended drainer.** The scheduled discovery loop is structurally broken on the maintainer's own OS (Windows+macOS: no bwrap out-of-band drainer; auto_maintain broken on Linux too). Route the fix to the queued cross-os-schedulers + P6 quarantine workstream; at minimum, P1.1 liveness makes a dead drainer visible today.

### Phase 4 — experimental, gated, LAST

- **P4.1 — Bounded, off-by-default task→skill routing hint (M, high-risk).** A deterministic `UserPromptSubmit` matcher surfacing the top **1–2** relevant installed skills/agents as a terse `additionalContext` hint. **Only after** auto-team M2 ships **and** P1.2 telemetry shows orientation/recall hints are actually Read. Fold into `persona-context.sh` (no new script — surface-budget ratchet); kill switch, default off; deterministic hook hint, **not** a reintroduced full-catalog dump or a grown model-invocable set. If telemetry shows the hints go unread, kill it. *(Treads ground reverted for cause — per-prompt specialist catalog removed 0.32.0; undo row 13 — hence bounded + measured + reversible.)*

### Cross-cutting

- **X.1 — Cross-OS loop smoke test in CI.** Capture a fixture → drain → assert the page is `knowledge_search`-visible in canonical `KNOWLEDGE_DIR` → recall. Tests **the loop itself**, not just units — the exact gap that let the drainer die silently on Windows/macOS. Applies the "prose-promises-need-machine-locks" doctrine to the whole loop.

---

## Do NOT propose (settled/rejected ground)

- Headless recursive `claude` (OAuth blocks it) · out-of-band model-triggered side effects (containment doctrine / lethal trifecta).
- Unbounded model-invocable catalog / per-prompt specialist metadata dump (removed 0.32.0; undo row 13).
- Spend caps (undo row 10) — stop conditions stay step/iteration-based.
- `ln -s` on MSYS (deep-copies) — use node junctions.
- Usage-frequency / utilization feedback into ranking/forgetting (undo rows 16-18) — telemetry stays observation-only.
- Per-worker git worktrees / parallel write-workers (team non-goal).
- Replacing the operator with lights-out hundreds-of-instances recursion — not this plugin's model.
- Coercive "you MUST" banners — `additionalContext` is `allow`, not command.

## Corrections applied from the refuter pass

- Steinberger/Cherny lines attributed as **ideas**, not fabricated verbatim quotes (Osmani essay is the one verified verbatim source).
- `/goal` is a **native Claude Code command (v2.1.139+)** with its own independent verifier model — Osmani's essay points to it; he didn't create it.
- ACE affiliation = **Stanford / SambaNova / UC Berkeley** (not just Stanford/Berkeley); the +14.8%-without-labels figure is verified.
- Auto-team is **direction-approved but unbuilt** (untracked spec, 2026-07-08); B0 grant slice is independently shippable per the doc.
- MCP surface is **~23 tools** (adds code_map/code_neighbors + three persona_* tools), not 21.
- Osmani's anatomy has **six** components (external state is his 6th), not five.
