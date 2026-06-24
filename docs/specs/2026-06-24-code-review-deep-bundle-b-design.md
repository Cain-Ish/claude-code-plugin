# code-review-deep Bundle B + cost-router routing — design

- **Date:** 2026-06-24
- **Status:** approved (brainstorm), pending implementation plan
- **Plugins touched:** `second-brain` (skills/code-review-deep, agents/code-review-\*) and `cost-router` (both live in this repo)
- **Supersedes nothing.** Extends: `2026-05-26-code-review-deep-v2-design.md`, `2026-05-27-code-review-deep-history-lens-design.md`, `2026-06-07-code-review-premise-lens-design.md`. Honors `code-review-deep-model-policy.md` ("do not revert") and `code-review-gate-lockstep.md`.

## 1. Motivation

The user supplied the upstream GitLab `anthropic-code-review` plugin (3 agents + 3 skills) as a *mirror* — the ancestor our `code-review-deep` evolved from — and asked what we should improve by comparing the two. Our skill is already a strict superset (4 specialized lenses, model routing, FP/fragile-premise stores, second-brain integration, low-confidence bucket, Pass 3.5 real-env probing). The comparison surfaced two reference capabilities we never adopted, plus three ours-only improvement candidates. The user selected **Bundle B** (a balanced release) and then added a cross-cutting constraint:

> Token cost is owned by **cost-router**. Do not bake token-cost optimization into the review skill. Instead, teach cost-router to **route to** the (self-tiering) skill.

A read-only investigation workflow (`wf_7a4e70a6-32e`, 5 agents) mapped cost-router and re-audited the skill's "cost" surface. Key finding that shapes this design: **cost-router cannot tier the skill's internal sub-dispatches.** It has no PreToolUse hook over a running skill, and it deliberately refuses to set `CLAUDE_CODE_SUBAGENT_MODEL` (that floor would clobber every second-brain agent pin — see `cost-router/skills/setup/SKILL.md` Step 4, `docs/reference.md:17`). So the skill *must* keep choosing its own per-dispatch models; "self-tiering" is the only available design. cost-router's role is limited to **recognizing a review request and pointing the user at the skill**.

## 2. Ownership boundary (the settled decision)

- cost-router owns the "how cheap" axis **only** for work routed through its own `orchestrate`/`cr-*` agents and per-dispatch `model:` keys.
- cost-router does **not** override second-brain agents' model pins. `code-review-deep` is a **sanctioned self-tiering carve-out** (`code-review-deep-model-policy.md`, status "settled in v2; do not revert").
- Integration direction: cost-router **recognizes** a deep-review request and **points at** `/second-brain:code-review-deep`. It never tiers it (no THINK→Opus nudge for review prompts) and never decomposes/delegates it. This is what prevents the *double-routing / two-routers-fighting* failure mode.
- The skill's per-pass model choices are **correctness/resource decisions, not price decisions** — and stay.

This boundary is recorded as a project decision (see §9).

## 3. cost-router changes

Target file: `cost-router/scripts/classify-prompt.sh` (v0.2.1, 105 lines, byte-identical to the installed `0.2.1` cache). cost-router and second-brain are published from this repo; edits propagate on reinstall.

### B1 — REVIEW detector + dedicated nudge (required)

Add a REVIEW classifier and a dedicated nudge that points at the review skill, taking precedence over the generic THINK/SCOUT nudge.

**Detection (conservative, word-bounded, multi-word only).** Reuse the existing punctuation-normalized padded copy (`P_PAD`, line 52) so trailing punctuation does not defeat the tokens. Match only review-tied phrases:

```
code review | code-review | review this pr | review the pr | review my pr |
review this mr | review the mr | deep review | deep code review |
review the diff | review my changes | review the changes | thorough review
```

**Never match bare `review`.** This is the CR-006 lesson encoded at lines 46–52: `refactor` and `security` were dropped entirely because bare substrings over-routed routine prompts. The detector must prefer false negatives ("review the logs", "review the plan", "review the meeting notes" must NOT fire).

**Emission.** After the always-on route-log emit (lines 84–87), if REVIEW matched:

