#!/bin/bash
# Tests for scripts/merge-edges.sh — the pure-bash edge capture path.
# Edges proposed by the extractor are appended to ~/knowledge/graph/edges.jsonl
# (op:assert, source:extractor) IFF both endpoints resolve to real wiki pages;
# unresolved endpoints are quarantined; invalid types/empty input are no-ops.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/merge-edges.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$SCRIPT" ] || fail "scripts/merge-edges.sh not found"

KDIR="$TMP/knowledge"; mkdir -p "$KDIR/wiki/entities"
printf '%s\n' '---' 'title: A' 'type: entities' '---' '# A' > "$KDIR/wiki/entities/page-a.md"
printf '%s\n' '---' 'title: B' 'type: entities' '---' '# B' > "$KDIR/wiki/entities/page-b.md"

# --- Test 1: a resolvable edge is appended ---
echo '{"relations":[{"from":"page-a","to":"page-b","type":"requires","confidence":"high"}]}' \
  | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
LOG="$KDIR/graph/edges.jsonl"
[ -f "$LOG" ] || fail "edges.jsonl not created"
grep -q '"from":"page-a"' "$LOG" || fail "resolvable edge not appended"
grep -q '"op":"assert"' "$LOG" || fail "op:assert missing"
grep -q '"source":"extractor"' "$LOG" || fail "source not stamped"
pass "resolvable edge appended with op/source stamped"

# --- Test 2: an edge to a non-existent page is quarantined ---
echo '{"relations":[{"from":"page-a","to":"ghost-page","type":"requires"}]}' \
  | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
grep -q '"to":"ghost-page"' "$LOG" && fail "unresolved edge leaked into edges.jsonl"
QLOG="$KDIR/graph/edges-quarantine.jsonl"
{ [ -f "$QLOG" ] && grep -q '"to":"ghost-page"' "$QLOG"; } || fail "unresolved edge not quarantined"
pass "unresolved-endpoint edge quarantined, not asserted"

# --- Test 3: empty / missing relations is a clean no-op ---
BEFORE=$(wc -l < "$LOG")
echo '{"relations":[]}' | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
echo '{}'              | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
AFTER=$(wc -l < "$LOG")
[ "$BEFORE" = "$AFTER" ] || fail "empty relations changed the log"
pass "empty/missing relations is a no-op"

# --- Test 4: invalid edge type rejected ---
echo '{"relations":[{"from":"page-a","to":"page-b","type":"bogus"}]}' \
  | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
grep -q '"type":"bogus"' "$LOG" && fail "invalid edge type was appended"
pass "invalid edge type rejected"

# --- Test 5: non-JSON stdin is a no-op (never crashes the Stop hook) ---
echo 'not json at all' | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR" || fail "non-JSON input returned non-zero"
pass "non-JSON stdin is a clean no-op"

# --- Test 6: valid_from passes through; default record has valid_to null ---
echo '{"relations":[{"from":"page-a","to":"page-b","type":"affects","valid_from":"2026-05-29"}]}' \
  | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
grep -q '"valid_from":"2026-05-29"' "$LOG" || fail "valid_from not recorded"
pass "valid_from passes through"

echo; echo "ALL PASS"
