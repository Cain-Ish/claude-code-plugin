#!/bin/bash
# Auth-aware SessionStart capture self-check (U5 0.24.18 + SP-1 0.24.19).
#  - API key  → extraction runs IN-SESSION at every Stop (Backend 2 curl); the
#    out-of-band drainer is NOT needed → no "install the bridge" nag.
#  - OAuth    → in-session is recursive-locked → needs drainer/local/key → nag WITH all 3 options.
#  - none     → the auth-mode-line already covers it → no double-nag here.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
# $1 = brain dir, $2 = ANTHROPIC_API_KEY value ("" = OAuth, given `claude` is on PATH here)
emit(){ printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' | env ANTHROPIC_API_KEY="$2" BRAIN_DIR="$1" bash "$SL" 2>/dev/null; }

B=$(mktemp -d); mkdir -p "$B/transcripts"; : > "$B/transcripts/s1.txt"; : > "$B/USER.md"   # transcripts, none drained, no timer

# 1. OAuth (no key) → SHOUT + offer all three paths
oauth=$(emit "$B" "")
echo "$oauth" | grep -qi 'capture not running' || fail "OAuth: no capture-not-running banner (got: $(echo "$oauth" | head -c 200))"
pass "OAuth: shouts capture not running"
# anchor to a banner-UNIQUE string (the auth-mode-line also mentions ANTHROPIC_API_KEY)
echo "$oauth" | grep -q 'instant in-session capture' || fail "OAuth capture banner must offer the API-key path (unique string)"
echo "$oauth" | grep -q 'install-extract-timer.sh' || fail "OAuth banner must offer the drainer path"
pass "OAuth banner offers API-key + drainer (+ local) options"

# 2. API key set → NEVER the drainer-install nag (in-session needs no drainer)
apikey=$(emit "$B" "sk-ant-test")
echo "$apikey" | grep -q 'install-extract-timer' && fail "API-key user wrongly told to install the drainer (in-session capture needs none)" || pass "API-key: no drainer-install nag"
# 2b. but a genuine silent failure (transcripts piling up, nothing extracted) is still surfaced
echo "$apikey" | grep -qiE 'no extraction recorded|extraction failing' || fail "API-key with 0 extraction should still warn (the silent-failure gap)"
pass "API-key: surfaces a real silent failure (without the drainer nag)"

# 3. kill switch
SB_CAPTURE_HEALTH_BANNER=off emit "$B" "" | grep -qi 'capture not running' && fail "kill switch did not suppress" || pass "SB_CAPTURE_HEALTH_BANNER=off suppresses"

# 4. no transcripts → silent (fresh install isn't nagged)
B2=$(mktemp -d); : > "$B2/USER.md"
emit "$B2" "" | grep -qi 'capture not running' && fail "nagged a fresh install (no transcripts)" || pass "silent on fresh install"

rm -rf "$B" "$B2"; echo; echo "ALL PASS"