1. Determine the skill pointer by **detect-&-degrade**: if second-brain's `code-review-deep` skill is installed → point at `/second-brain:code-review-deep`; else → point at `/cost-router:orchestrate`.
2. Emit the nudge via the existing `jq` emitter and `exit 0` **before** the generic THINK/SCOUT nudge block (lines 93–105), so a review prompt never also gets a tier nudge.

Detection check (Bash 3.2-safe, no network): test for the installed skill directory, e.g.

```sh
SB_REVIEW_SKILL=""
for d in "$HOME/.claude/plugins/cache/second-brain/second-brain/"*/skills/code-review-deep \
         "$HOME/.claude/plugins/marketplaces/second-brain/skills/code-review-deep"; do
  [ -d "$d" ] && { SB_REVIEW_SKILL="1"; break; }
done
```

Nudge text:

- present: `cost-router: this looks like a deep code review. Run /second-brain:code-review-deep — it multi-passes the diff and self-routes mechanical/doc work to the cheap tier and code+architectural passes to the best model. (cost-router does not tier it; the skill routes itself.)`
- absent (degraded): `cost-router: this looks like a code review. For tiered help run /cost-router:orchestrate. (Install the second-brain plugin for the dedicated /second-brain:code-review-deep multi-pass reviewer.)`

**Length floor.** The existing `< 25` char skip (line 94) is a triviality guard for generic tier advice. The REVIEW phrases are already specific multi-word signals, so the review path **bypasses** the 25-char floor — `review this pr` (14 chars) is a legitimate request that must still fire. (Documented deviation; the phrase specificity is the noise guard.)

**Kill switch.** No new switch. The existing `COST_ROUTER_AUTOROUTE=off` (line 31) already no-ops the entire hook before classification, which covers the review path for free.

**Ledger.** Keep `TIER` as classified for `route-log` (no schema churn). The REVIEW signal gates only the nudge text, not the ledger row. (If review-firing telemetry is later wanted, add it as a separate field — out of scope here.)

### B2 — on-demand advise-only bullets (approved scope)

Pure advice, no delegation (keeps "neither plugin needs the other"):

- `cost-router/skills/orchestrate/SKILL.md` (Step 1, ~lines 32–34): add a bullet — *"If the task is a deep code review, do NOT decompose it; invoke `/second-brain:code-review-deep` directly — it self-routes its own sub-agents."*
- `cost-router/commands/model-route.md`: add a line so `/cost-router:model-route "review PR 123"` recommends the skill instead of a raw tier.

Both must degrade gracefully in wording (point at the skill *if installed*; this is advice a human reads, so a parenthetical "if second-brain is installed" suffices rather than runtime detection).

## 4. code-review-deep changes (Bundle B)

All four Bundle-B changes, with model choices justified on **quality/resource** grounds (never price). Existing cost-rationale prose is left surgically intact except the cross-reference note in C6.

### C1 — ① prior-PR-comment mining (finding-generating, folded into Pass 0)

Extend the Pass 0 second-brain/context step (currently `episodic_search` → a "previously flagged / dismissed here" note). The same **Haiku** context agent additionally mines GitHub PR review comments and emits two outputs.

- **Discovery (no clean "PRs that touched file X" query on GitHub):** `git log origin/<base> -n 200 -- <changed files>` → parse PR numbers from merge/squash subjects (`Merge pull request #N`, `(#N)`) → cap at the ~10 most-recent distinct PRs → dedupe.
- **Fetch:** `gh api repos/{owner}/{repo}/pulls/{N}/comments` for inline review comments; keep only comments whose path is among the currently changed files (or same directory).
- **Output A (unchanged role):** fold into the existing advisory prior-review note threaded to the per-unit + history + premise reviewers.
- **Output B (new):** `prior-review` candidate findings — one per prior comment that **still applies** (the current change re-introduces/retains the concern), each citing PR #N + the comment. These flow into Pass 3 dedup + scoring exactly like history/premise findings.
- **Model:** the miner stays on Haiku. It is gather-and-filter; over-eager applicability calls are caught by the Pass 3 scorer (and criticals by the C3 refuter panel). No quality floor needed here.
- **Tooling:** add `Bash(gh api *)` to the skill `allowed-tools` (currently absent). Best-effort: no remote / no `gh` / no PR history → skip silently, note "no prior-PR signal."
- **Taxonomy:** add `prior-review` to the documented category list in the skill output section. The scorer gains a verification note (C3).
- **Degradation:** the existing single-context fallback path must also skip cleanly when `gh` is unavailable.

