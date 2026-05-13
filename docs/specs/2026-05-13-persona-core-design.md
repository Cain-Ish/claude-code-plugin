# Persona Core — Design Spec

**Date:** 2026-05-13
**Status:** Draft for review
**Author:** second-brain v2.3.0 architecture pass
**Scope:** Promote the persona from passive memory layer to silent-but-present collaborator. Single plugin, no external dependencies beyond what Claude Code ships with.

---

## 1. Goal

The persona is the *self* of the second-brain plugin: an identity (who the user is, how they work), a memory (wiki + episodic + hot tier), a toolset (installed plugins/agents/skills the persona can route to), and a judgment layer (when to volunteer context vs. stay silent).

A senior-developer collaborator that's **always present, rarely loud**.

## 2. Reframe — what the research changed

Original vision: "persona supports user on each step of prompting, automatically uses best model."

Research finding that overrides naïve reading:

- **CHI 2025 ("Need Help?" study, Persistent Suggest condition)** — proactive AI assistants in coding contexts are perceived as "distracting" and "annoying." Users preferred non-proactive baseline. The false-positive cost of a nag dominates the false-negative cost of a missed insight in flow contexts.
- **Anthropic's Advisor Strategy (2026)** — cheap executor pulls Opus on demand via structured brief. Sonnet+Opus-advisor beat solo Sonnet by 2.7pp on SWE-bench AND reduced cost 11.9%. Pull-based escalation, not push-based routing.
- **Karpathy's LLM Wiki (2026)** — compile-on-ingest with Quality Gate validator before promotion. We already implement this; need to formalize.

**Reframe:** the persona is **always present** (silent infrastructure: identity card + plugin catalog + wiki hits injected per prompt, free) but **rarely speaks** (Opus deep brief only on user invocation or hard uncertainty). Best model on demand, not best model on every breath.

## 3. Constraints (from user)

- All capability ships in the second-brain plugin. No external MCP servers, no external databases, no pre-install dependencies.
- Public utilities available out-of-the-box (Node, bash, jq, `claude -p`) are fine.
- The persona must be dynamic: knows when to engage, when not.
- The best available model (Opus 4.7) is used when the persona engages, configurable via env var.
- Per-prompt and per-session kill switches required.

## 4. Architecture — five layers

The persona is **layered** so each layer can be disabled independently without breaking the others. The free layers are always on; the paid layer is opt-in.

### Layer 1 — Silent infrastructure (always on, $0)

Pure file I/O + cached enumeration. Injected into every UserPromptSubmit via `hookSpecificOutput.additionalContext` as **factual statements** (research finding: factual phrasing dodges prompt-injection defenses, imperatives get filtered).

Components:

| File | Purpose |
|---|---|
| `scripts/discover-installed.sh` | Enumerate `~/.claude/plugins/` + bundled plugins → JSON catalog at `~/.second-brain/.installed-catalog.json`. Refreshes on plugin dir mtime change. ~30 lines bash. |
| `scripts/persona-context.sh` | New UserPromptSubmit hook (replaces `intent-gate.sh`). Reads identity card + plugin catalog + top wiki hits. Emits `additionalContext` JSON. Hard cap 1200 bytes. **No LLM call.** |
| `~/.second-brain/persona-card.md` | Compact identity (role, communication style, working preferences). Pre-filled from existing USER.md + graduated signals on first run. Owned by user; persona reads, never writes. |
| `skills/using-second-brain/SKILL.md` | Obra-pattern meta-skill: frontmatter description `"Use when starting any conversation - establishes how to consult the persona's identity, memory, and tool catalog before answering"`. Forces Claude to acknowledge persona state. Pure prompt engineering, no enforcement. |

Layer 1 cost: $0. Latency: <50ms (file reads + cached JSON).

### Layer 2 — Pull-based deep brief (opt-in, ~$0.11/call)

User-triggered or self-triggered Opus call producing a structured advisor brief.

Components:

| File | Purpose |
|---|---|
| `mcp/src/tools/persona-think.ts` | New MCP tool. Input: `{prompt, context_hints?}`. Output: structured brief — `intent_read`, `prompt_enrichment`, `clarifying_questions` (0-2), `relevant_specialists`, `risk_flags`. Internally calls `claude -p` with Opus 4.7 (configurable via `SB_PERSONA_MODEL`). |
| `skills/think/SKILL.md` | User-invocable skill: `/second-brain:think [topic]` triggers the Opus brief inline. |
| `/?` prefix in `persona-context.sh` | If user prompt starts with `/?`, strip prefix, invoke `persona-think`, inject result as additionalContext, bypass Layer 1's silent injection (Opus subsumes it). |

