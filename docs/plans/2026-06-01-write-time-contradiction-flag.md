# Write-time contradiction flag — Implementation Plan

> **For agentic workers:** Implement task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`. Spec: `docs/specs/2026-06-01-write-time-contradiction-flag-design.md`.

**Goal:** A deterministic, pure-bash detector in `merge-edges.sh` flags structurally-contradictory edges to `~/knowledge/graph/conflicts.jsonl` at write time (offline, no LLM); the **live** `knowledge-maintainer` drains the queue; `session-load` surfaces the count in a high-priority slot.

**Architecture:** Detection runs **before** each append, against a **pre-batch snapshot** that is folded forward per appended edge (running snapshot). The append itself is unchanged. `conflicts.jsonl` is append-only and **status-folded** (current status = last line per identity). Adjudication is a live-path job (maintainer / `knowledge_relate`), never the dream.

**Tech stack:** Bash + `jq` (no node, no LLM on the write path); `tests/test-*.sh` harness (`set -u`, `fail()`/`pass()`, `mktemp -d`, `trap`), auto-discovered by `tests/run-all.sh`.

**Phases:**
- **A** — detector core in `merge-edges.sh` (+ `tests/test-merge-edges-conflict.sh`). The foundation.
- **B** — consumption: maintainer drain, `session-load` surfacing, dream-runner read-only echo.
- **C** — release: migration row, gate.

**Conventions (verified):**
- Shell tests `tests/test-<name>.sh`; run a single one with `bash tests/test-<name>.sh`; the suite via `bash tests/run-all.sh`.
- `merge-edges.sh` sources `scripts/lib.sh` and uses `sb_sanitize_slug`; it writes `op:assert` only (lines 60/63).
- Fail-open: a detector error must never break the append or non-zero the Stop hook (precedent: the `verify.sh` empty-file fix).
- Commit after each green task. End commit messages with the Co-Authored-By trailer.

---

## Phase A — Detector core (`merge-edges.sh`)

Everything else consumes this. Build it test-first; make it bulletproof and offline.

**Files:**
- Modify: `scripts/merge-edges.sh`
- Create: `tests/test-merge-edges-conflict.sh`

### Task A1: Test scaffold + kill-switch + no-op safety

- [ ] **Step 1: Write the failing test** — `tests/test-merge-edges-conflict.sh`:

```bash
#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/merge-edges.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
KDIR="$TMP/knowledge"; mkdir -p "$KDIR/wiki/entities"
mkpage(){ printf '%s\n' '---' "title: $1" 'type: entities' '---' "# $1" > "$KDIR/wiki/entities/$1.md"; }
mkpage page-a; mkpage page-b; mkpage page-c
LOG="$KDIR/graph/edges.jsonl"; CONF="$KDIR/graph/conflicts.jsonl"
run(){ echo "$1" | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"; }

# no edges.jsonl => detector is a clean no-op (no conflicts file created)
run '{"relations":[{"from":"page-a","to":"page-b","type":"requires"}]}'
[ -f "$CONF" ] && fail "conflicts.jsonl created with no prior graph" || pass "no-graph no-op"

# kill switch
: > "$LOG"   # ensure a graph exists for subsequent tests
echo '{"op":"assert","from":"page-a","to":"page-b","type":"requires","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z","source":"extractor"}' >> "$LOG"
SB_CONFLICT_DETECT=off run '{"relations":[{"from":"page-a","to":"page-b","type":"requires"}]}'
[ -f "$CONF" ] && fail "kill switch did not suppress detection" || pass "SB_CONFLICT_DETECT=off suppresses"
echo "ALL PASS (A1)"
```

- [ ] **Step 2:** `bash tests/test-merge-edges-conflict.sh` → expect FAIL (detector not wired; behaviour may differ).
- [ ] **Step 3: Minimal impl** — in `merge-edges.sh`, after the arg parse + path setup, add the conflicts path and the kill switch guard; declare the snapshot file but leave detection a no-op stub for now:

```bash
CONFLICTS="$GRAPH_DIR/conflicts.jsonl"
SNAP=$(mktemp); trap 'rm -f "$SNAP"' EXIT
detect_enabled(){ [ "${SB_CONFLICT_DETECT:-on}" != off ] && [ -s "$LOG" ]; }
```

- [ ] **Step 4:** rerun → PASS (no-op + kill switch).
- [ ] **Step 5: Commit** — `feat(graph): conflict-detector scaffold + kill switch in merge-edges.sh`.

### Task A2: Pre-batch snapshot fold (`jq`, second-normalized)

- [ ] **Step 1: failing test** — append to the test: assert that after a run, the running snapshot logic exists by checking a same-second invalidate folds as latest (proxy via R1 in A3); for now test the helper directly by sourcing is not possible — instead defer the assertion to A3 and write the fold now.
- [ ] **Step 3: impl** — build `$SNAP` before the `relations[]` loop (per spec §3):

```bash
if detect_enabled; then
  jq -s '[ to_entries[] | .value + {recorded_at:(.value.recorded_at|.[0:19]), _i:.key} ] | group_by([.from,.type,.to]) | map(max_by([.recorded_at, ._i]))' \
     "$LOG" > "$SNAP" 2>/dev/null || echo '[]' > "$SNAP"
else echo '[]' > "$SNAP"; fi
```

- [ ] **Step 5: Commit** — `feat(graph): pre-batch second-normalized edge snapshot`.

### Task A3: R1 `reintroduce` + status-fold append + idempotency

- [ ] **Step 1: failing test** — add (mirrors spec test #1, #5, #6, #11):

```bash
: > "$LOG"; rm -f "$CONF"
# healthy retire (as knowledge_relate would write it: ms-stamped op:invalidate)
echo '{"op":"assert","from":"page-a","to":"page-b","type":"requires","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z","source":"extractor"}' >> "$LOG"
echo '{"op":"invalidate","from":"page-a","to":"page-b","type":"requires","valid_to":"2026-06-01","recorded_at":"2026-06-01T10:00:00.123Z","source":"manual"}' >> "$LOG"
run '{"relations":[{"from":"page-a","to":"page-b","type":"requires"}]}'
[ -f "$CONF" ] || fail "R1 did not flag reintroduce"
folded(){ jq -nR 'reduce (inputs|fromjson?) as $r ({}; .[($r|[.from,.type,.to,.kind]|tojson)]=$r)|[.[]]|map(select(.status=="open"))' "$CONF"; }
[ "$(folded | jq 'length')" = 1 ] || fail "R1 open-count != 1"
grep -q '"kind":"reintroduce"' "$CONF" || fail "kind not reintroduce"
grep -q '"from":"page-a"' "$LOG" && [ "$(grep -c '"to":"page-b"' "$LOG")" -ge 2 ] || fail "edge not also appended"
pass "R1 reintroduce flagged + edge still appended (granularity: ms-invalidate folds latest)"
# idempotent: re-run, still ONE open
run '{"relations":[{"from":"page-a","to":"page-b","type":"requires"}]}'
[ "$(folded | jq 'length')" = 1 ] || fail "R1 not idempotent"
pass "R1 idempotent (status-fold guard)"
# resolve → open count 0
echo '{"detected_at":"2026-06-01T11:00:00Z","from":"page-a","type":"requires","to":"page-b","kind":"reintroduce","against":{},"source":"merge-edges","status":"resolved"}' >> "$CONF"
[ "$(folded | jq 'length')" = 0 ] || fail "status-fold did not respect resolved"
pass "status-fold (open→resolved = 0 open)"
```

- [ ] **Step 3: impl** — add `detect_conflict()` (R1 branch first), `already_open()`, and the per-edge detect→append→fold-forward, inside the existing loop *before* the `>> "$LOG"` append. Use the exact `detect_conflict` from spec §3 (R1 jq) and:

```bash
already_open(){ # F T O kind
  [ -s "$CONFLICTS" ] && jq -e --arg f "$1" --arg t "$2" --arg o "$3" --arg k "$4" \
    -nR 'reduce (inputs|fromjson?) as $r ({}; .[($r|[.from,.type,.to,.kind]|tojson)]=$r)|[.[]]|any(.from==$f and .type==$t and .to==$o and .kind==$k and .status=="open")' \
    "$CONFLICTS" >/dev/null 2>&1; }
# inside the loop, before append:
if detect_enabled; then
  if hit=$(detect_conflict "$sfrom" "$type" "$sto"); then
    kind="${hit%%$'\t'*}"; against="${hit#*$'\t'}"
    if ! already_open "$sfrom" "$type" "$sto" "$kind"; then
      jq -nc --arg f "$sfrom" --arg t "$type" --arg o "$sto" --arg k "$kind" \
        --arg now "$NOW" --argjson ag "$against" \
        '{detected_at:$now,from:$f,type:$t,to:$o,kind:$k,against:$ag,source:"merge-edges",status:"open"}' \
        >> "$CONFLICTS"
    fi
  fi
fi
# ... existing append to $LOG ...
# fold the just-appended edge forward into $SNAP (running snapshot):
if detect_enabled; then
  jq -s --argjson new "$rec" '. as $s | ($new|.recorded_at|=.[0:19]) as $n
    | ($s | map(select([.from,.type,.to]!=[$n.from,$n.type,$n.to]))) + [$n]' "$SNAP" > "$SNAP.tmp" && mv "$SNAP.tmp" "$SNAP"
fi
```

- [ ] **Step 4:** rerun → PASS (R1 + idempotency + fold + granularity).
- [ ] **Step 5: Commit** — `feat(graph): R1 reintroduce detection + status-fold conflicts.jsonl`.

### Task A4: R2 `opposing` + within-batch running snapshot + no-cry-wolf

- [ ] **Step 1: failing test** (spec tests #2, #3, #4):

```bash
: > "$LOG"; rm -f "$CONF"
echo '{"op":"assert","from":"page-a","to":"page-b","type":"supersedes","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z","source":"extractor"}' >> "$LOG"
run '{"relations":[{"from":"page-b","to":"page-a","type":"supersedes"}]}'      # circular
grep -q '"kind":"opposing"' "$CONF" || fail "R2 circular supersede not flagged"; pass "R2 opposing"
# no cry wolf: fan-out
: > "$LOG"; rm -f "$CONF"
echo '{"op":"assert","from":"page-a","to":"page-b","type":"requires","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z","source":"extractor"}' >> "$LOG"
run '{"relations":[{"from":"page-a","to":"page-c","type":"requires"}]}'
[ -f "$CONF" ] && fail "fan-out wrongly flagged" || pass "no cry-wolf on requires fan-out"
# within-batch pair: one delta with (a supersedes b) AND (a requires b)
: > "$LOG"; rm -f "$CONF"
run '{"relations":[{"from":"page-a","to":"page-b","type":"supersedes"},{"from":"page-a","to":"page-b","type":"requires"}]}'
grep -q '"kind":"opposing"' "$CONF" || fail "within-batch opposing pair NOT caught (running snapshot broken)"
pass "within-batch opposing pair caught (running snapshot)"
```

- [ ] **Step 3: impl** — add the R2 branch to `detect_conflict` (spec §3 R2 jq). The running-snapshot fold from A3 makes the within-batch test pass with no extra code.
- [ ] **Step 4:** rerun → PASS.
- [ ] **Step 5: Commit** — `feat(graph): R2 opposing detection + within-batch running snapshot`.

### Task A5: Fail-open + append-always + R3 opt-in

- [ ] **Step 1: failing test** (spec #7, #9, and R3):

```bash
# fail-open: corrupt last log line
: > "$LOG"; rm -f "$CONF"
echo '{"op":"assert","from":"page-a","to":"page-b","type":"requires","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z"}' >> "$LOG"
printf '%s' '{"op":"assert","from":"page-a","to":"pag' >> "$LOG"   # torn
run '{"relations":[{"from":"page-a","to":"page-c","type":"relates"}]}'; rc=$?
[ "$rc" -eq 0 ] || fail "merge-edges did not exit 0 on corrupt log"; pass "fail-open exit 0"
# R3 opt-in
: > "$LOG"; rm -f "$CONF"
echo '{"op":"assert","from":"page-a","to":"page-b","type":"part_of","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z"}' >> "$LOG"
SB_CONFLICT_MULTIPARENT=on run '{"relations":[{"from":"page-a","to":"page-c","type":"part_of"}]}'
grep -q '"kind":"multi_parent"' "$CONF" || fail "R3 not flagged when enabled"; pass "R3 multi_parent (opt-in)"
: > "$LOG"; rm -f "$CONF"
echo '{"op":"assert","from":"page-a","to":"page-b","type":"part_of","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z"}' >> "$LOG"
run '{"relations":[{"from":"page-a","to":"page-c","type":"part_of"}]}'   # default off
[ -f "$CONF" ] && fail "R3 fired while disabled" || pass "R3 off by default"
echo "ALL PASS (A5)"
```

- [ ] **Step 3: impl** — add the R3 branch to `detect_conflict` (spec §3); ensure every `jq` in the detector has `2>/dev/null` and the function `return 1`s on any parse failure (fail-open). Confirm the append to `$LOG` is outside any `detect_enabled` guard.
- [ ] **Step 4:** rerun whole file → ALL PASS.
- [ ] **Step 5: Commit** — `feat(graph): R3 opt-in multi_parent + fail-open hardening`.

---

## Phase B — Consumption

### Task B1: `session-load.sh` high-priority surfacing + test

The conflict warning is a correctness signal — emit it in the **early-banner region** (before the uncapped USER.md/PROJECT.md), not a low-priority spill.

**Files:** `scripts/session-load.sh`, `scripts/lib.sh`, `tests/test-session-load-conflicts.sh`

- [ ] **Step 1: failing test** — populate USER.md+PROJECT.md to ≈6 KB and N open conflicts; assert the banner line is **present** and total ≤ 8000 B (spec test #12). (Model the fixture on `tests/test-session-load-graph.sh`.)
- [ ] **Step 2:** run → FAIL (no banner).
- [ ] **Step 3: impl** —
  - Add `sb_conflicts_open_count <knowledge_dir>` to `lib.sh`: folds `conflicts.jsonl` and prints the open count (`jq -nR 'reduce (inputs|fromjson?) as $r ({}; .[($r|[.from,.type,.to,.kind]|tojson)]=$r)|[.[]]|map(select(.status=="open"))|length'`), `echo 0` on absence/error.
  - In `session-load.sh`, in the early-banner region (near the extractor-health banner ~L194), if the count >0:
    `sb_append "$(printf '## ⚠ second-brain — %s graph conflict(s) pending\nStructural edge contradictions detected at write time. Resolve via the knowledge-maintainer (Phase 3) or `knowledge_relate`.\n\n' "$N")" "graph-conflicts-banner" 250`
- [ ] **Step 4:** run → PASS (present under near-full budget).
- [ ] **Step 5: Commit** — `feat(graph): surface open graph-conflict count in session-load (high-priority)`.

### Task B2: `knowledge-maintainer` Phase 3 drains the queue

**Files:** `agents/knowledge-maintainer.md`

- [ ] **Step 1:** No automated test (agent prose). Edit Phase 3 RELATE to add, **before** routine relate:
  - "**Drain `~/knowledge/graph/conflicts.jsonl` first.** Fold to current status (last line per `(from,type,to,kind)`); for each `status:open`: judge supersede / invalidate (the old was wrong) / dismiss (false alarm); perform the write via `knowledge_relate`; then **append** a `resolved`/`dismissed` line (with `resolved_by`) to `conflicts.jsonl`."
  - "**Phase-3 budget priority** (under the 50-change cap): drain conflicts → B2 SUPERSEDE → routine relate; overflow defers to next run."
- [ ] **Step 2: verify** — `grep -q 'conflicts.jsonl' agents/knowledge-maintainer.md` → 1+. Re-read the phase to confirm it reads coherently and doesn't claim to run in the dream.
- [ ] **Step 3: Commit** — `feat(graph): knowledge-maintainer Phase 3 drains the conflict queue (live path)`.

### Task B3: `dream-runner` read-only echo

**Files:** `agents/dream-runner.md`

- [ ] **Step 1:** Edit Phase 3 RELATE note to add: "May **read** `conflicts.jsonl` read-only and echo the folded open count into the report ('N open graph conflicts — resolve via the maintainer'); **writes nothing** to `graph/`."
- [ ] **Step 2: verify** — confirm the existing "dream does NOT curate edges" sentence is unchanged and the new line doesn't contradict it.
- [ ] **Step 3: Commit** — `docs(graph): dream-runner echoes open-conflict count (read-only)`.

---

## Phase C — Release

### Task C1: Migration row + gate

- [ ] **Step 1:** Add a 0.23.0 migration row to `skills/upgrade/SKILL.md` (purely additive: new `conflicts.jsonl` sidecar appears lazily; nothing to migrate).
- [ ] **Step 2:** `bash tests/run-all.sh` → the new `test-merge-edges-conflict.sh` + `test-session-load-conflicts.sh` are auto-discovered and green; whole suite green.
- [ ] **Step 3:** Run `/second-brain:code-review-deep` on the branch (the release gate per the deep-review-release-gate learning). Address findings.
- [ ] **Step 4:** Smoke: run a real session, confirm `~/.second-brain/error-log.jsonl` has no new errors and `conflicts.jsonl` only appears on a genuine collision.
- [ ] **Step 5: Commit** — `chore(release): write-time contradiction flag — 0.23.0 migration row + gate`.

## Done-when

- `tests/run-all.sh` green incl. the two new tests.
- A genuine retire→reassert (R1) or opposing-pair (R2) flags exactly one folded `open` conflict; a `requires` fan-out flags none.
- `session-load` shows the count under a near-full budget; the maintainer drains it live; the dream never writes `graph/`.
- Deep-review pass clean.
