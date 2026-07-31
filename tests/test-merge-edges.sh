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

# --- --source cohort tagging (Phase 3): edges must be attributable ------------
# Attribution IS the reversibility lock: one jq loop invalidates a bad dream's edges
# without touching curated ones. Default stays "extractor" for the historical caller.
echo '{"relations":[{"from":"page-a","to":"page-b","type":"relates"}]}'   | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR" --source "dream:drm_test"
grep -q '"source":"dream:drm_test"' "$LOG" || fail "--source tag not written to the edge"
pass "--source tags the cohort"
echo '{"relations":[{"from":"page-b","to":"page-a","type":"relates"}]}'   | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
grep -q '"source":"extractor"' "$LOG" || fail "default source regressed"
pass "default source unchanged when --source is omitted"

# --- quarantine RE-DRAIN: a quarantined edge whose endpoints appear later --------
# Before this, edges-quarantine.jsonl had a writer and NO reader — a legitimate edge whose
# target page merely arrived later rotted there forever. That is exactly the held-untrusted
# case, so the drain is what makes "quarantined, not dropped" a true statement.
MD="$(cd "$(dirname "$0")"/.. && pwd)/scripts/maintain-deterministic.sh"
if [ -f "$MD" ]; then
  QF="$KDIR/graph/edges-quarantine.jsonl"
  NOWTS=$(date -u +%FT%TZ)
  OLDTS=$(date -u -d '-60 days' +%FT%TZ  || date -u -v-60d +%FT%TZ  || echo "2000-01-01T00:00:00Z")
  printf '{"op":"assert","from":"page-a","to":"page-b","type":"relates","valid_to":null,"recorded_at":"%s","source":"dream:drm_q","confidence":"medium"}
{"op":"assert","from":"page-a","to":"never-exists","type":"relates","valid_to":null,"recorded_at":"%s","source":"extractor","confidence":"medium"}
{"op":"assert","from":"page-a","to":"ancient-ghost","type":"relates","valid_to":null,"recorded_at":"%s","source":"extractor","confidence":"medium"}
'     "$NOWTS" "$NOWTS" "$OLDTS" > "$QF"
  BEFORE_EDGES=$(grep -c . "$LOG"  || echo 0)
  SB_MAINTAIN_FORCE=1 BRAIN_DIR="$KDIR/.brain" KNOWLEDGE_DIR="$KDIR"     CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KDIR" bash "$MD" >/dev/null 2>&1
  grep -q '"to":"page-b".*"source":"dream:drm_q"' "$LOG"     && pass "re-drain replayed the now-resolvable edge WITH its original cohort tag"     || fail "re-drain did not replay a resolvable quarantined edge (or lost its source tag)"
  grep -q 'never-exists' "$QF"      && pass "still-unresolvable edge stays quarantined" || fail "unresolvable edge was dropped"
  grep -q 'ancient-ghost' "$QF"      && fail "TTL did not drop a 60-day-old never-resolving entry (quarantine grows unbounded)"     || pass "TTL drops never-resolving entries (bounded quarantine)"
  grep -q 'page-b' "$QF"      && fail "replayed edge left behind in the quarantine (would re-apply forever)"     || pass "replayed edge removed from the quarantine"
fi

echo; echo "ALL PASS"
