#!/bin/bash
# session-load surfaces a raw-inbox backlog banner for the active project, gated by SB_RAW_INBOX.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

grep -q 'SB_RAW_INBOX' "$SL" || fail "session-load.sh has no SB_RAW_INBOX gate"
grep -q 'raw-inbox-banner' "$SL" || fail "session-load.sh has no raw-inbox banner block"
pass "session-load references the raw-inbox banner + kill switch"

# Prove the documented count expression counts unprocessed items.
T=$(mktemp -d); RAW="$T/projects/demo/raw"; mkdir -p "$RAW"
mk(){ printf -- '---\nstatus: %s\n---\nx\n' "$1" > "$RAW/$2.md"; }
mk unprocessed a; mk unprocessed b; mk discarded c
N=$(grep -rl '^status: unprocessed$' "$RAW" 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = "2" ] || fail "expected the banner count expression to yield 2 (got $N)"
pass "the banner count expression counts unprocessed items (2)"
rm -rf "$T"
echo; echo "ALL PASS"
