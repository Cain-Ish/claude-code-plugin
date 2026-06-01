#!/bin/bash
# wiki-forget-score.sh must not emit awk syntax errors on mawk when access-counts.json is
# empty/sparse — an empty file makes acount return "" which broke `awk "BEGIN{a=$acc;...}"`
# (mawk: syntax error at or near ;). Regression for the dream-dogfood finding (2026-06-02);
# same bug class as the 0.21.4 lint awk reserved-word fix. Use -v + numeric coercion.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCORER="$ROOT/scripts/wiki-forget-score.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"

export KNOWLEDGE_DIR="$TMP/knowledge"; export BRAIN_DIR="$TMP/.second-brain"
mkdir -p "$KNOWLEDGE_DIR/wiki/entities" "$BRAIN_DIR"
: > "$BRAIN_DIR/access-counts.json"   # EMPTY file = the bug trigger (-f true, jq -> empty)
printf '%s\n' '---' 'title: A' 'type: entities' '---' '# A body padding padding padding' > "$KNOWLEDGE_DIR/wiki/entities/page-a.md"
printf '%s\n' '---' 'title: B' 'type: entities' '---' '# B body padding padding padding' > "$KNOWLEDGE_DIR/wiki/entities/page-b.md"

OUT=$(bash "$SCORER" 2>"$TMP/err"); rc=$?
[ "$rc" -eq 0 ] || fail "scorer exit $rc (stderr: $(head -1 "$TMP/err"))"
grep -qi 'syntax error' "$TMP/err" && fail "awk syntax error on empty access-counts.json: $(head -1 "$TMP/err")"
pass "no awk syntax errors with empty access-counts.json"

[ "$(printf '%s\n' "$OUT" | grep -c .)" -ge 2 ] || fail "expected >=2 scored rows, got: $OUT"
pass "rows still emitted (>=2)"

printf '%s\n' "$OUT" | grep -q 'acc=0' || fail "acc not defaulted to 0 (acount empty-unsafe): $(printf '%s\n' "$OUT" | head -1)"
pass "acc defaults to 0 (acount empty-safe)"

echo; echo "ALL PASS"
