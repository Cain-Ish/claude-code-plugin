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

## Scope audit — the live surface against the four content classes

Added 2026-08-20 after the maintainer restated the founding intent: *decisions, code map,
high-level decisions, and session recap so nothing important is missed*. Those four are now the
scope rule in `CONSTITUTION.md` ("What belongs in memory"). Applying them to the 0.43.0 surface:

**In scope, working.** Classes 1-3. `wiki/decisions` (63 pages), `wiki/concepts` (40),
`wiki/entities` (119), `wiki/themes` (12), `wiki/learnings` (56), the typed graph, and
`code_map`/`code_neighbors`. The write path produces genuinely decision-guiding content.

**In scope, broken.** Class 4 — session recap — is the class the founding intent leads with and
the one that fails: 28 transcripts unextracted (oldest 27 days, finding 5), 35% of the episodic
index is machine noise (finding 4), and nothing that is captured is ever read (0 of 83, the
value-loop measurement). Fixing class 4 end-to-end is Phase 0; it is the highest-intent, lowest-
functioning part of the system.

**Outside all four classes** — real tools, wrong repo. None of these produce, store, or deliver
decisions, architecture, a code map, or a session recap:

| Surface | Count | Class served |
|---|---|---|
| `code-review-deep` skill + `code-review-{history,premise,scorer,unit}-reviewer` + `quality-reviewer` | 1 skill, 5 agents | none — generic code review |
| `team` skill + `team-worker` agent | 1 skill, 1 agent | none — orchestration / model routing |
| `think` skill + `persona_think` / `persona_stats` / `persona_dismiss` | 1 skill, 3 MCP tools | none — persona advisory |

**3 of 19 skills, 6 of 10 agents, 3 of 23 MCP tools serve none of the four classes.**

**Executed 2026-08-20 (0.44.0).** The code-review and team rows are DELETED: `skills/code-review-deep`,
`skills/team`, the 4 `code-review-*` agents, `team-worker`, `quality-reviewer`, `scripts/team-run.sh`,
and 6 tests — ~2,400 lines. Budget ratcheted 19→17 skills, 10→4 agents, 54→53 scripts, 164→158 tests.
Rewiring: `subagent-capture.sh` SELF_AGENTS pruned to the three consolidation/recall agents;
`stop-verify-gate.sh`'s critic offer and `skills/doubt` step 4 now use `persona_think`;
two dead grant-locks removed from `agent-grants.test.ts`; the `skills/team/PROTOCOL.md`
agreement block removed from `test-model-ladder.sh`.

Model routing is NOT team-specific and stays: `model-ladder.json` is consumed by `stop-extract.sh`,
`pre-compact.sh`, `maintain-llm-drain.sh`, `extraction-quality-gate.sh` and `lib.sh` — core class-4
plumbing. Only `protocol_names` (SCOUT/DO/THINK) is now dead data, kept as one JSON line rather than
rippling through 4 files; retire it in the Phase 4.3 flag audit.

The `think` + `persona_*` row is DEFERRED, not rejected: `persona-context.sh` is the
UserPromptSubmit injection hook — the delivery path itself — so unbundling the advisory layer from
it is its own change.

**Dead schema.** `wiki/security`, `wiki/sources`, `wiki/state`: 0 pages each since creation
(finding 7). Categories that never attracted content are not classes anyone is writing to.

**Correction to the kill/keep ledger above.** That ledger lists `doubt` and `improve` alongside
`team` and `code-review-deep` as "real tools, wrong repo". The four-class rule does not agree:
`improve` proposes pin candidates from the current session (classes 1 and 4) and `doubt`
adversarially validates the plugin's own layers. Likewise `audit`, `lint`, `review`, `status`,
`track`, `import-host` all operate on the wiki, hot tier, or guards — they are memory-system
surfaces, not general engineering tools. Re-decide those against the scope rule rather than the
original ledger.

## Phases

Each phase ships independently and is gated on the value-loop number, not on completion.

