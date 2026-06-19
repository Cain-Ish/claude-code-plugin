#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/lib.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fail=1; fi; }
TMP=$(mktemp -d)

# 1. pretty-printed multi-line single record → one compact line
P="$TMP/pretty.jsonl"
printf '{\n  "slug": "alpha",\n  "name": "alpha",\n  "last_session_iso": "2026-05-01T00:00:00Z",\n  "hot_byte_count": 0\n}\n' > "$P"
sb_harden_projects_jsonl "$P"
check "pretty → 1 line" "1" "$(grep -c . "$P")"
check "pretty slug kept" "alpha" "$(jq -r .slug "$P")"

# 2. duplicate slug → deduped to the NEWEST last_session_iso
D="$TMP/dup.jsonl"
printf '%s\n%s\n' \
  '{"slug":"beta","name":"beta","last_session_iso":"2026-01-01T00:00:00Z","hot_byte_count":0}' \
  '{"slug":"beta","name":"beta","last_session_iso":"2026-09-09T00:00:00Z","hot_byte_count":9}' > "$D"
sb_harden_projects_jsonl "$D"
check "dup → 1 record" "1" "$(grep -c . "$D")"
check "dup kept newest" "9" "$(jq -r .hot_byte_count "$D")"

# 3. already-canonical clean file → UNCHANGED, no backup created
C="$TMP/clean.jsonl"
printf '%s\n' '{"slug":"gamma","name":"gamma","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0}' > "$C"
BEFORE=$(cat "$C")
sb_harden_projects_jsonl "$C"
check "clean unchanged" "$BEFORE" "$(cat "$C")"
check "clean no backup" "0" "$(ls "$TMP"/clean.jsonl.bak.* 2>/dev/null | wc -l | tr -d ' ')"

# 4. truly malformed (non-JSON line) → left INTACT, returns 1
M="$TMP/bad.jsonl"
printf '%s\n' 'this is not json at all {{{' > "$M"
BEFORE_M=$(cat "$M")
sb_harden_projects_jsonl "$M"; rc=$?
check "malformed returns 1" "1" "$rc"
check "malformed left intact" "$BEFORE_M" "$(cat "$M")"

rm -rf "$TMP"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
