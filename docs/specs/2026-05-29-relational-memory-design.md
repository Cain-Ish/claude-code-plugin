# Design: bi-temporal relational memory (typed, multi-hop knowledge graph)

**Date:** 2026-05-29
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session
**Target release:** 0.22.0 (plugin) / knowledge-base MCP 2.3.0

## Summary

Today the second-brain reliably remembers **nodes** (facts: decisions, blockers,
wiki pages) across sessions, but the **edges** between them — "changing A *affects*
B,C,D,E and *requires* F,G,H" — are second-class:

- The per-session extractor (`extract-prompt.txt`) emits no relationship field;
  `merge-project-update.sh` writes every new page/stub with `related: []`. So edges
  are **never captured at session time** — they exist only after a periodic LLM
  consolidation pass (dream RELATE / `knowledge-maintainer` Phase 3).
- That consolidation pass is exactly the layer that has been **degraded** for this
  user (OAuth-vs-`--bare` extractor conflict; see PROJECT.md `[degraded]` entries
  2026-05-22→28). When it is down, the relational layer simply does not accrue.
- The one existing relational signal — `related:` frontmatter — is **untyped**
  (no `requires` vs `affects` distinction), **one-hop** (graph boost in
  `knowledge-search.ts:116-127` propagates a single hop), and **drift-prone**
  (bidirectionality is a best-effort LLM instruction in `knowledge-maintainer.md:95`,
  never validated).
- There is no notion of **time on a relationship**. The user's own wiki proves this
  is needed: `pi-ip-ufw-sync` was *required* by the WireGuard recovery path from
  2026-05-21 and **RETIRED** 2026-05-29 (`cascade-failure-2026-05-19.md:111`). That
  is a relationship with a *validity interval*, currently only expressible as prose
  in a `## Updates` log — not queryable.

This design makes relationships **first-class, typed, bi-temporal, and multi-hop**,
modelled on the Graphiti/Zep temporal-knowledge-graph architecture (explicit
`(t_valid, t_invalid)` validity intervals; contradictions *invalidate, not delete*;
point-in-time "as-of" queries). The store is an **append-only JSONL edge log** that
becomes the single source of truth for the graph; human-readable `related:` links
and per-page dependency blocks are **deterministically projected** from it, so the
existing BM25 graph-boost and the self-describing wiki keep working unchanged.

The end-to-end capability delivered: **tell Claude once that "changing A relates to
B,C,D,E and requires F,G,H," and a fresh session recalls the whole typed dependency
neighbourhood automatically — time-filtered to what is currently true — without the
user re-explaining it.**

## Goals

- **Typed edges**: `requires`, `affects`, `relates`, `part_of`, `supersedes`.
- **Bi-temporal**: every edge carries *valid time* (`valid_from`/`valid_to`, when the
  fact was true in the user's world) and *transaction time* (`recorded_at`, when the
  brain learned it). Two independent clocks.
- **Capture-time emission**: edges land every substantive session via the extractor,
  so the graph accrues **even when the LLM consolidation pass is degraded**. This is
  the primary robustness requirement.
- **Manual same-session assertion**: a `knowledge_relate` MCP tool lets a confirmed
  relationship be asserted immediately — recall works next session with no dream wait.
- **Multi-hop, time-filtered retrieval**: a `knowledge_neighbors` tool and an upgraded
  graph-boost walk the current-valid typed graph N hops, in either direction
  (out = dependencies, in = blast radius).
- **Mark-not-delete**: invalidation/supersession preserves history; `as_of(T)`
  reconstructs the graph at any past date.
- **Bidirectional by construction**: edges are stored once, directed; recall walks
  both in- and out-edges. Drift is structurally impossible — no reverse row to fall
  out of sync.
- **Deterministic at the write step**: the LLM only *proposes* edges; the append and
  projection are plain code that runs offline / Claude-unavailable.
- **Strict backward compatibility**: with no graph store present, behaviour is
  byte-for-byte identical to 0.21.4 — mandatory for a published, P0-supply-chain plugin.
- **No new heavy dependency**: JSONL + existing TypeScript only.

## Non-goals (YAGNI)

- **No graph database** (Neo4j, SQLite, etc.). A file-based append-only JSONL log
  matches the existing all-files architecture, ships in `dist/`, diffs cleanly in
  git, and adds nothing to vet in the supply chain. Rejected DB engines explicitly.
- **No embeddings *on edges*.** Node-level hybrid search already exists
  (`knowledge-search.ts` RRF fusion); edges are walked structurally, not embedded.