### Phase 0 — Stop the bleeding, widen the measurement (no deletions)

- [x] **0.1 Fix the injection gate (THE root cause).** DONE. Gate moved off `score` entirely and
      onto `grounded` — the count of DISCRIMINATIVE query terms appearing in
      title/description/tags. `relevance` (frozen BM25) and `query_terms` are exposed alongside
      it; both CLIs (`knowledge-search-cli`, and `context-serve-cli`, which is the one the hook
      actually calls) gate on it; `SB_PERSONA_WIKI_MIN_SCORE` now defaults to 0.
      Result on the live 372-page wiki, shipped defaults, hybrid mode: **7/7 genuine queries
      inject their correct page, 0/7 nonsense inject anything** (was 0/7 and 0/7).

      Two intermediate designs were measured and rejected, both worth recording:
      - *Absolute BM25 floor (35).* Separated cleanly on the live wiki (28.5 vs 48.6) but is
        corpus-size dependent — on a small wiki df→N drives IDF→0 and all scores collapse, so
        the floor becomes unreachable. That is the SAME bug class being fixed. It surfaced as a
        real test failure (`test-injection-wrap`, a 1-page fixture), not as a hypothetical.
        `SB_INJECT_MIN_RELEVANCE` keeps the knob but defaults to 0.
      - *Raw term overlap (no df filter).* Leaked 3/6 nonsense queries, because `tokenize` has
        no stopword list and "best"/"way"/"today" ground just as well as "pagerank".
      `SB_GROUNDING_DF_SHARE` (default 0.5) is a corpus SHARE, not a count, so it is size
      invariant. Swept: 0.15→4/6 genuine, 0.25→5/6, **0.4–0.7→6/6 genuine + 0/6 nonsense**,
      1.0→3/6 nonsense leak. 0.5 sits mid-plateau.

      Lock: `retrieval-guards.test.ts` "injection gate satisfiability" — pure arithmetic plus a
      source scan of `persona-context.sh`, asserting no shipped default gates `score` above the
      RRF ceiling. Verified to go RED on the old value
      (`expected 0.045 to be less than 0.042622950819672135`). It needs no model, so it runs in
      CI's offline/degraded lane, and no env override can neuter it — unlike the behavioural
      tests, which pinned the gate open and hid this for the feature's entire lifetime.
- [ ] 0.2 Instrument per-prompt injection: `persona-context.sh` writes to the same session
      manifest (`sb_manifest_add` equivalent), so the denominator is complete. Today only
      SessionStart injections are measured.
- [ ] 0.3 Record *miss reasons* per injected item (below gate / injected-not-fetched /
      fetched-unused), so the zero always has a cause attached.
- [x] **0.4 Cross-project retrieval.** DONE — approved as a deliberate specification change.
      A tier-5 (other-project) page is now RESERVED a slot, ranked first, when it outscores
      EVERY in-scope candidate; otherwise the drop is unchanged. Knob `SB_SCOPE_CROSS_SLOTS`
      (default 1, `0` restores the old hard drop).

      Why "outscores everything in scope" rather than a margin or an unconditional slot: it is
      the condition that leaves the existing scoping contract intact. The two suppression tests
      (`C1 local-docs…`, `SP-1 family…`) use fixtures whose other-project page scores EQUAL to
      the in-scope pages, so a strict `>` leaves them dropped and both keep passing unmodified.
      A multiplicative margin was rejected outright — it is a threshold on a mode-dependent
      scale, the exact bug class that killed the injection gate. (The measured gap was 1.13×,
      so a margin rule tuned on that single case would also have been fitted to n=1.)

      Reserved candidates are placed FIRST, not appended: consumers read the top 1–2 candidates
      (`persona-context` injects 2), so a slot at the tail is the same as no slot. Ranking first
      is score-consistent by construction. Precision is still enforced downstream — the
      injection CLIs apply the grounding gate to every candidate, reserved or not.

      Verified end-to-end through the real `persona-context.sh` hook, scoped to
      `claude-code-plugin`, hybrid embeddings, shipped defaults:
      `"how do I fix the ansible replace regexp double substitution on a single line file"`
      → `[[ansible-replace-multiline-dollar-anchor-double-substitution]]` **first** (was
      `[[yaml-frontmatter-windows-backslash]]`, a wrong in-project page). Four in-project
      prompts unchanged; two nonsense prompts still inject nothing.

      Lock: `knowledge-search.test.ts` "SP-1 cross-project reservation" — asserts BOTH
      directions (outscoring page kept and ranked first; tying page still dropped) plus the
      `SB_SCOPE_CROSS_SLOTS=0` off-switch. Verified RED with the feature disabled:
      `expected [ 'a1', 'a2', 'a3' ] to include 'b-strong'`.
