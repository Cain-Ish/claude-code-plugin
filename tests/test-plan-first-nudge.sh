#!/bin/bash
# Guard: plan-first-nudge fires ONCE when a session reaches multi-file (>=SB_PLAN_FIRST_FILES)
# substantive code edits, stays silent on single-file work, one-line diffs, non-code files and
# non-edit tools, honors the kill switch + thresholds, is advisory-only (never blocks/asks), and
# fail-softs on malformed input.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SC="$ROOT/scripts/plan-first-nudge.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$SC" ] || fail "script missing"

BRAIN_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/sb-plan-$$"); export BRAIN_DIR
mkdir -p "$BRAIN_DIR"
trap 'rm -rf "$BRAIN_DIR"' EXIT

big=$(yes 'line' | head -5)     # >= MIN_LINES (3)
one=$(yes 'x' | head -1)        # one-line diff

evt(){ # $1=tool $2=file $3=session $4=content/new_string
  jq -nc --arg f "$2" --arg s "$3" --arg c "$4" \
    "{tool_name:\"$1\",session_id:\$s,tool_input:{file_path:\$f,content:\$c,new_string:\$c}}"
}

# 1. First substantive code file in a session -> silent (count 1 < 2)
OUT=$(printf '%s' "$(evt Write a.ts S1 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "single code file should be silent"
pass "single-file edit silent"

# 2. Second distinct code file, same session -> nudge once
OUT=$(printf '%s' "$(evt Write b.ts S1 "$big")" | bash "$SC" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'Plan-first' || fail "2nd code file should nudge"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName=="PreToolUse"' >/dev/null 2>&1 || fail "wrong hookEventName"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision=="allow"' >/dev/null 2>&1 || fail "must allow (advisory)"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext|test("Plan-first")' >/dev/null 2>&1 || fail "must use additionalContext"
printf '%s' "$OUT" | grep -qiE '"deny"|"ask"' && fail "must never block/ask"
pass "multi-file nudge: advisory PreToolUse additionalContext"

# 3. Third edit, same session -> silent (already nudged)
OUT=$(printf '%s' "$(evt Edit c.ts S1 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "should nudge at most once per session"
pass "once-per-session"

# 4. One-line diffs across two files (new session) -> silent (below MIN_LINES, never counted)
printf '%s' "$(evt Write a.ts S2 "$one")" | bash "$SC" >/dev/null 2>&1
OUT=$(printf '%s' "$(evt Write b.ts S2 "$one")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "one-line diffs must stay silent"
pass "one-line diffs silent"

# 5. Non-code files ignored (two .md files, new session)
printf '%s' "$(evt Write a.md S3 "$big")" | bash "$SC" >/dev/null 2>&1
OUT=$(printf '%s' "$(evt Write b.md S3 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "non-code files should be ignored"
pass "non-code files ignored"

# 6. Kill switch
printf '%s' "$(evt Write a.ts S4 "$big")" | SB_PLAN_FIRST_NUDGE=off bash "$SC" >/dev/null 2>&1
OUT=$(printf '%s' "$(evt Write b.ts S4 "$big")" | SB_PLAN_FIRST_NUDGE=off bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "kill switch should suppress"
pass "SB_PLAN_FIRST_NUDGE=off suppresses"

# 7. Raised threshold tunes it (need 3 files; 2 should stay silent, new session)
printf '%s' "$(evt Write a.ts S5 "$big")" | SB_PLAN_FIRST_FILES=3 bash "$SC" >/dev/null 2>&1
OUT=$(printf '%s' "$(evt Write b.ts S5 "$big")" | SB_PLAN_FIRST_FILES=3 bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "raised threshold should keep 2 files silent"
pass "SB_PLAN_FIRST_FILES tunes the threshold"

# 8. Non-edit tool + malformed input fail-soft
[ -z "$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$SC" 2>/dev/null)" ] || fail "Bash should be ignored"
[ -z "$(printf 'not json' | bash "$SC" 2>/dev/null)" ] || fail "malformed should be silent"
pass "non-edit tool ignored + malformed fail-soft"

echo; echo "ALL PASS"