- **No automatic re-typing during migration.** Migration imports existing `related:`
  links as untyped `relates` only — it never *guesses* `requires`/`affects`.
  Re-typing is later, LLM-judged, opt-in work.
- **No third temporal dimension** (decision time). Valid + transaction time is the
  Graphiti standard and sufficient here.
- **No UI / graph visualiser.** Out of scope; the projected `## Dependencies` block
  and the MCP tools are the interface.
- **No change to USER.md / persona-card semantics.** This is the wiki/graph layer
  only. (Skill upgrades — maintainer-as-caretaker, persona-as-wingman — are a
  separately-scoped follow-up, tracked outside this spec.)

## Background: what exists today (must keep working)

| Component | File | Current behaviour |
|---|---|---|
| Per-session extractor | `scripts/extract-prompt.txt` | Emits `recent_decisions`, `open_blockers`, `cross_refs` (slugs), `wiki_updates`, `persona_signals`. **No relationship field.** |
| Merge | `scripts/merge-project-update.sh` | Writes new pages/stubs with `related: []` (lines 292, 405-415). |
| Page schema | `~/knowledge/wiki/<cat>/<slug>.md` | Frontmatter `related: [[slug]], …`; optional body `## Cross-references`; inline `[[links]]`. |
| Search | `mcp/src/tools/knowledge-search.ts` | BM25 (title 3× / desc 2× / tags 2× / body 1×) + ONNX RRF fusion + **one-hop** untyped graph boost (0.3) + stub/access/recency boosts. |
| Validate | `mcp/src/tools/knowledge-validate.ts` | Detects broken-link / orphan / missing-frontmatter / dup-slug / stale / empty. **No asymmetry check.** |
| Reindex | `mcp/src/tools/knowledge-reindex.ts` | Validates (autofix) + rebuilds flat `index.md`. |
| Consolidation | `agents/knowledge-maintainer.md`, `agents/dream-runner.md` | Phase 3 RELATE adds `related:` links, bidirectional *by instruction*. |
| Session load | `scripts/session-load.sh` | Injects hot tier; keyword-searches wiki; surfaces top-8 slugs (8000-byte budget). |

The two hard constraints these impose: (1) `related:` frontmatter must remain present
and correct as a projection target so BM25 graph-boost is unaffected; (2) every new
code path must no-op cleanly when the graph store is absent.

## Architecture overview

```
            CAPTURE (proposes)                 STORE (truth)            PROJECT (view)
  ┌───────────────────────────────┐      ┌──────────────────┐    ┌──────────────────────┐
  │ extractor   → merge-edges.sh   │─────▶│ graph/edges.jsonl │───▶│ related: (frontmatter)│
  │ dream/maint → RELATE curation  │      │  (append-only,    │    │ ## Dependencies block │
  │ manual      → knowledge_relate │      │   bi-temporal)    │    │  (generated, fenced)  │
  └───────────────────────────────┘      └──────────────────┘    └──────────────────────┘
                                                   │
                                                   ▼  READ (as_of-filtered)
                                   ┌───────────────────────────────────────┐
                                   │ knowledge_neighbors (multi-hop, typed) │
                                   │ knowledge_search graph-boost (upgraded)│
                                   │ session-load neighbourhood injection   │
                                   └───────────────────────────────────────┘
```

**Source of truth = the log.** Pages are a deterministic, regenerable view. You change
the graph by appending to the log (via a tool or a hook), never by hand-editing prose.

## 1. Data model

### 1.1 Storage location
```
~/knowledge/graph/edges.jsonl            # append-only, source of truth
~/knowledge/graph/edges-quarantine.jsonl # edges whose endpoints didn't resolve
```
Under `~/knowledge/` (the existing knowledge root, honours `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR`),
**not** `wiki/`, so `collectMarkdown()` and the validator never treat it as a page.

### 1.2 Edge record (one JSON object per line)
```jsonc
// assertion
{"op":"assert","from":"wg-tunnel","to":"pi-ip-ufw-sync","type":"requires",
 "valid_from":"2026-05-21","valid_to":null,
 "recorded_at":"2026-05-21T18:30:00Z","source":"dream:drm_20260521","confidence":"high"}

// invalidation — pi-ip-ufw-sync retired 2026-05-29 (MARK, do not delete)
{"op":"invalidate","from":"wg-tunnel","to":"pi-ip-ufw-sync","type":"requires",
 "valid_to":"2026-05-29","recorded_at":"2026-05-29T12:00:00Z",
 "reason":"VPS UFW de-pinned; pi-ip-ufw-sync retired","source":"manual"}

// supersession — new dependency replaces the old
{"op":"assert","from":"vps-ufw-depinned","to":"pi-ip-ufw-sync","type":"supersedes",
 "valid_from":"2026-05-29","valid_to":null,"recorded_at":"2026-05-29T12:00:00Z","source":"manual"}
```

