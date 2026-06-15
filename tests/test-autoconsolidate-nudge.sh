#!/bin/bash
# B1 (SP-B): the self-install nudge. Fires when auto_improve is OFF and the raw inbox is
# genuinely piling up (>= SB_NUDGE_RAW_THRESHOLD); mutually exclusive with the plain
# raw-inbox banner; suppressed when auto_improve is on or the kill switch is set.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

B=$(mktemp -d); SLUG=demo
RAW="$B/projects/$SLUG/raw"; mkdir -p "$RAW"; : > "$B/USER.md"; : > "$B/projects.jsonl"
WORK="$B/work/$SLUG"; mkdir -p "$WORK"                          # cwd basename → slug=demo
seed(){ rm -f "$RAW"/*.md; local i; for i in $(seq 1 "$1"); do printf -- '---\nstatus: unprocessed\n---\nx\n' > "$RAW/item$i.md"; done; }
# emit: $1 = config.json body ("" = none), $2... = extra env; cwd=demo so slug resolves.
emit(){ local cfg="$1"; shift; [ -n "$cfg" ] && printf '%s' "$cfg" > "$B/config.json" || rm -f "$B/config.json"
        ( cd "$WORK" && env BRAIN_DIR="$B" SB_NUDGE_RAW_THRESHOLD=5 "$@" bash "$SL" 2>/dev/null ); }

# 1. auto OFF (EXPLICIT — 0.30.0 made absent default to ON) + 6 raw (>= thresh 5) → the
#    NUDGE, mutually exclusive with the plain banner
seed 6; out=$(emit '{"auto_improve": false}')
echo "$out" | grep -q 'auto-consolidation is off' || fail "nudge did not fire (auto off + 6 raw). got: $(echo "$out" | grep -i 'raw\|consolidat' | head -c 160)"
echo "$out" | grep -q 'raw inbox —' && fail "plain raw-inbox banner ALSO fired (not mutually exclusive)" || pass "auto off + overdue → nudge only"
{ echo "$out" | grep -q 'auto_improve: true' && echo "$out" | grep -q '/second-brain:maintain'; } && pass "nudge offers both remedies" || fail "nudge missing a remedy"

# 2. below threshold (3 < 5) → the plain raw-inbox banner, NOT the nudge
seed 3; out=$(emit "")
echo "$out" | grep -q 'raw inbox —' || fail "plain banner missing for sub-threshold backlog"
echo "$out" | grep -q 'auto-consolidation is off' && fail "nudge fired below threshold" || pass "below threshold → plain banner, no nudge"

# 3. auto_improve:true → nudge suppressed (user opted in)
seed 6; out=$(emit '{"auto_improve": true}')
echo "$out" | grep -q 'auto-consolidation is off' && fail "nudge fired even though auto_improve=true" || pass "auto_improve on → nudge suppressed"

# 4. kill switch
seed 6; out=$(emit "" SB_AUTOCONSOLIDATE_NUDGE=off)
echo "$out" | grep -q 'auto-consolidation is off' && fail "kill switch did not suppress the nudge" || pass "SB_AUTOCONSOLIDATE_NUDGE=off suppresses"

rm -rf "$B"; echo; echo "ALL PASS"
