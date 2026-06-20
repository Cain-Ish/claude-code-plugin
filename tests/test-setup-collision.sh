#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/lib.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fail=1; fi; }
TMP=$(mktemp -d); REG="$TMP/projects.jsonl"
printf '%s\n' '{"slug":"utils","name":"utils","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0,"root_path":"/repos/a/utils","git_remote":"git@github.com:me/a-utils.git"}' > "$REG"

# unregistered slug → new
check "new slug" "new" "$(sb_project_identity "$REG" "fresh" "/repos/fresh" "")"
# same slug + same remote → same project
check "same remote" "same" "$(sb_project_identity "$REG" "utils" "/anywhere" "git@github.com:me/a-utils.git")"
# same slug + DIFFERENT remote → collision
check "diff remote" "collision" "$(sb_project_identity "$REG" "utils" "/repos/b/utils" "git@github.com:me/b-utils.git")"
# same slug + both-empty remote + same root_path → same project
printf '%s\n' '{"slug":"local","name":"local","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0,"root_path":"/repos/local","git_remote":""}' >> "$REG"
check "no-remote same path" "same" "$(sb_project_identity "$REG" "local" "/repos/local" "")"
# same slug + both-empty remote + DIFFERENT root_path → collision
check "no-remote diff path" "collision" "$(sb_project_identity "$REG" "local" "/elsewhere/local" "")"
# LEGACY record (pre-0.33: 4-field, NO root_path/git_remote) re-setup with a NEWLY-detected
# remote → must lazy-fill as the SAME project, never a false collision (the live-setup bug).
printf '%s\n' '{"slug":"legacy","name":"legacy","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0}' >> "$REG"
check "legacy record + detected remote → same (lazy-fill, not false collision)" "same" \
  "$(sb_project_identity "$REG" "legacy" "/repos/legacy" "git@github.com:me/legacy.git")"
check "legacy record + no detected identity → same" "same" \
  "$(sb_project_identity "$REG" "legacy" "" "")"

rm -rf "$TMP"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
