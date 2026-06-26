# second-brain Constitution + Diet — design

**Date:** 2026-06-26
**Status:** Draft for review
**Author:** brainstormed with user (machuta)
**Supersedes direction of:** [[second-brain-v1-redesign]] (2026-05-01) — which fixed "trash collector" once and regressed

---

## 0. Why this document exists

The plugin works but has **re-accreted into a trash collector** — the exact failure the
v1.0 redesign (2026-05-01) was built to fix, now regressed. Evidence:

- **90 wiki pages across 8 categories** (`decisions` alone = 40) — undifferentiated growth.
- The 2026-06-10 deep-dive: **59/63 confirmed defects**; `auto_maintain` at **100%
  structural failure**; **~10,000× search-score corruption** from the access-count boost.
- Code-level symptom this session: **one dir resolver copy-pasted to ~16 sites, 11 wrong**
  (the `process.env.HOME` CWD-relative bug). No single source of truth in the code either.

**Root cause (single):** accretion with no forcing function for simplicity, and a
self-cleaning ("doubt") loop that exists but does not reliably run. A second from-scratch
rewrite would regress the same way — v1.0 proves it. The lever is **governance, not codebase.**

## 1. The Constitution (north star — frozen)

**second-brain IS:** a local, growing knowledge source that guides Claude across a
project's life — it gathers important information and user decisions, remembers the track
and the high-level direction, and keeps Claude focused. It grows with the user. Everything
stays local. Persona is its guardrail layer (helps Claude decide, flags issues, enforces
rules so Claude codes better and understands the project). Dream is its background processor
(consolidate, refactor, forget). Claude must know how to **search, update, delete, and
process it in the background.**

**second-brain IS NOT:** a session log; a dumping ground for trivia; a graph maintained for
its own sake; a place where saved nodes go unread. **If a saved item does not actively guide
a future decision, it does not belong.**

This statement is the contract. Every later change is measured against it. It is enforced by
a write-time gate (§5) and a CI surface budget (§6), not by discipline alone.

## 2. Thesis: second-brain is hermes-shaped — it needs hermes' discipline, not replacement

Hermes Agent's five pillars map almost 1:1 onto what already exists here:

| Hermes pillar | second-brain equivalent | Current state |
|---|---|---|
| Memory (USER.md + MEMORY.md, frozen at session start) | USER.md + PROJECT.md hot tier + wiki | over-built |
| Skills (learning → reusable, loaded next time) | learnings/decisions wiki pages | **passive — unread = trash** |
| Soul | persona / charter | exists |
| Crons | extraction-timer + dream auto-stage | **dead** (100% fail) |
| Self-improving loop | dream FORGET / improve | **bolted on, not first-class** |

Hermes' transferable lessons, each achievable inside the Claude-plugin model (hooks + MCP +
skills + out-of-band timer):

1. **Memory is brutally simple on purpose.** Collapse the cold tier to the minimum that
   earns keep.
2. **Learning produces an active artifact** — a guardrail Claude loads next time, not a page
   that sits unread.
3. **The loop is a pillar, run by cron** — our cron is the out-of-band timer + dream; make it
   real, with delete/refactor as its primary output.

