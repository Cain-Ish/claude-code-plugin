#!/bin/bash
# The ai-block must be excluded from the FORGET body byte-count (wiki-forget-score.sh wc -c +
# the body<200 stub-floor gate). A page whose only "length" is a big ai-block must still hit
# the stub floor (spec §5b) — else uniform blocks silently lift every page's score.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SCORER="$ROOT/scripts/wiki-forget-score.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"
export KNOWLEDGE_DIR="$TMP/knowledge"; export BRAIN_DIR="$TMP/.second-brain"
mkdir -p "$KNOWLEDGE_DIR/wiki/entities" "$BRAIN_DIR"

# e: tiny prose ("hi") padded ONLY by a long ai-block → prose<200 → stub floor must apply
{ echo '---'; echo 'title: E'; echo 'type: entities'; echo '---'
  echo '<!-- ai:begin -->'
  echo 'identity: long identity padding padding padding padding padding padding padding padding'
  echo 'current_state: more padding padding padding padding padding padding padding padding pad'
  echo '<!-- ai:end -->'
  echo '# E'; echo 'hi'; } > "$KNOWLEDGE_DIR/wiki/entities/e.md"
# f: long real prose, no block → full 0.5 entity category
{ echo '---'; echo 'title: F'; echo 'type: entities'; echo '---'; echo '# F'
  for i in $(seq 1 30); do echo "real prose line $i with enough content to comfortably exceed two hundred bytes"; done; } > "$KNOWLEDGE_DIR/wiki/entities/f.md"

OUT=$(bash "$SCORER" 2>/dev/null) || fail "scorer failed"
se=$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="e"{print $1}')
sf=$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="f"{print $1}')
[ -n "$se" ] && [ -n "$sf" ] || fail "missing scores (e='$se' f='$sf')"
awk -v a="$se" -v b="$sf" 'BEGIN{exit !(a+0 < b+0)}' \
  || fail "block-padded stub e=$se scored >= real-prose f=$sf — ai-block not excluded from wc -c"
pass "ai-block excluded from FORGET body byte-count (block-padded page still hits the stub floor)"

echo; echo "ALL PASS"