- [ ] 0.5 Filter `<task-notification>` / hook-context / system-reminder blocks before episodic
      indexing; re-index. Assert noise share < 5%.
- [ ] 0.6 Unblock capture: starvation escape must fire under pure OAuth; replace the fixed
      100-file cap with an extraction-state-aware cap that cannot evict un-mined transcripts.
- [ ] 0.7 Purge the 8 junk rows from `projects.jsonl`; add a registration guard for scratch/temp
      roots.
- [x] **0.8 Make the wiki hint executable (0.45.0).** DONE — the delivery half of `read=0`.

      0.1 fixed INJECTION and the rate stayed at exactly zero, which narrows the cause to
      CONSUMPTION. Measured over all 14 `gate=value-loop` rows, 2026-08-11 → 08-20:
      `injected=83, read=0, prior=0, hits=none` — including the three sessions AFTER 0.1
      shipped. So the gate was never the whole story.

      Root cause: the block handed the model a bare `[[slug]]` under the instruction
      "Read in full if relevant". `Read` requires an absolute path, so that instruction is
      literally unexecutable and the only recovery is grep — the behaviour this plugin exists
      to prevent. `knowledge_fetch` accepts exactly a slug, but it was invisible: absent from
      the MCP `instructions` blurb (`mcp/src/server.ts`), from all 17 skills, and from every
      injected line. `stop-extract.sh`'s telemetry counts a hit only on `knowledge_fetch(slug)`
      or a `Read` of `/slug.md`, so both facts predict exactly the observed 0.

      The hint now names `knowledge_fetch(slug)` with a gist-first policy and states that these
      are slugs, not paths. Shape copied from `session-load.sh`'s code-map block — the one
      injected surface with a non-zero read rate: content + tool name + when to call it.
      Cost: +40 bytes (~10 tokens) per turn on prompts that produce wiki hits.

      Lock: `tests/test-injection-wrap.sh` — asserts the emitted block names `knowledge_fetch`
      AND does not instruct an unexecutable `Read` of a slug. Verified RED on the old wording
      (2 failures).

      **This is a hypothesis under test, not a completed fix.** It is cheap and reversible; the
      measurement decides. If `read` is still 0 after ~5 sessions, the cause is NOT the wording
      and the next suspects are 0.2/0.3 (the denominator is incomplete, and misses have no
      recorded reason) — do those before touching ranking again.

**Exit criterion:** a `gate=value-loop` row with `read>0`, sustained over 5 sessions.
If Phase 0 cannot produce a non-zero read rate, no later phase is worth building.

> Status 2026-08-21: still UNMET (83 injected / 0 read over 14 sessions). 0.1 and 0.8 have both
> shipped against it; 0.2, 0.3, 0.5, 0.6, 0.7 remain open. Re-read this line before concluding
> that a later phase is ready to start.

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

## Why 918 green tests missed all of this

The suite is not too big. It disables the thing under test.

- The two tests covering per-prompt injection pin the gate open —
  `tests/test-injection-wrap.sh:34` sets `SB_PERSONA_WIKI_MIN_SCORE=0`,
  `tests/test-persona-context-combined.sh:50` sets `KNOWLEDGE_MIN_SCORE=0` — i.e. they set the
  exact constant whose production value is the bug to a value that cannot fail. The comment at
  :31-33 even names the open P0 it is stepping around.