### C2 — ② inline-comment compliance (per-unit checklist item)

Add a checklist section to `agents/code-review-unit-reviewer.md`:

> **Inline-contract compliance** — does the diff violate guidance in nearby code comments? (`// keep sorted`, `// do not call before init`, `NOTE/INVARIANT/WARNING/HACK` notes, docstring contracts). Flag only when the change contradicts a still-valid in-code instruction, diff-scoped like everything else.

Reuse the existing `convention` category (zero enum churn across scorer/output). No new dispatch, no wave-cap impact. Inherits the unit reviewer's model (best model for code units).

### C3 — ③ adversarial refuter panel on critical/high findings (Pass 3)

In Pass 3 step 2 (scoring):

- **Medium/low severity findings:** single `code-review-scorer` (unchanged).
- **Critical/high severity findings:** a **3-vote panel** — scorer A (normal) + scorers B, C in **refute mode**. `final score = median(A, B, C)`, which is identical to "confirmed iff ≥2 of 3 score ≥70", so it drops into the existing ≥70 / 16–69 / ≤15 partition **with no rule change**.
- **Refute mode** is a prompt branch in `agents/code-review-scorer.md`: *"SKEPTIC MODE: assume this finding is a false positive. Actively search the code/history for evidence it is wrong, pre-existing, intentional, or linter-caught. Only score ≥70 if you cannot refute it."*
- **Model:** the panel scorers inherit the **session/best** model. This is a **quality floor** (a refuter must out-reason the original finder, like the code-unit reviewers and the gate-lockstep coupling) — explicitly *not* a cost choice and *not* deferrable.
- **prior-review verification note** added to the scorer: for `prior-review` findings, confirm the cited PR comment exists and that the current change actually re-triggers it; if the comment was resolved/addressed or targets unchanged lines, score low.

### C4 — ④ disallowedTools hygiene

Add `disallowedTools: Write, Edit, NotebookEdit, WebFetch, WebSearch` to the read-only review agents: `code-review-unit-reviewer`, `code-review-scorer`, `code-review-history-reviewer`, `code-review-premise-reviewer`, `quality-reviewer`. Verify each retains the Read/`git`/`grep` it needs. (Extends the `cc-feature-adoption-roadmap` note, which named scorer + history, to all read-only review agents.)

### C5 — extend the ≤5 wave cap to Pass 3 scoring (resource ceiling)

Pass 3 currently fans out one scorer per finding with no documented concurrency cap. The C3 refuter panel multiplies Pass-3 agents (×3 for each critical/high finding), so Pass 3 must obey the **same ≤5 concurrent-agent wave cap** as Pass 2 — scorers and refuters counted together. This is a Pi-RAM ceiling, not cost. Document the Pass-3 wave behavior in the SKILL.md (mirror the Pass 2 wave language).

### C6 — cost-ownership note + cost-router cross-reference

Add a short note to the skill's model/Notes section closing the bidirectional gap the precedent reader found (neither plugin references the other today):

> Model tiering here is the skill's own (self-routing). cost-router does **not** override it — it only routes a review request *to* this skill (see `cost-router/skills/setup`). The per-pass model choices below are correctness/resource decisions, not price decisions.

Leave existing per-pass cost prose intact (surgical). Only the **new** additions (C1 miner, C3 refuters, C5 cap) carry quality/resource justifications, never price.

## 5. Deliberately KEPT (not cost-driven — nothing important removed)

