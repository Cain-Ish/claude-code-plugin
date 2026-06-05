#!/bin/bash
# Guard: USER.md (the human's global Never/Always rules — stated priority 1) must ALWAYS land in
# the SessionStart context, even when the conditional banners have already consumed the byte budget.
# Regression: USER.md was appended after ~9 banners under the shared budget, so a degraded
# multi-banner state could silently drop it. sb_append now honors a `force` arg that bypasses the
# budget; the USER.md call passes it.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

# 1. the live USER.md append must pass `force`
# force + a finite cap: always lands (priority-1) but bounded so a huge USER.md can't breach the hook cap.
grep -qE 'sb_append "\$USER_CONTENT" "USER.md" [0-9]+ force' "$SL" \
  || fail "the USER.md sb_append does not pass the force arg (would be budget-starvable)"
grep -qE 'sb_append "\$USER_CONTENT" "USER.md" 0 force' "$SL" \
  && fail "USER.md is forced but UNCAPPED (max=0) — a huge USER.md could breach the ~10K hook cap"
pass "session-load forces the USER.md section past the budget"

# 1b. SP-E: the PROJECT.md append must ALSO pass force + a finite cap — the sibling bug.
# PROJECT.md is the project hot tier, appended AFTER ~9 banners, so it was budget-starvable
# and could be silently dropped (losing the project's whole context).
grep -qE 'sb_append "\$PROJ_CONTENT" "PROJECT.md" [0-9]+ force' "$SL" \
  || fail "the PROJECT.md sb_append does not pass force (the project hot tier is budget-starvable)"
grep -qE 'sb_append "\$PROJ_CONTENT" "PROJECT.md" 0 force' "$SL" \
  && fail "PROJECT.md is forced but UNCAPPED (max=0) — a huge PROJECT.md could breach the ~10K hook cap"
pass "session-load forces the PROJECT.md section past the budget (SP-E sibling fix)"

# 2. functional: extract the real sb_append and prove force bypasses the budget, non-force doesn't
TMP=$(mktemp); awk '/^sb_append\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SL" > "$TMP"
sb_log_error(){ :; }                      # no-op stub for the extracted function
OUT=$(mktemp); OUTPUT_FILE="$OUT"; BYTE_BUDGET=100; USED=95
BIG="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"   # 49 chars → 95+49 > 100
. "$TMP"
: > "$OUT"; USED=95
if sb_append "$BIG" "banner" 0; then fail "non-forced over-budget section should be skipped (return 1)"; fi
[ ! -s "$OUT" ] || fail "skipped section must not be written"
pass "non-forced section over budget is skipped (prior behaviour preserved)"
: > "$OUT"; USED=95
sb_append "${BIG//x/u}" "USER.md" 0 force || fail "forced USER.md should append (return 0)"
grep -q 'uuuu' "$OUT" || fail "forced USER.md was NOT written despite being over budget"
pass "forced USER.md lands even when the budget is already spent"
rm -f "$TMP" "$OUT"
echo; echo "ALL PASS"
