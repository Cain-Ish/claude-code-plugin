#!/bin/bash
# Phase 1.2 — sb_extract_transcript must pass the drainer-dedicated timeout to the
# extractor, defaulting to 240s (slow-HW headroom) and honoring SB_DRAIN_EXTRACT_TIMEOUT.
# ORACLE: override sb_call_extractor with a stub that records the 5th positional arg
# (timeout_s) it actually receives to a probe file, and assert against that recorded
# value — never by re-reading the source literal. The stub spawns NOTHING.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL SB_DRAIN_EXTRACT_TIMEOUT 2>/dev/null || true
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"
export BRAIN_DIR="$SANDBOX/brain"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SANDBOX/knowledge"
mkdir -p "$BRAIN_DIR/transcripts"
PROBE="$SANDBOX/timeout.probe"
TX="$BRAIN_DIR/transcripts/sess.txt"
printf 'slug: proj\n---\nsome transcript body content for the extractor\n' > "$TX"

# shellcheck source=/dev/null
source "$ROOT/scripts/lib.sh"
# Override the extractor: record the timeout arg ($5), spawn NOTHING, return 1 so
# sb_extract_transcript stops before the merge (we only need the value it passed).
sb_call_extractor() { printf '%s' "${5:-MISSING}" > "$PROBE"; return 1; }

echo "=== sb_extract_transcript drainer timeout ==="

# A: default → 240
rm -f "$PROBE"
sb_extract_transcript "$TX" "proj" >/dev/null 2>&1 || true
[ "$(cat "$PROBE" 2>/dev/null)" = "240" ] && pass "A: default drainer timeout is 240s" || fail "A: default not 240 (got '$(cat "$PROBE" 2>/dev/null)')"

# A2: env override honored (not frozen to the default)
rm -f "$PROBE"
SB_DRAIN_EXTRACT_TIMEOUT=99 sb_extract_transcript "$TX" "proj" >/dev/null 2>&1 || true
[ "$(cat "$PROBE" 2>/dev/null)" = "99" ] && pass "A2: SB_DRAIN_EXTRACT_TIMEOUT override honored" || fail "A2: override not honored (got '$(cat "$PROBE" 2>/dev/null)')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
