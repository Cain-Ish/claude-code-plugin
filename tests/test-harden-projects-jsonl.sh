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

# 5. remote-identity dedupe: two slugs sharing one NORMALIZED remote (ssh vs https
#    forms of the same repo) collapse to the slug matching the remote's repo basename,
#    LOUDLY (stderr + error-log entry naming the dropped slug).
BRAIN_DIR="$TMP"   # sandbox the sb_log_error target with the fixtures
R="$TMP/remote-dup.jsonl"
printf '%s\n%s\n' \
  '{"slug":"name","last_session_iso":"2026-01-01T00:00:00Z","git_remote":"git@github.com:Example/Name.git"}' \
  '{"slug":"name-2","last_session_iso":"2026-06-01T00:00:00Z","git_remote":"https://github.com/example/name.git"}' > "$R"
ERR=$(sb_harden_projects_jsonl "$R" 2>&1 >/dev/null)
check "remote dedupe → 1 record" "1" "$(grep -c . "$R")"
check "remote dedupe kept the basename-matching slug" "name" "$(jq -r .slug "$R")"
check "remote dedupe reported dropped slug on stderr" "1" "$(printf '%s' "$ERR" | grep -c 'name-2')"
check "remote dedupe logged dropped slug" "1" "$(grep -c 'name-2' "$TMP/error-log.jsonl" 2>/dev/null | head -1)"

# 5b. no slug matches the remote's basename → the newest last_session_iso wins
R2="$TMP/remote-dup2.jsonl"
printf '%s\n%s\n' \
  '{"slug":"alpha","last_session_iso":"2026-01-01T00:00:00Z","git_remote":"https://github.com/example/zeta.git"}' \
  '{"slug":"beta","last_session_iso":"2026-06-01T00:00:00Z","git_remote":"git@github.com:example/zeta.git"}' > "$R2"
sb_harden_projects_jsonl "$R2" >/dev/null 2>&1
check "remote dedupe (no basename match) kept newest" "beta" "$(jq -r .slug "$R2")"

# 5c. records with an absent/empty git_remote are never grouped (no shared identity)
R3="$TMP/noremote.jsonl"
printf '%s\n%s\n' \
  '{"slug":"p1","last_session_iso":"2026-01-01T00:00:00Z"}' \
  '{"slug":"p2","last_session_iso":"2026-02-01T00:00:00Z","git_remote":""}' > "$R3"
sb_harden_projects_jsonl "$R3" >/dev/null 2>&1
check "empty-remote records never collapsed" "2" "$(grep -c . "$R3")"

# 5d. distinct remotes stay distinct records
R4="$TMP/distinct.jsonl"
printf '%s\n%s\n' \
  '{"slug":"one","last_session_iso":"2026-01-01T00:00:00Z","git_remote":"https://github.com/example/one.git"}' \
  '{"slug":"two","last_session_iso":"2026-02-01T00:00:00Z","git_remote":"https://github.com/example/two.git"}' > "$R4"
sb_harden_projects_jsonl "$R4" >/dev/null 2>&1
check "distinct remotes stay distinct" "2" "$(grep -c . "$R4")"

# 6. D120/D139: a torn/partial line (a concurrent-append tear) must NOT abandon the
# other valid records — the old strict `-s` slurp aborted on the bad line and left
# the WHOLE file untouched (return 1), even though two good records were readable.
T="$TMP/torn.jsonl"
printf '%s\n' '{"slug":"tornkeep1","last_session_iso":"2026-01-01T00:00:00Z","hot_byte_count":0}' > "$T"
printf '{"slug":"partial' >> "$T"   # no trailing newline: genuine crash-mid-write tear
printf '\n%s\n' '{"slug":"tornkeep2","last_session_iso":"2026-02-01T00:00:00Z","hot_byte_count":0}' >> "$T"
rm -f "$TMP/error-log.jsonl"
sb_harden_projects_jsonl "$T" >/dev/null 2>&1
check "torn line: both good records survive" "2" "$(grep -c . "$T")"
check "torn line: record before the tear kept" "1" "$(jq -s '[.[] | select(.slug=="tornkeep1")] | length' "$T")"
check "torn line: record after the tear kept" "1" "$(jq -s '[.[] | select(.slug=="tornkeep2")] | length' "$T")"
check "torn line: logged once via sb_log_error" "1" "$(grep -c 'torn line' "$TMP/error-log.jsonl" 2>/dev/null | head -1)"

rm -rf "$TMP"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
