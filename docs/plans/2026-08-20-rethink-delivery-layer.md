# Rethink — the delivery layer is the product

**Status: PROPOSED (2026-08-20).** Direction approved by the maintainer: *rewrite delivery, keep
the data; delegate the hot tier to Claude Code's native memory.*

**Goal:** raise the measured injection→read rate from its current **0** to a non-zero, tracked
number, and delete every subsystem that does not move it.

---

## The measurement that drives this plan

`gate=value-loop` rows in `audit-log.jsonl`, written by `stop-extract.sh:119-201` since 0.33.36:

```
6 sessions:  injected=10  read=0  prior=0  hits=none
5 sessions:  injected=1   read=0  prior=0  hits=none
2 sessions:  injected=4   read=0  prior=0  hits=none
```

83 injected items over 13 sessions, **0 reads, 0 prior-session reuse**. The manifest
(`sb_manifest_add`, session-load.sh:29) covers only SessionStart injections; `persona-context.sh`
per-prompt wiki slugs are not instrumented, so the true denominator is larger and the true rate is
no better.

**The knowledge base is not the problem.** 372 pages, avg 3.6 KB, structured ai-blocks, 291 typed
graph edges, content that is genuinely decision-guiding (sampled). The write path works. The read
path converts nothing.

### Root cause of `read=0`: the injection gate thresholds a rank-derived score

Measured 2026-08-20 against the live wiki (372 pages, embeddings active).

**1. The floor is above the mathematical maximum.** Fused score = `1/(RRF_K+rank)` summed over two
rankers, `RRF_K=60` (knowledge-search.ts:269, :288-292). A document ranked #1 by *both* engines
scores `2/61 = 0.0328`. The only post-fusion multipliers are the stub penalty (×0.5, downward) and
recency (×1.3 max, :313). Absolute ceiling: **0.0328 × 1.3 = 0.04264**.

`persona-context.sh:185` gates injection at `SB_PERSONA_WIKI_MIN_SCORE=0.045`. **The gate is above
the ceiling** — per-prompt wiki injection cannot fire while embeddings are active. Measured: 0 of 7
well-formed queries cleared it; max top-score observed 0.04036.

It inverts in degraded mode: bm25-only scores are raw open-ended BM25, so the gate passes. Injection
works *only when search is broken* — which is why the field note "a wiki slug line in persona
context means bm25-only degraded search" was a correct observation of a backwards mechanism.

**2. Lowering the floor cannot fix it — the scale carries no relevance information.** RRF is
rank-derived: every query has a rank-1 document regardless of relevance. Measured top-scores,
6 genuine queries vs 5 nonsense queries:

| Scale | genuine (min) | nonsense (max) | separable? |
|---|---|---|---|
| Fused RRF | 0.02815 | **0.03707** | **No** — nonsense outscores 4 of 6 genuine queries |
| BM25 base | **48.58** | 28.48 | Yes — ~1.7× gap |

`"olympic swimming lane etiquette"` scores 0.03707 on the live wiki. No value of
`SB_PERSONA_WIKI_MIN_SCORE` separates signal from noise: raise it and nothing injects, lower it and
nonsense injects.

**Conclusion — the shape of the fix.** Relevance gating must read the frozen BM25 `baseScore`;
RRF stays for *ordering only*. The codebase already contains this insight one layer down —
`passesFloor` (:363-365) deliberately compares `baseScore` in bm25-only mode so a boost "can no
longer inflate the cutoff". The injection gate never got the same treatment.