| Field | Meaning |
|---|---|
| `op` | `assert` \| `invalidate` |
| `from`, `to` | edge endpoints — wiki slugs (kebab-case) |
| `type` | `requires` \| `affects` \| `relates` \| `part_of` \| `supersedes` |
| `valid_from` | start of *valid time* (world truth). Date or ISO. Defaults to `recorded_at` date. |
| `valid_to` | end of valid time; `null` = still true (= Graphiti `t_invalid` open) |
| `recorded_at` | *transaction time* — when the brain learned it. ISO-8601 Z. |
| `source` | `extractor` \| `dream:<id>` \| `manual` \| `migration:v1` |
| `confidence` | `high` \| `medium` (extractor/LLM only; manual = high) |
| `reason` | optional, on `invalidate` |

### 1.3 Edge identity & current state
- **Identity** = `(from, type, to)`.
- **Current state** of an identity = fold its records in `recorded_at` order; an
  `invalidate` sets `valid_to`. An `assert` of an already-live identity is a **no-op**
  (idempotent). An `assert` that contradicts (e.g. re-points) routes through
  invalidation first.

### 1.4 The `as_of(T)` predicate (the one rule everything reads through)
An edge is **valid at time T** iff:
```
valid_from <= T  AND  (valid_to is null OR valid_to > T)
```
The interval is **half-open** `[valid_from, valid_to)` — an edge invalidated on date D
is *not* valid at D itself. Implementations MUST use strict `>` on `valid_to` (using
`>=` silently breaks the boundary cases in test #2). Compare as dates when both operands
are date-only, else as ISO timestamps.
- Default `T = now` → current truth (what almost every read wants).
- `T = 2026-05-19` → reconstruct the cascade-incident-day graph.
- This is the existing `## Updates` prose log, made queryable.

### 1.5 Edge types (typed + inherent direction)
| Type | Direction semantics | User sentence |
|---|---|---|
| `requires` | A depends on B (out = deps of A) | "A **requires** F,G,H" |
| `affects` | changing A impacts B (in = blast radius of B) | "changing A **affects** B,C,D,E" |
| `relates` | soft association (symmetric meaning, stored directed) | generic `related:` |
| `part_of` | A is a component of B | composition |
| `supersedes` | A replaces B (temporal) | "F replaced by F′" |

**Bidirectionality is solved by construction**: one directed row; recall walks
out-edges *and* in-edges. "What does A require?" = out/`requires`. "What breaks if A
changes?" = in/`affects` + in/`requires`. No reverse row exists to drift.

## 2. Capture (write path)

All three writers append to the same log; the **append itself is deterministic code**
(works with Claude unavailable). The LLM only *proposes* candidate edges.

### 2.1 Capture-time — extractor (primary robustness path)
- `extract-prompt.txt` gains a top-level array:
  ```jsonc
  "relations": [
    {"from":"<slug>","to":"<slug>","type":"requires|affects|relates|part_of",
     "valid_from":"<YYYY-MM-DD optional>","confidence":"high|medium"}
  ]   // max 5 per session; only relationships explicitly established this session
  ```
- New `scripts/merge-edges.sh` (invoked from `stop-extract.sh`, after
  `merge-project-update.sh`) appends each as `op:assert`, `source:"extractor"`.
- **Endpoint guard (per [[validate-the-real-capability]]):** before appending, each
  endpoint slug must resolve to a real wiki page **or** a slug already present in this
  delta's `wiki_updates`/`cross_refs`. Unresolved → written to
  `edges-quarantine.jsonl`, never to `edges.jsonl`. A bad extraction cannot poison
  the graph.

### 2.2 Consolidation-time — dream / knowledge-maintainer (RELATE upgrade)
Phase 3 RELATE is upgraded from "add `related:`" to **edge curation**:
- Propose new typed edges (it may upgrade migration's untyped `relates` to
  `requires`/`affects` under LLM judgment).
- Perform **invalidation/supersession**: when a newer page contradicts a live edge,
  append `op:invalidate` + a `supersedes` assertion. (LLM judges "is this a
  replacement?"; the write stays code.)
- `source:"dream:<id>"`. Still bounded by the agent's existing 50-change cap.

### 2.3 Manual / in-session — `knowledge_relate` MCP tool (the user's literal scenario)
```
knowledge_relate({ from, to, type, valid_from?, reason? })
```
Appends `op:assert`, `source:"manual"`, `confidence:"high"` immediately. When the user
confirms a relationship mid-session, it is asserted at once — recall works in the very
next session with no dream dependency. A companion `op:invalidate` is reachable via
`knowledge_relate({ ..., invalidate:true, valid_to })`.

## 3. Projection (log → human-readable pages)

A deterministic projector (a function called by `knowledge_reindex`, after the
post-Stop merge, and on dream-accept) reads `edges.jsonl`, computes `as_of(now)` valid
edges per node, and regenerates **two** views. **The log is truth; pages are the view.**

### 3.1 Frontmatter `related:` (back-compat target)
`related:` is rewritten as the untyped union of a node's current-valid neighbours
(both directions). This keeps the existing BM25 graph-boost in `knowledge-search.ts`
working with **zero changes to that boost's input contract**.

### 3.2 Body `## Dependencies` block (self-describing wiki, offline)
A fenced, generated block — so opening a page in an editor shows current deps with no
tool running:
```markdown
<!-- graph:begin (generated from ~/knowledge/graph/edges.jsonl — do not hand-edit) -->
## Dependencies (as of 2026-05-29)
**Requires:** [[vps-ufw-depinned]]
**Affects:** [[router-daemon]], [[cainish-evolve-vps-collector]]
**Superseded:** [[pi-ip-ufw-sync]] (valid 2026-05-21 → 2026-05-29)
<!-- graph:end -->
```
Idempotent. Only the region between the markers is rewritten. Hand-edits inside the
markers are overwritten; `wiki-write-guard` warns if it sees a manual edit there.

## 4. Retrieval (read path)

### 4.1 `knowledge_neighbors` (new MCP tool) — one-call dependency neighbourhood
```
knowledge_neighbors(slug, { depth=2, edge_types?, direction="both", as_of="now" })
  → { slug, edges:[{from,to,type,hops,score,valid_from,valid_to}] }
```
- BFS over `as_of(T)`-valid edges, up to `depth` hops, per-hop score decay.
- `direction`: `out` = A's dependencies; `in` = blast radius; `both` = default.
- This is the direct answer to "touch A → surface B,C,D,E + F,G,H."

### 4.2 `knowledge_search` graph-boost upgrade
Replace the one-hop untyped boost (`knowledge-search.ts:116-127`) with a bounded
multi-hop walk over **current-valid typed** edges:
- per-type weight (`requires`/`affects` propagate stronger than `relates`),
- decay per hop (`0.3`, `0.3²`), capped at `depth=2`,
- guarded: if `graph/edges.jsonl` absent, fall back to **today's exact behaviour**
  (reads `related:` from frontmatter, one hop) — golden-file tested.

### 4.3 `session-load.sh` neighbourhood injection
For the active project's key entities (the slugs already mined for keyword search),
inject their `as_of(now)` typed neighbourhood — slugs + edge types only, not full
pages — within the **existing 8000-byte budget** (spills after wiki enrichment, before
dream nudge). Result: a fresh session's hot tier already contains "changing A affects
B,C,D,E / requires F,G,H," automatically.

## 5. Migration & backward compatibility

### 5.1 One-shot migration (`scripts/graph-migrate.sh`)
- Walk all wiki pages; for each `related:` entry and body `[[link]]`, append
  `op:assert, type:relates, source:"migration:v1"`, `valid_from = page.created`,
  `recorded_at = now`.
- **Untyped on purpose** — never guess `requires` vs `affects`.
- Idempotent (re-run = no dupes; identity de-dup). Reversible (delete `graph/` →
  pages still carry their original `related:`; nothing destroyed).
- Gated behind explicit invocation (and an `upgrade` skill step), never automatic on
  plugin update.

### 5.2 Back-compat guarantees (published-plugin grade)
- **No `graph/` dir ⇒ 0.21.4 behaviour, byte-for-byte.** Every new path guards on log
  existence. A fresh install or another user's wiki sees no change until they opt in.
  This is the single most important invariant — owns golden-file test #6.
- `related:` stays the projection target ⇒ BM25 graph-boost untouched for non-adopters.
- New MCP tools (`knowledge_relate`, `knowledge_neighbors`) are additive; no forced
  schema migration.
- No new runtime dependency.

## 6. Error handling

| Failure | Behaviour |
|---|---|
| Torn final line (writer killed mid-append) | Loader parses line-by-line, **skips** the only-possibly-bad last line, keeps all prior edges. Each append is a single one-line `>>` write (atomic in practice). |
| Edge endpoint → archived/forgotten slug | Coexists with forget/restore: rendered as historical (`supersedes`/past `valid_to`), **never** flagged as a broken link (mirrors `knowledge-maintainer.md:146-165`). |
| Projector vs hand-edit race | Only the `graph:begin/end` region is rewritten; `wiki-write-guard` warns on manual edits inside it. |
| Corrupt / empty log | Treated as "no graph" → fall back to current `related:` behaviour. Never crashes a hook (precedent: the verify.sh empty-file fix). |
| Extractor proposes unresolved/garbage edge | Quarantined (`edges-quarantine.jsonl`), never asserted. |
| Two writers append concurrently | Append-only + line-atomic ⇒ interleave-safe; identity fold at read time resolves order by `recorded_at`. |

## 7. Testing strategy

Per [[validate-the-real-capability]], tests prove the **real capability** (an edge
round-trips the whole pipeline), not that a field exists. Wired into the existing
`tests/test-*.sh` harness and gated by the deep-review release gate
([[deep-review-release-gate]]).

1. **Round-trip**: assert `wg-tunnel --requires--> pi-ip-ufw-sync` →
   `knowledge_neighbors(wg-tunnel)` returns it → projector writes it into the page.
2. **Bi-temporal as-of (headline)**: assert valid 2026-05-21, invalidate 2026-05-29 →
   `as_of(2026-05-25)` includes; `as_of(now)` excludes; `as_of(2026-05-19)` excludes.
3. **Mark-not-delete**: after invalidation the historical row is still present and
   queryable.
4. **Bidirectional-by-construction**: one stored edge → `direction:out` from A and
   `direction:in` from target both return it; assert no reverse row exists.
5. **Multi-hop + decay**: A→B→C, `depth:2` from A reaches C at lower score than B.
6. **Back-compat golden file**: with no `graph/` dir, `knowledge_search` output is
   identical to pre-change baseline.
7. **Resilience**: corrupt the last log line → loader returns all prior edges, exit 0.
8. **Migration idempotency**: run twice → no duplicate edges.
9. **Quarantine**: extractor proposes an edge to a non-existent slug → lands in
   quarantine, not in `edges.jsonl`.

## 8. File-change inventory (for the implementation plan)

**New:**
- `mcp/src/tools/graph-store.ts` — append, fold-to-current, `as_of(T)`, BFS neighbours, loader (torn-line-safe).
- `mcp/src/tools/knowledge-relate.ts` — manual assert/invalidate MCP tool.
- `mcp/src/tools/knowledge-neighbors.ts` — multi-hop typed retrieval MCP tool.
- `scripts/merge-edges.sh` — append extractor-proposed edges (with endpoint guard).
- `scripts/graph-migrate.sh` — one-shot `related:`→log import.
- `tests/test-graph-store.sh` (+ fixtures).

**Modified:**
- `scripts/extract-prompt.txt` — add `relations` array to schema + rules.
- `scripts/stop-extract.sh` — call `merge-edges.sh` after merge.
- `mcp/src/tools/knowledge-search.ts` — multi-hop typed graph-boost (guarded fallback).
- `mcp/src/tools/knowledge-reindex.ts` — invoke the projector.
- `mcp/src/tools/knowledge-validate.ts` — graph-aware (no false "broken link" on
  historical/quarantined edges); optional asymmetry check now moot (no reverse rows).
- `mcp/src/server.ts` — register `knowledge_relate`, `knowledge_neighbors`; bump server to 2.3.0.
- `scripts/session-load.sh` — inject active-project neighbourhood within byte budget.
- `agents/knowledge-maintainer.md`, `agents/dream-runner.md` — RELATE → edge-curation
  (assert + invalidate/supersede), `knowledge_relate`/projector awareness.
- `skills/upgrade/SKILL.md` (or equivalent) — optional one-shot `graph-migrate.sh` step.

## 9. Rollout

1. Ship graph-store + tools + projector **dormant** (no `graph/` dir created on update).
2. User opts in by running `graph-migrate.sh` once (gated, reversible).
3. Capture paths begin appending; projection populates pages at next reindex.
4. Validate with the test suite + a deep-review pass before release (per the gate).
5. Skill upgrades (maintainer-as-caretaker, persona-as-wingman) follow in a separate
   spec, built on this foundation.