Layer 2 cost: ~$0.11/invocation with Opus, ~$0.02 with Sonnet. User-controlled. `SB_PERSONA_DAILY_BUDGET` (default $20/day) auto-disables Layer 2 when exceeded.

### Layer 3 — PreToolUse mutation (rules-based, $0)

Persona-flavored tool intercept. Pure heuristic rules, no LLM. Catches the patterns the user has already expressed preferences against.

Components:

| File | Purpose |
|---|---|
| `scripts/persona-tool-guard.sh` | New PreToolUse hook. Reads `persona-rules.json`, matches tool input against rules, returns `permissionDecision: "allow"`/`"deny"`/`"ask"` + optional `updatedInput` to rewrite. |
| `~/.second-brain/persona-rules.json` | User-editable rule list. Default rules (from your existing USER.md preferences): strip `2>/dev/null` from Bash; warn on `git push --force` to main; warn on Write to USER.md/PROJECT.md outside pin tools. Extensible. |

Layer 3 cost: $0. Latency: <20ms (regex match).

Defaults SHIPPED with the plugin, NOT auto-mutating files the user hasn't reviewed.

### Layer 4 — Quality Gate (Haiku, ~$0.001/session-end)

Karpathy's "compile-on-ingest with validator" pattern, formalized. Runs at Stop/PreCompact, augments the existing extraction.

Components:

| File | Purpose |
|---|---|
| `scripts/quality-gate.sh` | New script invoked by `stop-extract.sh` after candidate extraction. Calls `claude -p` with Haiku: "is this a real insight, or session noise?" Returns boolean per candidate. |
| Extension to `scripts/stop-extract.sh` | Wraps the existing extraction in a quality-gate pass before merging to PROJECT.md / wiki. Rejected candidates logged to `.rejected-extractions.jsonl` for inspection. |

Layer 4 cost: ~$0.001/session-end. Latency: ~2s (Haiku is fast).

### Layer 5 — Persona MCP surface (free, on demand)

Exposes the persona's state to Claude as MCP tools so Claude can self-inspect.

Components:

| Tool | Purpose |
|---|---|
| `mcp__second-brain__persona_stats` | Returns: identity card summary, ungraduated signals count, top 5 wiki entries, dismissal count this week, recent dreams |
| `mcp__second-brain__persona_dismiss` | User signal: "the persona's last suggestion was unhelpful." Increments dismissal count, feeds backoff. |
| `mcp__second-brain__persona_recall` | Wrapper around episodic_search but persona-scoped: "what did *we* decide about X last time?" Already 80% of episodic_search. |

Layer 5 cost: $0. Mostly free read operations.

## 5. Defenses (from failure-mode research)

Three concrete defenses baked into Layer 1-2:

1. **Dismissal-aware backoff** (alert fatigue): persona-stats tracks `dismissal_count_7d`. If >3 in 7d, Layer 1 prunes its suggestions section (keeps catalog + wiki hits, drops opinionated framing). Auto-recovers when dismissal count decays.
2. **Untrusted-input quarantine** (prompt injection / XPIA): Layer 2's Opus call never sees raw tool output, web content, or file content directly. The brief is constructed from *extracted facts* (existing extract-prompt.txt pipeline) + persona-card + wiki abstracts. Already noise-filtered.
3. **Write-once-then-confirm** (memory contamination loops): Layer 4's Quality Gate never auto-writes to wiki. Rejected candidates are logged; accepted candidates are queued for `/second-brain:improve` user confirmation, matching the existing flow.

## 6. Cost model (realistic)

For a power user doing 50 substantive prompts + 5 session-ends + 10 explicit `/?` invocations per day:

| Layer | Default model | Daily calls | Daily cost |
|---|---|---|---|
| 1 (silent) | none | 50 | $0 |
| 2 (opt-in deep brief) | Opus 4.7 | 10 | ~$1.10 |
| 3 (tool guard) | none | 100 | $0 |
| 4 (quality gate) | Haiku 4.5 | 5 | ~$0.005 |
| 5 (MCP tools) | none | varies | $0 |
| **Total** | | | **~$1.10/day, ~$33/month** |

If user enables Opus on Layer 4 too: ~$2/day. If user invokes `/?` more aggressively: scales linearly with usage.

