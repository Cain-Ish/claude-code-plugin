#!/usr/bin/env bash
# Hermetic tests for scripts/kb-drain-reconcile.sh
# Tests: basic reconcile, idempotency, ghost id no-op, already-processed no-op.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/kb-drain-reconcile.sh"
fail(){ echo "FAIL: $1"; exit 1; }
pass(){ echo "PASS: $1"; }
[ -f "$S" ] || fail "kb-drain-reconcile.sh not found"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
KD="$TMP/knowledge"; BD="$TMP/.second-brain"
mkdir -p "$KD/wiki/entities" "$BD/projects/p/raw"

# --- helpers ---
make_raw() { # <id> <status>
  cat > "$BD/projects/p/raw/${1}.md" <<EOF
---
id: ${1}
source: /x
captured_at: 2026-01-01T00:00:00Z
captured_by: user
origin: p
content_type: text/plain
status: ${2}
---
body
EOF
}

raw_status()    { grep -m1 '^status:'      "$BD/projects/p/raw/${1}.md" | sed 's/status:[[:space:]]*//' | tr -d '\r '; }
raw_node()      { grep -m1 '^target_node:' "$BD/projects/p/raw/${1}.md" | sed 's/target_node:[[:space:]]*//' | tr -d '\r '; }

# --- Test 1: basic reconcile ---
make_raw "rawid-1" "unprocessed"
cat > "$KD/wiki/entities/foo.md" <<'EOF'
---
title: foo
type: entities
---
# foo
## Sources
- captured from /x (raw rawid-1)
EOF

out=$(bash "$S" --knowledge-dir "$KD" --brain-dir "$BD" --slug p 2>&1)
[ $? -eq 0 ] || fail "exit non-zero: $out"
[ "$(raw_status rawid-1)" = "processed" ]  || fail "rawid-1 not marked processed (got: $(raw_status rawid-1))"
[ "$(raw_node   rawid-1)" = "foo" ]        || fail "rawid-1 target_node not set to foo (got: $(raw_node rawid-1))"
echo "$out" | grep -q "reconciled 1 item" || fail "output should say 'reconciled 1 item', got: $out"
pass "basic reconcile: status+target_node written"

# --- Test 2: idempotency ---
content_before=$(cat "$BD/projects/p/raw/rawid-1.md")
out2=$(bash "$S" --knowledge-dir "$KD" --brain-dir "$BD" --slug p 2>&1)
[ $? -eq 0 ] || fail "second run exit non-zero: $out2"
echo "$out2" | grep -q "reconciled 0 item" || fail "second run should reconcile 0, got: $out2"
content_after=$(cat "$BD/projects/p/raw/rawid-1.md")
[ "$content_before" = "$content_after" ] || fail "second run mutated already-processed file"
pass "idempotent: second run is a no-op"

# --- Test 3: ghost id (no raw file) ---
cat > "$KD/wiki/entities/bar.md" <<'EOF'
---
title: bar
type: entities
---
# bar
## Sources
- captured from /y (raw ghost-9)
EOF

out3=$(bash "$S" --knowledge-dir "$KD" --brain-dir "$BD" --slug p 2>&1)
[ $? -eq 0 ] || fail "ghost id caused non-zero exit: $out3"
echo "$out3" | grep -q "reconciled 0 item" || fail "ghost id should reconcile 0, got: $out3"
pass "ghost id: no-op (exit 0, no error)"

# --- Test 4: already-processed item referenced by a node is untouched ---
make_raw "rawid-already" "processed"
# Also set a target_node already so we can verify it is not overwritten.
printf '\ntarget_node: original-node\n' >> "$BD/projects/p/raw/rawid-already.md"
cat > "$KD/wiki/entities/baz.md" <<'EOF'
---
title: baz
type: entities
---
# baz
## Sources
- captured from /z (raw rawid-already)
EOF

out4=$(bash "$S" --knowledge-dir "$KD" --brain-dir "$BD" --slug p 2>&1)
[ $? -eq 0 ] || fail "already-processed caused non-zero exit: $out4"
echo "$out4" | grep -q "reconciled 0 item" || fail "already-processed should reconcile 0, got: $out4"
[ "$(raw_node rawid-already)" = "original-node" ] || fail "already-processed target_node was overwritten"
pass "already-processed: untouched"

# --- Test 5: back-ref COUPLING — the EXACT documented worker template parses ---
# agents/raw-drainer.md REQUIRES the back-ref line shape:
#   - captured from <source> (raw <id>)
# This proves the worker's documented output is parseable by reconcile's actual
# regex; it goes RED if either the template prose or reconcile's regex drifts.
make_raw "rawid-coupled" "unprocessed"
cat > "$KD/wiki/entities/coupled.md" <<'EOF'
---
title: coupled
type: entities
---
# coupled
## Sources
- captured from https://example.com/doc (raw rawid-coupled)
EOF

out5=$(bash "$S" --knowledge-dir "$KD" --brain-dir "$BD" --slug p 2>&1)
[ $? -eq 0 ] || fail "coupling run exit non-zero: $out5"
[ "$(raw_status rawid-coupled)" = "processed" ] || fail "documented template not parsed: rawid-coupled not processed (got: $(raw_status rawid-coupled))"
[ "$(raw_node   rawid-coupled)" = "coupled" ]   || fail "documented template: target_node not set to node slug (got: $(raw_node rawid-coupled))"
echo "$out5" | grep -q "reconciled 1 item" || fail "coupling run should reconcile 1, got: $out5"
pass "back-ref coupling: exact '- captured from <source> (raw <id>)' template is parseable"

# --- Test 6: MULTI-ref — one node, two back-refs, two items both flip; count=2 ---
# Exercises reconcile's inner multi-id loop (the `while read raw_id` over all
# (raw <id>) matches found in a single node).
make_raw "rawid-multiA" "unprocessed"
make_raw "rawid-multiB" "unprocessed"
cat > "$KD/wiki/entities/multi.md" <<'EOF'
---
title: multi
type: entities
---
# multi
## Sources
- captured from /a (raw rawid-multiA)
- captured from /b (raw rawid-multiB)
EOF

out6=$(bash "$S" --knowledge-dir "$KD" --brain-dir "$BD" --slug p 2>&1)
[ $? -eq 0 ] || fail "multi-ref run exit non-zero: $out6"
[ "$(raw_status rawid-multiA)" = "processed" ] || fail "multi-ref: idA not processed (got: $(raw_status rawid-multiA))"
[ "$(raw_status rawid-multiB)" = "processed" ] || fail "multi-ref: idB not processed (got: $(raw_status rawid-multiB))"
[ "$(raw_node   rawid-multiA)" = "multi" ]      || fail "multi-ref: idA target_node wrong (got: $(raw_node rawid-multiA))"
[ "$(raw_node   rawid-multiB)" = "multi" ]      || fail "multi-ref: idB target_node wrong (got: $(raw_node rawid-multiB))"
echo "$out6" | grep -q "reconciled 2 item" || fail "multi-ref should report 'reconciled 2 item(s)', got: $out6"
pass "multi-ref: both idA and idB flip; count line reports reconciled 2"

echo; echo "ALL PASS"