≤5 wave cap + slot accounting (`SKILL.md:81–100`); ≤15-files / ~3000-lines / ≤15-units bounds (`:56`); lean structured-only returns (unit/history/premise reviewers); `effort: high` on the three bug reviewers; best-model-for-code + the code-as-prompt `.md` exception (`:62,:77`); scorer-inherits-the-reviewer coupling (`:144–158`, `code-review-gate-lockstep.md`); RAM/RSS triage note (`:286–292`). The audit confirmed each is RAM/peak-agent/context-accuracy driven, not price.

## 6. Deferred (unchanged, documented for later)

- **#3 shard history/premise lenses** — only helps the large-PR tail; rewrites the fragile wave-1 slot accounting. Revisit when a real large PR demonstrates tail misses.
- **#4b completeness critic** — adds a whole extra orchestrator round; revisit after C3 lands and if recall (not precision) proves the bottleneck.

## 7. Testing

This repo gates releases on a clean `code-review-deep` run and on behavioral tests with an **independent oracle** (not re-asserting the implementation through its own reader).

### cost-router hook (scriptable, behavioral)

Drive `classify-prompt.sh` via stdin JSON `{"prompt": "..."}` and assert on emitted `additionalContext` (parsed with `jq`, an independent oracle):

- **REVIEW fires:** `do a code review of PR 12`, `review this pr`, `deep code review`, `please review the diff`, `thorough review of my changes` → output contains `/second-brain:code-review-deep` (when second-brain present) AND contains no `THINK →`/`SCOUT →` tier nudge.
- **Over-routing guard (must NOT fire review):** `review the logs`, `review the plan`, `review the meeting notes`, `let's review what happened` → no review nudge; normal tier path applies.
- **Detect & degrade:** with the skill dir present → second-brain pointer; with detection pointed at a nonexistent root (test shim) → `/cost-router:orchestrate` fallback wording, no `/second-brain:` string.
- **Kill switch:** `COST_ROUTER_AUTOROUTE=off` + a review prompt → empty output, exit 0.
- **Length floor bypass:** `review this pr` (14 chars) → review nudge fires (proves the review path skips the 25-char floor) while a generic 14-char prompt still produces nothing.
- **Precedence:** a prompt containing both a THINK word and a review phrase (`how should I review this pr`) → review nudge wins, no THINK nudge.

### code-review-deep (dogfood gate)

The skill is prompt-as-code; the oracle is a real run. Before merge, run the **improved** `code-review-deep` on this very change (the new prior-review lens, inline-comment check, and refuter panel review their own introduction). Plus scriptable checks: `validate-plugin.sh` passes; all five reviewer agents' frontmatter parses with the new `disallowedTools`; the skill `allowed-tools` now includes `gh api`; `prior-review` appears in the documented category list.

## 8. Rollout

- `cost-router`: behavioral change to `classify-prompt.sh` + content to `orchestrate/SKILL.md`, `commands/model-route.md` → version bump (0.2.1 → 0.2.2) + CHANGELOG.
- `second-brain`: skill/agent markdown only (prompt content) + one `allowed-tools` addition → patch release + CHANGELOG; the skill is content-loaded, no migration.
- Both ship from this repo; reinstall propagates to the caches.

## 9. Memory / decision to record

Pin the cross-cutting principle to the second-brain KB (project decisions): *"Token cost is cost-router's domain — do not bake price optimization into individual skills. Keep RAM/resource ceilings and quality floors inside the skill. cost-router cannot tier a running skill's internal dispatches (no PreToolUse over a skill; no SUBAGENT_MODEL floor by design), so to integrate a skill with cost-router make cost-router RECOGNIZE + POINT at it, never tier or decompose it. `code-review-deep` is the canonical self-tiering carve-out."* Relate to `code-review-deep-model-policy` and `code-review-gate-lockstep`.

## 10. Out of scope (documented for later)

- Sharding history/premise lenses (#3) and the completeness critic (#4b) — §6.
- cost-router actively delegating to (invoking) the skill — rejected to preserve the standalone boundary.
- A review-firing telemetry field in the route-log ledger — possible later, no schema churn now.
- Mining GitLab MR notes (the reference's `glab` path) — this skill is GitHub/`gh`-only.