`SB_PERSONA_DAILY_BUDGET=20` (default) kills Layer 2/4 when daily spend exceeds threshold.

Compared to the originally-proposed always-on-Opus design ($200/month minimum), this is **~85% cheaper for equivalent or better outcomes** — because Opus only runs when actually needed.

## 7. Explicit non-goals (what we are NOT building)

- **Always-on Opus calls** — rejected. CHI research says proactive coding assistants are perceived as annoying; cost is also prohibitive.
- **LLM-driven PreToolUse on every tool call** — rejected. Latency unacceptable, cost untenable, value marginal (Aider, Anthropic guidance, my own analysis all converge).
- **External vector DB / MemGPT-style separate process** — rejected per user constraint. The wiki + episodic index already serve this role; no external dep.
- **Persona "learning" via RL/LoRA** (ruflo's framing) — rejected. Marketing-heavy in public ruflo docs; under the hood it's `recordExperience + recommendStrategy`, which is what we already have via persona-signals + extract-learnings. Don't build novel ML for something the existing graduation flow handles.
- **Multi-persona switching** — rejected. One persona, persistent. mickdarling/persona-mcp-style switching adds complexity for marginal value.
- **Federation / cross-machine persona sync** — out of scope for v2.3.0. Ruflo's federation plugin demonstrates this is its own product. Maybe v3.0.

## 8. Open questions for user review

1. **Persona card default content** — what should the initial `persona-card.md` contain when seeded from your existing USER.md + graduated signals? Proposed structure: identity (3 lines), communication style (3 lines), working preferences (5 lines), how to engage me (3 lines). 14 lines, ~600 bytes. Capped to keep Layer 1 cheap.
2. **Default Layer 3 rules** — initial `persona-rules.json` ships with: strip `2>/dev/null`, warn `git push --force` to main, warn writes to USER.md/PROJECT.md/plugin.json outside pin tools. Anything else worth shipping by default?
3. **Layer 2 trigger heuristic** — Opus brief fires on:
   - Explicit `/?` prefix (always)
   - Explicit `/second-brain:think` skill (always)
   - **Optional:** automatic trigger when prompt > 80 chars AND contains domain-crossing verbs (build/design/refactor/architecture). Off by default; opt-in via `SB_PERSONA_AUTO_THINK=on`.
4. **Quality Gate aggressiveness** — Layer 4's Haiku gate should reject what fraction of candidates by default? Conservative (only reject obvious noise, ~10% rejection rate) or aggressive (~30%)? Affects how much survives to user's `/improve` queue.

## 9. Implementation plan dependencies

Once this spec is signed off, `writing-plans` produces the task-by-task plan covering:

- T1: Discover script + catalog cache (foundation)
- T2: persona-card seed logic + setup skill integration
- T3: persona-context.sh (Layer 1 main hook)
- T4: using-second-brain meta-skill (Layer 1 forcing)
- T5: persona-think MCP tool + Opus call wrapper (Layer 2)
- T6: think skill + /? prefix support (Layer 2)
- T7: persona-tool-guard.sh + default rules (Layer 3)
- T8: quality-gate.sh + stop-extract integration (Layer 4)
- T9: persona MCP tools (Layer 5)
- T10: Tests across layers (TDD per task)
- T11: Migration row + bump to 2.3.0
- T12: README + status integration

Each task TDD'd, committed independently, then squashed into v2.3.0 release.

Estimated effort: 4-5 days focused, building bottom-up. Bigger than my usual recommended scope per release, but matches user's "bundle into one big v2.3.0" choice.

## 10. Self-review checklist

- [x] No placeholders ("TBD", "TODO", vague requirements)
- [x] Internal consistency (Layer 1's free claim verified against components; Layer 2's cost model checks out)
- [x] Scope appropriate for one release (5 layers + 12 implementation tasks is borderline-large but bounded)
- [x] Each ambiguity resolved with explicit choice + rationale, OR surfaced as a question in §8
- [x] All five research-recommended patterns mapped to a layer: Karpathy compile-on-ingest → Layer 4; Advisor pull-based escalation → Layer 2; Aider Architect/Editor split → reflected in cheap-default + Opus-on-demand; CHI silence-by-default → Layer 1 silent; FrugalGPT confidence cascade → could be added as Layer 4 enhancement (deferred)
- [x] All three failure modes have defenses: dismissal fatigue, prompt injection, contamination loops — all addressed in §5

Ready for user review.