- `.github/workflows/ci.yml:42` sets `SECOND_BRAIN_DISABLE_EMBEDDINGS: '1'`, so the hybrid RRF
  path — the only mode where the ceiling exists — never executes in CI at all.
- **71 of 163 shell tests (44%) pin at least one `SB_*` override.** `SB_INTERACTIVE_OVERRIDE`
  (12 uses) forces the drainer's defer verdict, which is why finding 5 also survived.

Every bug in the inventory above lives in the gap between the test configuration and the
production configuration. So the corrective action is NOT fewer tests — deleting them drops the
12 documented regression locks (architecture-contract §7) while leaving the blind spot intact.
It is:

1. **A production-config lane** — the existing suite re-run with no overrides and embeddings on.
   Blocker: CI is offline and cannot fetch the ~490 MB ONNX model, so this needs either a cached
   model artifact or a self-hosted/local-only lane. Until then it runs pre-release on a
   developer machine.
2. **Prefer arithmetic/source-scan locks over behavioural fixtures** where the invariant allows
   it. 0.1's lock needs no model, no fixture, and no env — so nothing can pin it open.
3. **Outcome checks against the real corpus**, not synthetic pages: "this query injects that
   page", "nonsense injects nothing". Ten of those outrank a hundred fixture tests.
4. **Make the measurement fail loudly.** `read=0` held for 13 sessions and notified no one; a
   sustained-zero read rate must raise a banner the way drainer staleness already does.

## Non-goals

- Porting the wiki to a new schema or store. `~/knowledge` is not touched by any phase.
- Rebuilding `knowledge_search`'s BM25/RRF/ONNX core. It works; only its *triggering and scoping*
  change.
- Preserving `auto_accept`, `brain_os`, or the dream lifecycle in any form.

## Known gap opened by 0.1: no stemming

`tokenize` produces raw lowercase alphanumeric runs with no stemmer, so grounding cannot match
"remove a **page**" against a title reading "archive**s** ... **pages**". Measured cost on the
12-query eval fixture: 10/12 on-topic queries inject; the 2 misses are both plural/tense
mismatches, not relevance failures.

Deliberately NOT fixed by weakening the gate — that would re-admit the nonsense injections the
df-share filter removes. Fix it at the tokenizer (light stemming, or grounding on token prefixes)
where it also improves BM25, and re-measure both `test-injection-gate.sh` ratios afterwards.

## 0.1 postscript: two more "unsatisfiable gate" edges, found by tests

The same bug class reappeared twice *inside the fix*, which is the strongest argument that the
class — not the constant — is the thing to guard:

1. **Absolute BM25 floor (35).** Clean on 372 pages, unreachable on a 1-page corpus
   (df→N ⇒ IDF→0). Caught by `test-injection-wrap`. Resolution: default 0, knob retained.
2. **df-share filter with no fallback.** On a 4-page corpus where every page contains the query
   terms, df = N for all of them, every term is "common", grounding zeroes out and nothing can
   inject. Caught by `test-search-cli-scope` / `test-pipeline-smoke`. Resolution:
   `discriminativeTerms()` falls back to raw overlap when NO term discriminates — safe, because
   the nonsense-injection hole requires a common term to ground on *while* rare terms exist, so
   the fallback cannot trigger in that case.

Also narrowed deliberately: grounding reads title/description/tags and never the body, so a page
whose head fields do not mention the topic will not inject even if its body does. `description`
is a required frontmatter field, so real pages are unaffected; two fixtures that omitted it were
building schema-invalid pages and were corrected rather than the gate loosened.
Follow-up worth measuring: whether the ai-block (BM25 field 3, the proposition-level summary)
should also count as a head field — it is aboutness-bearing and would help pages with thin
descriptions, but it needs the same genuine-vs-nonsense sweep before it ships.
