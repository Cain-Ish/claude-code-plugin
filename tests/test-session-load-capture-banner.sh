#!/bin/bash
# U5: SessionStart capture-health self-check — the "wired != works" guard.
# Shouts when transcripts exist but the drainer never turned them into deltas.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
emit(){ printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' | BRAIN_DIR="$1" bash "$SL" 2>/dev/null; }

# A: transcripts archived but none extracted + no timer → must SHOUT
B=$(mktemp -d); mkdir -p "$B/transcripts"; : > "$B/transcripts/s1.txt"; : > "$B/USER.md"
out=$(emit "$B")
echo "$out" | grep -qi 'capture not running' || fail "no 'capture not running' banner when transcripts undrained (got: $(echo "$out" | head -c 300))"
pass "shouts when transcripts archived but nothing extracted"
echo "$out" | grep -q 'install-extract-timer.sh --apply' || fail "banner missing the one-command fix"
pass "banner gives the install command"

# B: kill switch suppresses
SB_CAPTURE_HEALTH_BANNER=off emit "$B" | grep -qi 'capture not running' && fail "SB_CAPTURE_HEALTH_BANNER=off did not suppress" || true
pass "SB_CAPTURE_HEALTH_BANNER=off suppresses"

# C: no transcripts at all → no banner (fresh install isn't nagged)
B2=$(mktemp -d); : > "$B2/USER.md"
emit "$B2" | grep -qi 'capture not running' && fail "nagged a fresh install with no transcripts" || true
pass "silent when there are no transcripts (fresh install)"

rm -rf "$B" "$B2"
echo; echo "ALL PASS"