**Plugin-constraint note:** we cannot be an always-on autonomous server with its own chat
gateway (hermes' 20%). We do not need to be. Everything load-bearing — context at
SessionStart, search/update/delete via MCP, guardrails enforced at PreToolUse, background
refactor via the timer — is already expressible as plugin primitives.

## 3. Capability ledger — Keep / Fix / Cut

Nothing the user values is removed. Dream and persona are kept and **promoted**.

| Capability | Fate | Note |
|---|---|---|
| Dream: background consolidation (dedup/relate/enrich) | **KEEP + PROMOTE** | becomes P3, the doubt loop |
| Dream: FORGET / prune stale | **KEEP — make centerpiece** | the "self-recheck and refactor" |
| Dream: human review gate (staging → accept/discard) | **KEEP** | strength; never erase good content unreviewed |
| Dream: auto-stage on threshold | **KEEP, FIX** | cron dead: bwrap + `RestrictNamespaces` → fix runner, not feature |
| Persona L1: silent context per prompt | **KEEP** | the "assistant always present" |
| Persona L2: Opus brief (`/?`, `/think`) | **KEEP** | decision help on demand |
| Persona L3: PreToolUse tool guard | **KEEP + PROMOTE** | the P2 guardrail engine — feed learned rules in |
| Persona L4: quality gate (filters extractions) | **KEEP + PROMOTE** | the P2 anti-trash write-gate — make it the enforced default |
| Persona L5: MCP self-inspection | **KEEP** | cheap, useful |
| Hot tier (USER/PROJECT @ SessionStart) | **KEEP** | core |
| On-demand wiki search | **KEEP, simplify stack** | keep recall; thin machinery |
| Episodic recall (past sessions) | **KEEP** | "remember the track" |
| Extraction pipeline (transcripts → knowledge) | **KEEP, FIX + retarget** | fix timeout/cron; output decisions/guardrails, not orphan pages |
| **Access-count search boost** | **CUT** | caused ~10,000× corruption (R2) |
| **Typed knowledge graph** (edges.jsonl / relate / neighbors) | **DEMOTE** | stop ranking search by it (kills corruption); keep typed relations only as cheap read-time metadata |
| **8-category wiki split** | **COLLAPSE** | to a minimal set (§4) |
| 44K-token upgrade skill, duplicated vendored skills, dead scripts | **CUT** | pure surface (R6) |

## 4. Workstreams

Three workstreams + one forcing function. Each becomes its own implementation plan; this
spec is the contract they share. Ordered by dependency.

**P0 — Constitution + governance forcing function (this spec + §5/§6).**
Write the Constitution into the repo as an enforced artifact. Add the surface-budget CI gate.
Nothing else is safe to start until the anti-accretion mechanism exists — otherwise the diet
re-accretes.

**P1 — Diet the memory model.**
- Cut the access-count boost. Demote the graph (no search ranking).
- Collapse wiki categories to a minimal set. Proposed: **`project` (hot-tier mirror),
  `decisions`, `guardrails`, `reference`** — merging entities/concepts/themes/learnings/issues
  into decisions/guardrails/reference by function. Per-category page budget; merge mandate
  over create.
- Re-impose hot-tier token budget (≤800) and a wiki page-count budget.

**P2 — Learning → active guardrail (the anti-trash gate).**
- Every extraction/save resolves to exactly one of: (a) a PROJECT decision, (b) a persona
  guardrail rule (L3, fires at tool-time), or (c) discard. No orphan pages.
- Promote persona L4 quality gate from opt-in to enforced default; tighten it to the
  Constitution test ("does this guide a future decision?").
- Wire learned guardrails into `persona-rules.json` so they actually block at PreToolUse —
  closing the gap the SessionStart banner already warns about ("USER.md rules are advisory").

**P3 — Make the doubt loop real.**
- Fix the dead cron: remove `RestrictNamespaces=true` from the OAuth systemd unit / add the
  bwrap preflight on every platform; verify auto-stage runs unattended on Windows + POSIX.
- Promote dream FORGET to first-class: every dream proposes deletions/merges/contradiction
  flags as its primary output, reviewed via the existing accept/discard gate.

**Forcing function — anti-accretion governance (§5, §6).**

## 5. Write-time Constitution gate

A save is admitted only if it passes the Constitution test. Mechanism reuses persona L4
(already built): the quality gate becomes the enforced default and its acceptance predicate
becomes "does this actively guide a future decision, per §1?". Rejected content is dropped
loudly (logged), never silently — consistent with the project's fail-loud convention.

## 6. CI surface-budget gate

A test that fails the build when the surface exceeds budget:
- wiki page count per category over its cap (forces merge-not-create);
- skill/script/MCP-tool file counts over budget;
- duplicate-logic guard (generalize this session's `process.env.HOME` source-scan: no
  copy-pasted resolver/config-read patterns).

This is the mechanism v1.0 lacked. It is what makes the diet *stay*.

## 7. The one resolved decision: the graph

Demote, do not delete. Stop using the graph to rank search (removes the corruption surface).
Keep typed relations only as cheap read-time metadata shown when a page is opened, if useful.
Re-evaluate full removal after P1 if it earns no use.

## 8. Success criteria

- Constitution committed and CI-enforced; surface-budget gate green.
- Wiki page count down materially (target: a category set of ≤4, total pages bounded), with a
  documented merge of the collapsed categories — no knowledge lost, only re-homed.
- `auto_maintain` / dream auto-stage verified running unattended on Windows + one POSIX OS
  (evidence, not assertion).
- Every new saved item traceable to a decision or a guardrail; zero orphan pages added after
  the gate ships.
- Persona learned-guardrails block at PreToolUse (behavioral test), closing the advisory gap.

## 9. Non-goals (YAGNI)

- No autonomous always-on daemon / chat-gateway (out of plugin scope; hermes' 20%).
- No migration to hermes-agent — would relocate accretion and forfeit hard-won
  cross-platform fixes.
- No new retrieval tech (no vector DB swap) — fix the stack we have.
- No new wiki categories beyond the collapsed minimal set.

## 10. Scope boundary

This spec is the **Constitution + direction + capability contract**. Each workstream (P1/P2/P3)
is decomposed into its own implementation plan via the writing-plans skill, built and reviewed
independently under the existing release discipline (version-bump lockstep + migration row +
deep-review gate + green suite + the new surface-budget gate).
