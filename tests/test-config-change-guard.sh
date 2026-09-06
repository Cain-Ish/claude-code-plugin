#!/bin/bash
# pins: SB_CONFIG_CHANGE_AUDIT — kill-switch test: asserts =off bypasses the audit entirely (Test 3)
# Tests for scripts/config-change-guard.sh — ConfigChange audit-only hook.
# Closes G-HOOK-3 from wiki/security/plugin-hardening-gap-analysis-2026-05-28.md.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/config-change-guard.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export BRAIN_DIR="$TMP/brain"
mkdir -p "$BRAIN_DIR"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

audit_file() {
  ls "$BRAIN_DIR"/audit-log.jsonl 2>/dev/null
}

# Helper: build a ConfigChange event payload and pipe to the hook.
run_hook() {  # $1 source, $2 file_path
  jq -nc --arg s "$1" --arg f "$2" '{
    session_id: "test-session",
    hook_event_name: "ConfigChange",
    source: $s,
    file_path: $f
  }' | bash "$SCRIPT" 2>/dev/null
}

# --- Test 1: hook emits no stdout (audit-only) -------------------------
rm -f "$BRAIN_DIR/audit-log.jsonl"
OUT=$(run_hook "project_settings" "/path/to/.claude/settings.json")
[ -z "$OUT" ] || fail "audit-only hook must not emit stdout (got: $OUT)"
pass "audit-only: no stdout"

# --- Test 2: audit-log.jsonl record created with correct fields --------
[ -f "$BRAIN_DIR/audit-log.jsonl" ] || fail "audit-log.jsonl should exist after hook fires"
LINE=$(tail -n1 "$BRAIN_DIR/audit-log.jsonl")
[ -n "$LINE" ] && echo "$LINE" | jq -e '.hook == "config-change-guard.sh"' >/dev/null \
  || fail "audit line should name the hook (got: $LINE)"
[ -n "$LINE" ] && echo "$LINE" | jq -e '.verdict == "flag"' >/dev/null \
  || fail "verdict should be 'flag' for audit-only (got: $LINE)"
[ -n "$LINE" ] && echo "$LINE" | jq -e '.rule | test("config-change:project_settings")' >/dev/null \
  || fail "rule should include source category (got: $LINE)"
[ -n "$LINE" ] && echo "$LINE" | jq -e '.target | test("\\.claude/settings\\.json")' >/dev/null \
  || fail "target should be the file_path (got: $LINE)"
[ -n "$LINE" ] && echo "$LINE" | jq -e '.extra.source == "project_settings"' >/dev/null \
  || fail "extra should preserve original source (got: $LINE)"
pass "audit-log entry has correct fields"

# --- Test 3: SB_CONFIG_CHANGE_AUDIT=off bypasses entirely ---------------
rm -f "$BRAIN_DIR/audit-log.jsonl"
OUT=$(SB_CONFIG_CHANGE_AUDIT=off run_hook "user_settings" "/etc/dummy.json")
[ -z "$OUT" ] || fail "kill-switch should produce no stdout (got: $OUT)"
[ ! -f "$BRAIN_DIR/audit-log.jsonl" ] || fail "kill-switch should not write audit log"
pass "SB_CONFIG_CHANGE_AUDIT=off bypasses hook"

# --- Test 4: non-JSON input ignored silently ----------------------------
rm -f "$BRAIN_DIR/audit-log.jsonl"
OUT=$(echo "not-json-at-all" | bash "$SCRIPT" 2>/dev/null)
[ -z "$OUT" ] || fail "garbage input should be silently ignored (got: $OUT)"
[ ! -f "$BRAIN_DIR/audit-log.jsonl" ] || fail "garbage input should not create audit entry"
pass "non-JSON input silently ignored"

# --- Test 5: empty stdin ignored silently -------------------------------
rm -f "$BRAIN_DIR/audit-log.jsonl"
OUT=$(echo "" | bash "$SCRIPT" 2>/dev/null)
[ -z "$OUT" ] || fail "empty stdin should be silently ignored (got: $OUT)"
[ ! -f "$BRAIN_DIR/audit-log.jsonl" ] || fail "empty stdin should not create audit entry"
pass "empty stdin silently ignored"

# --- Test 6: each matcher category logs distinct rule label -------------
rm -f "$BRAIN_DIR/audit-log.jsonl"
for cat in user_settings project_settings local_settings policy_settings skills; do
  run_hook "$cat" "/tmp/$cat.json" >/dev/null
done
LINES=$(wc -l < "$BRAIN_DIR/audit-log.jsonl" | tr -d ' ')
[ "$LINES" = "5" ] || fail "expected 5 audit lines, got $LINES"
for cat in user_settings project_settings local_settings policy_settings skills; do
  grep -q "config-change:$cat" "$BRAIN_DIR/audit-log.jsonl" \
    || fail "rule for $cat missing from audit-log"
done
pass "all 5 matcher categories produce distinct rule labels"

echo
echo "ALL PASS"
