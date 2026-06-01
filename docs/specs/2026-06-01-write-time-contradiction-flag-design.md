# Design: deterministic write-time contradiction flag

**Date:** 2026-06-01
**Status:** Implemented in 0.22.2 (PR #7, branch `feat/graphiti-adoption-specs`) — brainstorm output (Graphiti eval `wf_ac6b4c11-117`), **revised after adversarial review** (`wf_51f2dbeb-ae1`)
**Author:** second-brain session
**Target release:** plugin 0.22.2 (scripts + knowledge-maintainer + session-load). **No MCP server change.**

> **Revision note (post-review):** the original draft routed conflict adjudication through the *dream*. That is wrong — `agents/dream-runner.md` Phase 3 states the dream does **not** curate edges and `graph/edges.jsonl` is intentionally **not** snapshotted into staging. Edge curation is owned by the **live paths** (`knowledge_relate`, the `knowledge-maintainer` agent). This revision moves the drain to the **maintainer** (live), adds a status-fold rule for the append-only sidecar, fixes a within-batch miss, normalizes timestamp granularity, gives the session-load surfacing a high-priority slot, and reframes the R1 motivation honestly.

## Summary

The relational graph (`~/knowledge/graph/edges.jsonl`) is **invalidated only by a live, healthy path** — `knowledge_relate(invalidate)` or the `knowledge-maintainer` RELATE phase. So when the LLM/MCP layer is degraded (this user's recurring `[degraded]` windows), a *structurally contradictory* edge can be appended by the pure-bash write path and go **completely unnoticed** until the next healthy maintainer run.

This design adds a **deterministic, pure-bash collision detector** to the existing write path (`merge-edges.sh`). When a proposed edge structurally collides with current-valid graph state, the edge is **still appended** (we never block the deterministic write), and a one-line record is also written to a new **`~/knowledge/graph/conflicts.jsonl`** sidecar. The **`knowledge-maintainer` Phase 3 (RELATE)** — which already curates edges on the live wiki via `knowledge_relate` — drains that queue and adjudicates (supersede / invalidate / dismiss). `session-load.sh` surfaces an open-conflict count in a **high-priority banner slot** so the user sees pending contradictions even before a maintainer run.

The detector runs with **no LLM, no node/MCP, no network** — preserving `merge-edges.sh`'s reason to be pure bash. Adjudication stays human/maintainer-judged; we only remove the *silent-staleness window* by flagging structurally at write time.

## Goals

- **Detect at write time**, deterministically, in pure bash + `jq` (no LLM, no node), so it works in the degraded windows that motivate it.
- **Never block, never auto-invalidate.** The proposed edge is appended as today; the conflict is *queued*. Adjudication stays on the live path (honours "the write path only proposes; invalidation is reviewed").
- **Low false-positive rate.** Flag only *genuinely* contradictory shapes; never flag legitimately multi-valued fan-out (`A requires B` *and* `A requires C` is normal).
- **Correctly consumable.** `knowledge-maintainer` Phase 3 drains the queue (it is the live edge curator); `session-load` shows a folded open-count; `lint`/`status` can report it.
- **Strict back-compat.** No `graph/` dir ⇒ no-op. No `conflicts.jsonl` ⇒ behaviour byte-for-byte as 0.22.x. Adds only O(edges) work per session at single-user scale (the real log is ~460 edges today).

## Non-goals (YAGNI)

- **No automatic invalidation/supersession.** That stays the maintainer's / user's call via `knowledge_relate`. This feature only *surfaces* the collision.
- **No semantic contradiction detection** ("vegetarian" vs "eats meat" across page *prose*). That needs an LLM and belongs to the maintainer's retrieval-grounded reconcile (`2026-06-01-dream-consolidation-v2-design.md` §B2). This is purely **structural** edge-collision detection.
- **No drain inside the dream.** The dream cannot touch `edges.jsonl` (not snapshotted). The dream may *read* `conflicts.jsonl` read-only and echo the count into its report, nothing more.
- **No new MCP tool, no node/TS surface, no new dependency, no `edges.jsonl` schema change.** Conflicts live in a separate sidecar.

## Background — what exists today (must keep working)

| Component | File | Current behaviour |
|---|---|---|
| Write path | `scripts/merge-edges.sh` | Appends each proposed `relations[]` edge as `op:assert` (lines 60/63 — **only** asserts; never invalidates); endpoint-guard → `edges.jsonl` or `edges-quarantine.jsonl`. **No collision awareness.** |
| Fold-to-current | `mcp/src/tools/graph-store.ts` `foldToCurrent`/`validAt` | Folds the log to current-valid state — **node-only**; the bash write path can't call it (re-implemented minimally in `jq`). |
| **Live edge curator** | `agents/knowledge-maintainer.md` **Phase 3 RELATE** | Runs against the **live** wiki; asserts/invalidates/supersedes via `knowledge_relate`; reindexes. **This is where the drain belongs.** |
| Dream | `agents/dream-runner.md` Phase 3 | Staging-only; **does NOT curate edges**; `graph/` not snapshotted; surfaces suggested `knowledge_relate` calls in its report. |
| Session load | `scripts/session-load.sh` | `sb_append(content,label,maxBytes)` skips an item silently if it would exceed `BYTE_BUDGET=8000`. Early **banner slots** (extractor-health 800, episodic 800, auth) emit *before* the uncapped USER.md/PROJECT.md draw down the budget. |

Hard constraint: the detector **must not** depend on `graph-store.ts` (node may be down — the whole point of the pure-bash write path). It re-implements the minimal "latest record per identity" fold in `jq`, over a small single-user log.

## Architecture

```
   merge-edges.sh (pure bash) — per Stop-hook delta
   ┌──────────────────────────────────────────────────────────┐
   │ 0. SNAPSHOT once: LATEST = fold(edges.jsonl) PRE-batch     │
   │ for each proposed edge (F,T,O):                            │
   │   1. detect_conflict(F,T,O) against the RUNNING snapshot   │
   │        → if hit and not already-open: append to conflicts  │
   │   2. append (F,T,O) op:assert to edges.jsonl  (UNCHANGED)  │
   │   3. fold the just-appended edge INTO the running snapshot │
   │        (so the next edge in THIS delta sees it)            │
   └──────────────────────────────────────────────────────────┘
                 │ folded open conflicts
                 ▼
   knowledge-maintainer Phase 3  ──adjudicate──▶ knowledge_relate(supersede/invalidate)  [LIVE]
   session-load.sh (high-prio slot) ──surface──▶ "⚠ N graph conflict(s) pending"
   dream-runner report (read-only)  ──echo─────▶ "N open graph conflicts (resolve via maintainer)"
```

**Detection happens *before* the append, against the pre-batch snapshot** (step 1 before step 2). This is essential for R1: if we detected after appending, the just-added assert would re-open the identity and R1 could never fire. Step 3 keeps a *running* snapshot so a within-delta collision (two proposed edges that conflict with each other) is still caught.

## 1. Data model — `conflicts.jsonl` (append-only sidecar, status-folded)

`~/knowledge/graph/conflicts.jsonl`, one JSON object per line:

```jsonc
{"detected_at":"2026-06-01T10:22:05Z",
 "from":"wg-tunnel","type":"requires","to":"vps-ufw-depinned","kind":"reintroduce",
 "against":{"from":"wg-tunnel","type":"requires","to":"vps-ufw-depinned","valid_to":"2026-05-29"},
 "source":"merge-edges","status":"open"}
```

| Field | Meaning |
|---|---|
| `detected_at` | ISO-8601 Z when flagged |
| `from`/`type`/`to` | the **proposed** edge that triggered the flag |
| `kind` | `reintroduce` \| `opposing` \| `multi_parent` (see §2) |
| `against` | the live edge it collides with (identity + its `valid_to`) |
| `source` | `merge-edges` (write path) |
| `status` | `open` \| `resolved` \| `dismissed` |

**Identity** of a conflict = `(from, type, to, kind)`. **Status is folded, not overwritten** (the file is append-only, mirroring `edges.jsonl`): the **current status of an identity is the status of its last-appended line**. The maintainer marks a conflict resolved/dismissed by *appending* a new line with the same identity + new status (and a `resolved_by` note). Consumers (session-load count, maintainer drain, idempotency guard) **must fold-then-read**:

```bash
# open conflicts = identities whose LAST line is status:open
jq -nR 'reduce (inputs|fromjson?) as $r ({}; .[($r|[.from,.type,.to,.kind]|tojson)]=$r)
        | [.[]] | map(select(.status=="open"))' conflicts.jsonl
```

A re-detection of an already-`open` identity is a **no-op** (the fold shows it open → skip the append).

## 2. Detection rules (deterministic, tuned for near-zero false positives)

For each proposed edge `(F,T,O)`, against the **running** pre-batch snapshot `LATEST` (latest record per `(from,type,to)`):

- **R1 `reintroduce` (default ON).** Identity `(F,T,O)` exists in `LATEST` and its latest record is an `invalidate` **or** has a non-null `valid_to`. → the proposed assert *re-introduces a retired edge*. **Flag.**
  *Honest scope:* `merge-edges.sh` itself only ever writes `op:assert` — it **cannot** produce the `invalidate` record R1 keys on. So R1 fires on the **healthy-retire → later-reassert** boundary: an edge invalidated by `knowledge_relate`/maintainer (a healthy moment) and then re-asserted by a later extractor delta. A retire-then-reassert that happens *entirely within* one degraded window produces two asserts and R1 will **not** catch it (documented limitation, not a silent bug). This is still the headline value: it catches the `pi-ip-ufw-sync`-class "we retired this, why is it back?" churn across the common case.

- **R2 `opposing` (default ON).** A directionally-opposing live edge exists, restricted to unambiguous types:
  - circular `supersedes`: `LATEST` has live `(O, supersedes, F)` and the proposal is `(F, supersedes, O)`;
  - supersede-vs-dependency: `LATEST` has live `(F, supersedes, O)` and the proposal is `(F, requires, O)` (or vice-versa) — you don't *require* what you've *replaced*. **Flag.**

- **R3 `multi_parent` (default OFF, `SB_CONFLICT_MULTIPARENT=on`).** Proposal `(F, part_of, O)` while a live `(F, part_of, O2)`, `O2≠O` exists. Off by default (legitimate multi-parent composition exists).

**Explicitly NOT flagged** (cry-wolf guardrails): multiple live `requires`/`affects`/`relates` from the same `from` to *different* targets (normal fan-out); a plain re-assert of an already-live identity (idempotent — handled by the fold, no contradiction); any edge whose endpoint didn't resolve (already quarantined upstream).

### Within-batch correctness (running snapshot)

Because `LATEST` is updated after each append (architecture step 3), a single delta proposing **both** `(A,supersedes,B)` and `(A,requires,B)` (an R2 pair across *distinct* identities) is caught: the first append folds `(A,supersedes,B)` into the running snapshot, so the second edge sees it and R2 fires. Without the running update, neither would be in the pre-batch snapshot, **neither would flag, and — because there is no new proposal next session — the conflict would be permanently lost, not merely deferred.** The running snapshot closes that hole.

### Timestamp-granularity note

`merge-edges.sh` stamps `recorded_at` at **second** granularity (`date -u +%Y-%m-%dT%H:%M:%SZ`); `knowledge_relate` (the source of the `invalidate` records R1 keys on) stamps **millisecond** ISO (`new Date().toISOString()`). A naive `max_by(.recorded_at)` string-sort places a same-second ms-stamped invalidate (`…05.123Z`) *before* a second-stamped assert (`…05Z`) because `'.'(0x2E) < 'Z'(0x5A)`. The fold therefore **normalizes to second granularity** before `max_by` (`.recorded_at[:19]`), with line order as the deterministic tiebreak within a second. (Same-second assert+invalidate is rare; the normalization makes it order-stable rather than string-accidental.)

## 3. Implementation — `merge-edges.sh` delta

```bash
CONFLICTS="$GRAPH_DIR/conflicts.jsonl"
# pre-batch snapshot (normalized to second granularity); kept in a temp, updated per append
SNAP=$(mktemp); trap 'rm -f "$SNAP"' EXIT
[ -s "$LOG" ] && jq -s '[ to_entries[] | .value + {recorded_at:(.value.recorded_at|.[0:19]), _i:.key} ]
  | group_by([.from,.type,.to]) | map(max_by([.recorded_at, ._i]))' "$LOG" > "$SNAP" || echo '[]' > "$SNAP"

detect_conflict() {            # args: F T O ; on hit prints "<kind>\t<against-json>" and returns 0
  local F="$1" T="$2" O="$3" against opp
  # R1 reintroduce: latest record for identity (F,T,O) is closed (op:invalidate or valid_to set)
  against=$(jq -c --arg f "$F" --arg t "$T" --arg o "$O" \
    '(map(select(.from==$f and .type==$t and .to==$o)) | .[0])
     | select(. != null and (.op=="invalidate" or (.valid_to != null)))
     | {from,type,to,valid_to}' "$SNAP" 2>/dev/null)
  [ -n "$against" ] && { printf 'reintroduce\t%s\n' "$against"; return 0; }
  # R2 opposing (supersedes-anchored, low-FP): circular supersede, or supersede<->requires on the pair.
  # "live" = latest record has valid_to==null (merge-edges only writes asserts; an invalidate sets valid_to).
  if [ "$T" = supersedes ]; then                         # proposing (F supersedes O): is (O supersedes F) live?
    against=$(jq -c --arg f "$F" --arg o "$O" \
      '(map(select(.from==$o and .type=="supersedes" and .to==$f and .valid_to==null)) | .[0] // empty)
       | {from,type,to,valid_to}' "$SNAP" 2>/dev/null)
  fi
  if [ -z "$against" ] && { [ "$T" = requires ] || [ "$T" = supersedes ]; }; then
    [ "$T" = requires ] && opp=supersedes || opp=requires      # is the opposing type live on the same pair?
    against=$(jq -c --arg f "$F" --arg o "$O" --arg op "$opp" \
      '(map(select(.from==$f and .type==$op and .to==$o and .valid_to==null)) | .[0] // empty)
       | {from,type,to,valid_to}' "$SNAP" 2>/dev/null)
  fi
  [ -n "$against" ] && { printf 'opposing\t%s\n' "$against"; return 0; }
  # R3 multi_parent (opt-in): proposing (F part_of O) while (F part_of O2≠O) is live
  if [ "${SB_CONFLICT_MULTIPARENT:-off}" = on ] && [ "$T" = part_of ]; then
    against=$(jq -c --arg f "$F" --arg o "$O" \
      '(map(select(.from==$f and .type=="part_of" and .to!=$o and .valid_to==null)) | .[0] // empty)
       | {from,type,to,valid_to}' "$SNAP" 2>/dev/null)
    [ -n "$against" ] && { printf 'multi_parent\t%s\n' "$against"; return 0; }
  fi
  return 1
}
already_open() {               # F T O kind — fold conflicts.jsonl, true if last line is open
  [ -s "$CONFLICTS" ] && jq -e --arg f "$1" --arg t "$2" --arg o "$3" --arg k "$4" \
    -nR 'reduce (inputs|fromjson?) as $r ({}; .[($r|[.from,.type,.to,.kind]|tojson)]=$r) | [.[]]
        | any(.from==$f and .type==$t and .to==$o and .kind==$k and .status=="open")' "$CONFLICTS" >/dev/null 2>&1
}
```

Inside the existing `relations[]` loop, **before** the `>> "$LOG"` append: if `[ "${SB_CONFLICT_DETECT:-on}" != off ]` and `detect_conflict F T O` hits and `! already_open …`, append the conflict line. **After** the append, fold the new edge into `$SNAP` (a one-line `jq` update). All bash + `jq`; no node, no LLM, no network.

## 4. Consumption (read side)

- **`knowledge-maintainer` Phase 3 RELATE** (edit `agents/knowledge-maintainer.md`): at the start of RELATE, fold `conflicts.jsonl` and read `status:open` identities. For each, the maintainer **judges** (supersede / the old was wrong → invalidate / false alarm → dismiss) and performs the deterministic write via `knowledge_relate` (it already does exactly this for edge curation), then **appends** a status line (`resolved`/`dismissed`) to `conflicts.jsonl`. Bounded by the maintainer's existing 50-change cap. This is a *live-path* write — correct, because the maintainer runs against the live wiki (not staging). **Phase-3 budget priority** (Phase 3 now carries three jobs under one 50-change cap — routine relate, B2 SUPERSEDE, and this drain): adjudicate open conflicts **first** (they surface an existing contradiction), then B2 SUPERSEDE, then routine relate; overflow defers to the next run per the existing cap contract — so a large SUPERSEDE can't starve the correctness-surfacing drain.
- **`session-load.sh`**: fold + count `status:open`; if >0, emit a one-line warning in a **high-priority early slot** (alongside the extractor-health banner, label `graph-conflicts-banner`, cap ~250B) — **before** USER.md/PROJECT.md draw down the budget — so the correctness signal can't be the item that gets silently dropped. Zero open ⇒ no line (byte-for-byte unchanged).
- **`dream-runner` report (read-only)**: the dream may fold + echo the open count into its summary ("N open graph conflicts — resolve via the maintainer"), but writes nothing to `graph/`.
- **`skills/lint` / `status`** (optional follow-up): report folded open-conflict count.

## 5. Error handling / safety

| Failure | Behaviour |
|---|---|
| No `graph/` dir or empty `edges.jsonl` | `SNAP='[]'`; detector never fires; full no-op. |
| `jq` fold fails / malformed log | Detector returns no conflict (fail-open: never breaks the append, never crashes the Stop hook — precedent: the `verify.sh` empty-file fix). |
| Duplicate detection of an open conflict | Idempotent via the status-fold `already_open` guard. |
| `conflicts.jsonl` torn line | Consumers `jq -s` line-parse; a torn final line is skipped (same contract as `edges.jsonl`). |
| `SB_CONFLICT_DETECT=off` | Detector disabled entirely; kill switch. |
| Same-second assert/invalidate | Normalized to second granularity + line-order tiebreak; order-stable. |

## 6. Configuration (env, conservative)

| Var | Default | Meaning |
|-----|---------|---------|
| `SB_CONFLICT_DETECT` | `on` | master kill switch |
| `SB_CONFLICT_MULTIPARENT` | `off` | enable R3 (`part_of` single-parent) |

## 7. Testing strategy (per the validate-the-real-capability learning)

Tests prove the **real capability** (a structural contradiction is flagged; a legit fan-out is NOT), not field presence. Shell tests in `tests/test-*.sh`, gated by the deep-review release gate.

1. **R1 reintroduce (across the healthy/degraded boundary)**: assert `(a,requires,b)` via `merge-edges`; record an `invalidate` for it *as `knowledge_relate` would* (ms-stamped, op:invalidate); then a fresh `merge-edges` delta re-asserts `(a,requires,b)` → exactly one folded `open` `reintroduce` conflict; the edge is **also** appended to `edges.jsonl`.
2. **R2 opposing**: live `(a,supersedes,b)`, propose `(b,supersedes,a)` → one `opposing` conflict.
3. **No cry-wolf**: live `(a,requires,b)`, propose `(a,requires,c)` → **zero** conflicts.
4. **Within-batch pair**: a single delta with both `(a,supersedes,b)` and `(a,requires,b)` → R2 fires (running-snapshot test — proves the permanent-loss hole is closed).
5. **Idempotent**: same conflicting delta twice → still one folded `open` line.
6. **Status fold**: append `open` then `resolved` for one identity → folded open-count = 0.
7. **Append-still-happens**: every conflicting case asserts the new edge is present in `edges.jsonl`.
8. **No-graph no-op**: no `edges.jsonl` → no `conflicts.jsonl` created.
9. **Fail-open**: corrupt `edges.jsonl` last line → `merge-edges.sh` exits 0, edge appended, no crash.
10. **Kill switch**: `SB_CONFLICT_DETECT=off` → no `conflicts.jsonl` writes.
11. **Granularity**: same-second ms-invalidate vs second-assert folds to the invalidate as latest (R1 fires), proving the `[:19]` normalization.
12. **Session-load surfacing under pressure**: fixture with USER.md+PROJECT.md ≈ 6 KB **and** N open conflicts → the `graph-conflicts-banner` line is **present** (not dropped), and total output ≤ 8000 B. (Asserting presence under a near-full budget — not merely "under 8000" — is the test that catches silent-drop.)

## 8. File-change inventory

**New:**
- `tests/test-merge-edges-conflict.sh` (+ fixtures) — detector behaviour above.

**Modified:**
- `scripts/merge-edges.sh` — pre-batch `jq` snapshot (second-normalized) + running update + `detect_conflict` + status-fold idempotent append (guarded by `SB_CONFLICT_DETECT`).
- `agents/knowledge-maintainer.md` — Phase 3 RELATE drains the folded conflict queue (judge → `knowledge_relate` → append status line). **This is the live-path owner.**
- `agents/dream-runner.md` — Phase 3 note: may echo the open-conflict count read-only; still writes nothing to `graph/`.
- `scripts/session-load.sh` — high-priority `graph-conflicts-banner` slot (folded open-count), emitted in the early-banner region.
- `skills/upgrade/SKILL.md` — migration row for 0.23.0 (purely additive).

## 9. Rollout

1. Ship **dormant-safe**: no `edges.jsonl` ⇒ never fires.
2. Conflicts queue on the next colliding append.
3. The next `knowledge-maintainer` run drains the queue (live), or the user resolves via `knowledge_relate`.
4. Validate with the test suite + a deep-review pass before release (per the gate).
5. Tune R2/R3 against real `conflicts.jsonl` volume; the live edge log is ~460 edges (98% `relates`, 2 `supersedes`, 0 `requires`, 0 `invalidate`) today, so **R1/R2 will rarely fire until typed/temporal edges accrue** — this is insurance against future churn, not a fix for an evidenced live backlog. Frame it that way in the release notes.
