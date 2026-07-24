#!/bin/bash
# Write-time contradiction detector in merge-edges.sh.
# Spec: archive/docs branch, docs/specs/2026-06-01-write-time-contradiction-flag-design.md
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/merge-edges.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }
pass(){ echo "PASS: $1"; }

[ -f "$SCRIPT" ] || fail "scripts/merge-edges.sh not found"
command -v jq >/dev/null 2>&1 || fail "jq required for this test"

KDIR="$TMP/knowledge"; mkdir -p "$KDIR/wiki/entities"
mkpage(){ printf '%s\n' '---' "title: $1" 'type: entities' '---' "# $1" > "$KDIR/wiki/entities/$1.md"; }
mkpage page-a; mkpage page-b; mkpage page-c
LOG="$KDIR/graph/edges.jsonl"; CONF="$KDIR/graph/conflicts.jsonl"
run(){ echo "$1" | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"; }
# folded open conflicts (current status = last line per identity)
open_count(){ [ -s "$CONF" ] && jq -nR 'reduce (inputs|fromjson?) as $r ({}; .[($r|[.from,.type,.to,.kind]|tojson)]=$r)|[.[]]|map(select(.status=="open"))|length' "$CONF" || echo 0; }
seed(){ mkdir -p "$KDIR/graph"; printf '%s\n' "$1" >> "$LOG"; }
reset(){ rm -f "$LOG" "$CONF"; mkdir -p "$KDIR/graph"; }

# --- 1: no edges.jsonl => clean no-op (no conflicts file) ---
reset; rm -f "$LOG"
run '{"relations":[{"from":"page-a","to":"page-b","type":"requires"}]}'
[ -f "$CONF" ] && fail "conflicts.jsonl created with no prior graph" || pass "no-graph no-op"

# --- 2: kill switch ---
reset
seed '{"op":"assert","from":"page-a","to":"page-b","type":"requires","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z","source":"extractor"}'
seed '{"op":"invalidate","from":"page-a","to":"page-b","type":"requires","valid_to":"2026-06-01","recorded_at":"2026-06-01T10:00:00.123Z","source":"manual"}'
SB_CONFLICT_DETECT=off run '{"relations":[{"from":"page-a","to":"page-b","type":"requires"}]}'
[ -f "$CONF" ] && fail "kill switch did not suppress detection" || pass "SB_CONFLICT_DETECT=off suppresses"

# --- 3: R1 reintroduce (healthy retire -> degraded reassert) + edge still appended ---
reset
seed '{"op":"assert","from":"page-a","to":"page-b","type":"requires","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z","source":"extractor"}'
seed '{"op":"invalidate","from":"page-a","to":"page-b","type":"requires","valid_to":"2026-06-01","recorded_at":"2026-06-01T10:00:00.123Z","source":"manual"}'
run '{"relations":[{"from":"page-a","to":"page-b","type":"requires"}]}'
[ -f "$CONF" ] || fail "R1 did not flag reintroduce"
grep -q '"kind":"reintroduce"' "$CONF" || fail "R1 kind not reintroduce"
[ "$(open_count)" = 1 ] || fail "R1 open-count != 1 (got $(open_count))"
[ "$(grep -c '"to":"page-b"' "$LOG")" -ge 3 ] || fail "R1: edge not also appended"
pass "R1 reintroduce flagged + edge appended + ms-invalidate folds latest (granularity)"

# --- 4: R1 idempotent ---
run '{"relations":[{"from":"page-a","to":"page-b","type":"requires"}]}'
[ "$(open_count)" = 1 ] || fail "R1 not idempotent (got $(open_count))"
pass "R1 idempotent (status-fold guard)"

# --- 5: status fold open->resolved = 0 open ---
printf '%s\n' '{"detected_at":"2026-06-01T11:00:00Z","from":"page-a","type":"requires","to":"page-b","kind":"reintroduce","against":{},"source":"merge-edges","status":"resolved"}' >> "$CONF"
[ "$(open_count)" = 0 ] || fail "status fold did not respect resolved (got $(open_count))"
pass "status fold (open->resolved = 0 open)"

# --- 6: R2 opposing (circular supersede) ---
reset
seed '{"op":"assert","from":"page-a","to":"page-b","type":"supersedes","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z","source":"extractor"}'
run '{"relations":[{"from":"page-b","to":"page-a","type":"supersedes"}]}'
grep -q '"kind":"opposing"' "$CONF" || fail "R2 circular supersede not flagged"
pass "R2 opposing (circular supersede)"

# --- 7: R2 supersede-vs-requires on the same pair ---
reset
seed '{"op":"assert","from":"page-a","to":"page-b","type":"supersedes","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z","source":"extractor"}'
run '{"relations":[{"from":"page-a","to":"page-b","type":"requires"}]}'
grep -q '"kind":"opposing"' "$CONF" || fail "R2 supersede-vs-requires not flagged"
pass "R2 opposing (supersede<->requires)"

# --- 8: no cry-wolf on legit requires fan-out ---
reset
seed '{"op":"assert","from":"page-a","to":"page-b","type":"requires","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z","source":"extractor"}'
run '{"relations":[{"from":"page-a","to":"page-c","type":"requires"}]}'
[ -f "$CONF" ] && fail "fan-out wrongly flagged" || pass "no cry-wolf on requires fan-out"

# --- 9: within-batch opposing pair (running snapshot) ---
reset
run '{"relations":[{"from":"page-a","to":"page-b","type":"supersedes"},{"from":"page-a","to":"page-b","type":"requires"}]}'
grep -q '"kind":"opposing"' "$CONF" || fail "within-batch opposing pair NOT caught (running snapshot broken)"
pass "within-batch opposing pair caught (running snapshot)"

# --- 10: fail-open on corrupt log ---
reset
seed '{"op":"assert","from":"page-a","to":"page-b","type":"requires","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z"}'
printf '%s' '{"op":"assert","from":"page-a","to":"pag' >> "$LOG"   # torn last line
run '{"relations":[{"from":"page-a","to":"page-c","type":"relates"}]}'; rc=$?
[ "$rc" -eq 0 ] || fail "merge-edges did not exit 0 on corrupt log"
pass "fail-open exit 0 on corrupt log"

# --- 11: R3 multi_parent (opt-in) ---
reset
seed '{"op":"assert","from":"page-a","to":"page-b","type":"part_of","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z"}'
SB_CONFLICT_MULTIPARENT=on run '{"relations":[{"from":"page-a","to":"page-c","type":"part_of"}]}'
grep -q '"kind":"multi_parent"' "$CONF" || fail "R3 not flagged when enabled"
pass "R3 multi_parent (opt-in on)"
reset
seed '{"op":"assert","from":"page-a","to":"page-b","type":"part_of","valid_to":null,"recorded_at":"2026-06-01T10:00:00Z"}'
run '{"relations":[{"from":"page-a","to":"page-c","type":"part_of"}]}'
[ -f "$CONF" ] && fail "R3 fired while disabled" || pass "R3 off by default"

echo; echo "ALL PASS"
