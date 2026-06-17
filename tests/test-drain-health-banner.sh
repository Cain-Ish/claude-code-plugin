#!/bin/bash
# Out-of-band DRAINER health banner (Phase 1 task 5, root cause #2: silent failure).
# ORACLE: crafted error-log.jsonl / .extraction-state.jsonl / quarantine fixtures with
# KNOWN counts → assert the banner fires/omits and the OS-aware remedy matches uname -s.
# We assert against session-load.sh's emitted stdout, never by re-calling the helper.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

B=$(mktemp -d); trap 'rm -rf "$B"' EXIT
export HOME="$B"
# Defensively disable the maintain/dream cascade — a hook test must never spawn.
printf '{"auto_improve": false, "auto_maintain": false}\n' > "$B/config.json"
BANNER='background extraction is failing silently'

emit(){ printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' | env BRAIN_DIR="$B" HOME="$B" bash "$SL" 2>/dev/null; }
reset(){ rm -f "$B/error-log.jsonl" "$B/.extraction-state.jsonl" "$B/.llm-maintain-quarantine"; }
ec124(){ local n="$1" i; : > "$B/error-log.jsonl"
  for i in $(seq 1 "$n"); do
    printf '{"ts":"2026-06-17T13:0%s:00Z","script":"extract-drain.sh","level":"TRACE","message":"extractor-diag stage=direct ec=124 out=0 cc=0 ak=0 pty=no"}\n' "$i" >> "$B/error-log.jsonl"
  done; }

echo "=== drain-health banner ==="

# 1: >=3 ec=124 timeouts → banner fires
reset; ec124 4
O=$(emit)
printf '%s' "$O" | grep -q "$BANNER" && pass "1: >=3 ec=124 timeouts fire the banner" || fail "1: banner did not fire on timeouts"

# 2: no signal → no banner
reset
O=$(emit)
printf '%s' "$O" | grep -q "$BANNER" && fail "2: banner fired with no signal" || pass "2: no signal → no banner"

# 3: quarantine ALONE → drain-health banner does NOT fire (dream-autostage owns it)
reset; printf '[2026-06-11T00:00:00Z] quarantined: bwrap preflight failed\n' > "$B/.llm-maintain-quarantine"
O=$(emit)
printf '%s' "$O" | grep -q "$BANNER" && fail "3: drain-health double-fired on quarantine" || pass "3: quarantine-alone does NOT fire drain-health (no double-banner)"

# 4: >=5 poison-pilled transcripts → banner fires
reset; : > "$B/.extraction-state.jsonl"
for i in 1 2 3 4 5 6; do printf '{"basename":"s%s.txt","outcome":"error"}\n' "$i" >> "$B/.extraction-state.jsonl"; done
O=$(emit)
printf '%s' "$O" | grep -q "$BANNER" && pass "4: >=5 dead-letter transcripts fire the banner" || fail "4: dead-letter banner did not fire"

# 5: kill switch suppresses
reset; ec124 4
O=$(SB_DRAIN_HEALTH_BANNER=off emit)
printf '%s' "$O" | grep -q "$BANNER" && fail "5: kill switch did not suppress" || pass "5: SB_DRAIN_HEALTH_BANNER=off suppresses"

# 6: OS-aware remedy
reset; ec124 4
O=$(emit)
if [ "$(uname -s)" = "Linux" ]; then
  printf '%s' "$O" | grep -q 'SB_DRAIN_EXTRACT_TIMEOUT' && pass "6: Linux remedy names the timeout knob" || fail "6: Linux remedy missing the timeout knob"
else
  printf '%s' "$O" | grep -q 'second-brain:maintain' && pass "6: non-Linux remedy points to in-session maintain" || fail "6: non-Linux remedy missing"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
