#!/bin/bash
# session-load surfaces a raw-inbox backlog banner for the active project, gated by SB_RAW_INBOX.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

grep -q 'SB_RAW_INBOX' "$SL" || fail "session-load.sh has no SB_RAW_INBOX gate"
grep -q 'raw-inbox-banner' "$SL" || fail "session-load.sh has no raw-inbox banner block"
pass "session-load references the raw-inbox banner + kill switch"

# Prove the banner count expression = open backlog (unprocessed + malformed; excludes processed/discarded),
# matching the module's unprocessedCount.
T=$(mktemp -d); RAW="$T/projects/demo/raw"; mkdir -p "$RAW"
mk(){ printf -- '---\nstatus: %s\n---\nx\n' "$1" > "$RAW/$2.md"; }
mk unprocessed a; mk unprocessed b; mk discarded c; mk processed d
printf 'no frontmatter\n' > "$RAW/broken.md"   # malformed → counts as open
RAW_TOTAL=$(find "$RAW" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
RAW_CLOSED=$(grep -rlE '^status: (processed|discarded)$' "$RAW" 2>/dev/null | wc -l | tr -d ' ')
N=$(( RAW_TOTAL - RAW_CLOSED ))
[ "$N" = "3" ] || fail "expected open=3 (a,b unprocessed + broken malformed; c,d closed), got $N"
pass "the banner count = open backlog incl. malformed (3)"
rm -rf "$T"
echo; echo "ALL PASS"