Note the tier-suppression finding (#3 below) is real but **secondary**: it removes cross-project
pages from a candidate list that was never going to be injected anyway. Fix the gate first, then
re-measure whether tiering still costs anything.

---

## Evidence inventory (verified 2026-08-20, working tree 0.43.0)

| # | Finding | Evidence |
|---|---|---|
| 1 | Native memory now duplicates the hot tier | `~/.claude/projects/<slug>/memory/` — 24 typed memories here, 11 project dirs; MEMORY.md auto-loaded; auto-recall via system-reminders |
| 2 | Hot tier starves retrieval | 8,001 B used vs 3,365 B cap; 48 logged `gate=byte-budget … skipped` events, dropping `wiki-enrichment`, `sessions-digest`, `index-line` |
| 3 | Cross-project knowledge is suppressed below the injection floor | Same query: `SB_ACTIVE_SLUG=kiri-os` returns the correct page at rank 1; `SB_ACTIVE_SLUG=claude-code-plugin` returns neither it nor anything relevant. Floor `SB_PERSONA_WIKI_MIN_SCORE=0.045` |
| 4 | 35% of episodic memory is machine noise | 286 of 809 indexed exchanges are `<task-notification>` / hook-context / system-reminder blobs |
| 5 | Capture is deadlocked and losing data | 28 transcripts unextracted, oldest 27 days; archive pinned at the 100-file cap (`sb_prune_transcripts`, lib.sh:1316); escape gated on `ANTHROPIC_API_KEY` before the starvation branch (`extract-drain.sh:145`) |
| 6 | Project registry is polluted | 14 rows, 8 junk (`scratchpad`, `t3-proj`, `chan`, `chantest`, 2× `strix-cli-*`, `transcripts`, `curst`); brain-os picks the codemap target from this file |
| 7 | Dead schema | `security`, `sources`, `state` categories: 0 pages each |
| 8 | Consolidation machinery serves nothing | 5 dreams run, **0** pages ever forgotten (`wiki-archive/` empty), `wiki_archive_ttl_days: 0` |

Gate state at branch point — all green, so none of the above is a test failure:
`run-all.sh` 161 pass / 0 fail / 3 skip · vitest 757 pass / 9 skip · `tsc --noEmit` clean ·
`validate-plugin.sh` OK (1 WARN: undocumented `fork` matcher).

---

## Architecture after the rethink

Three primitives, one measured contract between them.

```
capture  ── session transcript ──> distilled page (wiki)          [keep, de-noise, unblock]
storage  ── ~/knowledge/wiki + graph/edges.jsonl                  [keep as-is, untouched]
delivery ── evidence-of-need retrieval ──> read ──> measured hit  [REWRITE — this is the product]
hot tier ── delegated to Claude Code native memory                [DELETE ours, write into theirs]
```

Target shape: **~33k lines → ~5k**, 19 skills → ~5, 23 MCP tools → ~10, 193 `SB_*` flags → ~15.

### Kill / keep ledger

| Verdict | Surface | Rationale |
|---|---|---|
| DELETE | `session-load.sh` hot-tier injection, `persona-context.sh` card/charter/signals, `USER.md`, `projects/<slug>/PROJECT.md`, `merge-persona-signals.sh` | Native memory does this, better, at no budget cost (finding 1); ours actively starves retrieval (finding 2) |
| DELETE | dream (`dream-*.sh`, `dream-runner`, 6 MCP tools), `brain-os-run.sh`, `maintain-llm-drain.sh`, `maintain-deterministic.sh`, FORGET trio | Elaborate consolidation of knowledge nothing reads (finding 8) |
| DELETE | `team`, `code-review-deep`, `doubt`, `improve` + 5 agents | Real tools, wrong repo — not memory |
| REWRITE | retrieval: unscoped-by-default hybrid search, evidence-of-need triggering, full read instrumentation | The product; currently converts 0 of 83 |
| REWRITE | capture: no OAuth deadlock, no fixed 100-file cap, noise filtered pre-index | Currently losing data (findings 4, 5) |
| KEEP | `~/knowledge` wiki + graph, `knowledge_search`/`knowledge_fetch`, `code_map`/`code_neighbors`, the 6 PreToolUse guards, `bin/sb` | Working, tested, valuable |

---

## Phases

Each phase ships independently and is gated on the value-loop number, not on completion.

### Phase 0 — Stop the bleeding, widen the measurement (no deletions)

- [ ] **0.1 Fix the injection gate (THE root cause).** Gate on the frozen BM25 `baseScore`, not the
      fused RRF score; RRF keeps ordering only. Requires: expose `baseScore` (or a `relevance`
      field) on the search result — note this touches `search-output-contract.test.ts`; switch
      `knowledge-search-cli.ts:24` to gate on it; retire `SB_PERSONA_WIKI_MIN_SCORE` for
      `SB_PERSONA_WIKI_MIN_BM25` (proposed default ~35, sitting in the measured 28.5→48.6 gap).
      Regression lock: a nonsense query injects nothing, a genuine query injects its known page,
      asserted in BOTH hybrid and bm25-only modes (CI runs degraded — a hybrid-only test proves
      nothing here).
      *Open calibration risk:* the default is fitted on 11 queries. BM25 is corpus- and
      query-length dependent; per-term normalization measured WORSE separation (8.1 vs 7.1). Ship
      the threshold with 0.2's miss-reason telemetry so it is tuned on real traffic, not on n=11.
- [ ] 0.2 Instrument per-prompt injection: `persona-context.sh` writes to the same session
      manifest (`sb_manifest_add` equivalent), so the denominator is complete. Today only
      SessionStart injections are measured.
- [ ] 0.3 Record *miss reasons* per injected item (below gate / injected-not-fetched /
      fetched-unused), so the zero always has a cause attached.
- [ ] 0.4 Cross-project retrieval — **re-measure before acting.** Tiering drops tier-5 pages
      (`knowledge-search.ts:371`) and sorts tier-major (:356). Two existing tests (`C1`,
      `SP-1 family`) assert that drop as correct, so changing it is a SPECIFICATION change needing
      an explicit decision, not a bug fix. Measured cost is currently masked by 0.1: the correct
      cross-project page scored 0.04152 vs 0.03672 for the best in-project page — only 1.13×, so a
      naive margin rule would not have surfaced it either.
- [ ] 0.5 Filter `<task-notification>` / hook-context / system-reminder blocks before episodic
      indexing; re-index. Assert noise share < 5%.
- [ ] 0.6 Unblock capture: starvation escape must fire under pure OAuth; replace the fixed
      100-file cap with an extraction-state-aware cap that cannot evict un-mined transcripts.
- [ ] 0.7 Purge the 8 junk rows from `projects.jsonl`; add a registration guard for scratch/temp
      roots.

**Exit criterion:** a `gate=value-loop` row with `read>0`, sustained over 5 sessions.
If Phase 0 cannot produce a non-zero read rate, no later phase is worth building.

### Phase 1 — Delegate the hot tier

- [ ] 1.1 Write distilled session output into the native memory dir (typed entries + MEMORY.md
      pointer) instead of `PROJECT.md`/`USER.md`.
- [ ] 1.2 Delete the hot-tier injection path and its byte-budget machinery.
- [ ] 1.3 Migrate existing `PROJECT.md` blockers/decisions into native memories or wiki pages;
      nothing is dropped.

**Exit criterion:** SessionStart injects 0 bytes of hot tier; no regression in the Phase 0 number.

### Phase 2 — Rewrite delivery

- [ ] 2.1 Retrieval fires on evidence of need (tool-use pattern, file context, explicit ask) rather
      than on every prompt.
- [ ] 2.2 Progressive disclosure end-to-end: identifiers first, body only on fetch.
- [ ] 2.3 Close the loop: miss reasons from 0.2 drive ranking changes, each validated against the
      read rate.

### Phase 3 — Delete

- [ ] 3.1 Remove the DELETE-ledger surfaces, their tests, agents, skills and flags in one commit
      per subsystem, ratcheting `surface-budget.json` down each time.

### Phase 4 — Consolidate what remains

- [ ] 4.1 Split `lib.sh` (2,351 L) and whatever survives of `session-load.sh` (1,027 L) to the
      800-line ceiling.
- [ ] 4.2 One wiki-write chokepoint instead of 17 call sites.
- [ ] 4.3 Flag audit: every surviving `SB_*` flag justifies itself or dies.

---

## Constitution compliance

- **Fully autonomous** — no phase adds a required manual step. Phase 1 moves writes to a
  directory the harness already owns.
- **Untrusted-content isolation** — unchanged. Deleting the dream/consolidation lane *removes*
  the largest untrusted-input attack surface rather than adding to it.
- **Cross-platform** — Phase 0.5 fixes a Windows-only deadlock; the bash-3.2/BSD floor, jq-CRLF
  discipline, and no-native-deps rules all still apply.
- **Token discipline** — this plan is the token-discipline plan: it deletes the always-injected
  tier and spends the budget only on retrieval that is proven to be read.
- **Surface-budget ratchet** — Phase 3 ratchets DOWN, which the gate permits freely.

## Non-goals

- Porting the wiki to a new schema or store. `~/knowledge` is not touched by any phase.
- Rebuilding `knowledge_search`'s BM25/RRF/ONNX core. It works; only its *triggering and scoping*
  change.
- Preserving `auto_accept`, `brain_os`, or the dream lifecycle in any form.
