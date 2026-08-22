#!/bin/bash
# Tests for scripts/sar-summary.sh — Stop hook that aggregates audit-log
# entries for the current session_id and emits a SAR (Safety Adherence Rate)
# banner via systemMessage. HarnessAudit-style metric for self-feedback.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/sar-summary.sh"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

BRAIN=$(mktemp -d)
trap 'rm -rf "$BRAIN"' EXIT

# Helper: emit an audit-log entry.
log_entry() {
  local sid="$1" verdict="$2" rule="$3"
  printf '{"ts":"2026-05-21T00:00:00Z","hook":"persona-tool-guard.sh","verdict":"%s","rule":"%s","target":"x","reason":"y","session_id":"%s","extra":{}}\n' \
    "$verdict" "$rule" "$sid" >> "$BRAIN/audit-log.jsonl"
}

# Test 1: no audit log → silent
out=$(BRAIN_DIR="$BRAIN" echo '{"session_id":"s1"}' | BRAIN_DIR="$BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "no audit-log should be silent (got: $out)"
pass "no audit-log → silent"

# Test 2: empty session_id → silent
echo '' > "$BRAIN/audit-log.jsonl"
log_entry "other" "ask" "rule-a"
out=$(BRAIN_DIR="$BRAIN" echo '{}' | BRAIN_DIR="$BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "missing session_id should be silent (got: $out)"
pass "missing session_id → silent"

# Test 3: no entries for this session → silent
out=$(BRAIN_DIR="$BRAIN" echo '{"session_id":"s1"}' | BRAIN_DIR="$BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "no matching entries should be silent (got: $out)"
pass "no matching entries → silent"

# Test 4: entries for session → emit systemMessage with SAR banner
log_entry "s1" "allow" "anonymous"
log_entry "s1" "allow" "anonymous"
log_entry "s1" "ask" "warn-rm-rf"
log_entry "s1" "flag" "injection:system-tag"
out=$(BRAIN_DIR="$BRAIN" echo '{"session_id":"s1"}' | BRAIN_DIR="$BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.systemMessage' >/dev/null \
  || fail "should emit systemMessage (got: $out)"
echo "$out" | jq -r '.systemMessage' | grep -q 'SAR' \
  || fail "systemMessage should contain 'SAR' (got: $out)"
echo "$out" | jq -r '.systemMessage' | grep -q 'allow=2' \
  || fail "systemMessage should report allow=2 (got: $out)"
echo "$out" | jq -r '.systemMessage' | grep -q 'ask=1' \
  || fail "systemMessage should report ask=1 (got: $out)"
echo "$out" | jq -r '.systemMessage' | grep -q 'flag=1' \
  || fail "systemMessage should report flag=1 (got: $out)"
pass "session entries → SAR banner emitted"

# Test 5: SAR value is computed correctly
# allow=2, ask=1, deny=0, flag=1, rewrite=0; total=4
# hard violations = ask+deny = 1; sar = 1 - 1/4 = 0.75
echo "$out" | jq -r '.systemMessage' | grep -q 'sar=0.75' \
  || fail "sar should equal 0.75 for 2 allow / 1 ask / 1 flag (got: $(echo "$out" | jq -r '.systemMessage' | grep -o 'sar=[^ ]*'))"
pass "SAR computed: 2 allow / 1 ask / 1 flag → 0.75"

# Test 6: only this session's entries are counted (cross-session isolation)
# Wipe + seed: s1 has 1 allow, s2 has 5 deny
echo '' > "$BRAIN/audit-log.jsonl"
log_entry "s1" "allow" "ok"
for i in 1 2 3 4 5; do log_entry "s2" "deny" "bad"; done
out=$(BRAIN_DIR="$BRAIN" echo '{"session_id":"s1"}' | BRAIN_DIR="$BRAIN" bash "$SCRIPT")
echo "$out" | jq -r '.systemMessage' | grep -q 'allow=1' \
  || fail "cross-session: s1 should report allow=1 (got: $out)"
echo "$out" | jq -r '.systemMessage' | grep -qv 'deny=5' \
  || fail "cross-session: s1 should NOT pick up s2's deny entries (got: $out)"
pass "cross-session isolation by session_id"

# Test 7: SB_SAR_SUMMARY=off kill switch
out=$(SB_SAR_SUMMARY=off BRAIN_DIR="$BRAIN" echo '{"session_id":"s1"}' \
  | SB_SAR_SUMMARY=off BRAIN_DIR="$BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "SB_SAR_SUMMARY=off should suppress output (got: $out)"
pass "SB_SAR_SUMMARY=off kill switch honored"

# Test 8: rewrite verdicts count as allows for SAR purposes (auto-corrected)
echo '' > "$BRAIN/audit-log.jsonl"
log_entry "s3" "rewrite" "strip-silent-fallback"
log_entry "s3" "rewrite" "strip-silent-fallback"
out=$(BRAIN_DIR="$BRAIN" echo '{"session_id":"s3"}' | BRAIN_DIR="$BRAIN" bash "$SCRIPT")
echo "$out" | jq -r '.systemMessage' | grep -q 'rewrite=2' \
  || fail "rewrite verdicts should be reported (got: $out)"
echo "$out" | jq -r '.systemMessage' | grep -q 'sar=1.00' \
  || fail "all-rewrite session should have sar=1.00 (got: $out)"
pass "rewrites count as allows (sar=1.00)"

# Test 9: all-deny session → sar=0.00
echo '' > "$BRAIN/audit-log.jsonl"
log_entry "s4" "deny" "warn-rm-rf"
log_entry "s4" "deny" "warn-rm-rf"
out=$(BRAIN_DIR="$BRAIN" echo '{"session_id":"s4"}' | BRAIN_DIR="$BRAIN" bash "$SCRIPT")
echo "$out" | jq -r '.systemMessage' | grep -q 'sar=0.00' \
  || fail "all-deny session should have sar=0.00 (got: $out)"
pass "all-deny session → sar=0.00"

# Test 10: malformed stdin → silent, no crash
out=$(BRAIN_DIR="$BRAIN" echo 'not json' | BRAIN_DIR="$BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "malformed stdin should be silent (got: $out)"
pass "malformed stdin → silent (fail-soft)"

# Test 11: audit-log rotation is triggered when entries exceed the cap.
# Seed > SB_AUDIT_MAX_LINES (5000) entries, run sar-summary, expect the
# audit-log to have been pruned to roughly half.
echo '' > "$BRAIN/audit-log.jsonl"
for i in $(seq 1 5100); do
  printf '{"ts":"2026-05-21T00:00:00Z","hook":"x","verdict":"allow","rule":"r","target":"t","reason":"r","session_id":"rot","extra":{}}\n' \
    >> "$BRAIN/audit-log.jsonl"
done
before=$(wc -l < "$BRAIN/audit-log.jsonl" | tr -d ' ')
BRAIN_DIR="$BRAIN" echo '{"session_id":"rot"}' | BRAIN_DIR="$BRAIN" bash "$SCRIPT" >/dev/null
after=$(wc -l < "$BRAIN/audit-log.jsonl" | tr -d ' ')
[ "$before" -gt 5000 ] || fail "rotation test: seed should exceed 5000 (got $before)"
[ "$after" -lt 5000 ] || fail "rotation should have pruned to <5000 lines (before=$before after=$after)"
pass "audit-log rotation fires from Stop hook (before=$before after=$after)"

# Test 12: corrupted lines in audit-log don't crash the summary.
echo '' > "$BRAIN/audit-log.jsonl"
log_entry "s12" "allow" "ok"
echo 'this is not json' >> "$BRAIN/audit-log.jsonl"
echo '{"ts":"x","hook":' >> "$BRAIN/audit-log.jsonl"
log_entry "s12" "ask" "rule-x"
out=$(BRAIN_DIR="$BRAIN" echo '{"session_id":"s12"}' | BRAIN_DIR="$BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.systemMessage' >/dev/null \
  || fail "corrupted audit-log should still produce a banner (got: $out)"
echo "$out" | jq -r '.systemMessage' | grep -q 'allow=1' \
  || fail "corruption-resilient parse should still see allow=1 (got: $out)"
pass "corrupted audit-log lines tolerated"

echo
echo "ALL PASS"
