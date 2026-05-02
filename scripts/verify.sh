#!/bin/bash
# Runtime smoke check for second-brain. Complements the static
# scripts/validate-plugin.sh with live-state assertions.
# Exit 0 = all checks pass, exit 1 = at least one check failed.
# Output: 'verify: ok' on success, 'verify: FAIL: <check> — <detail>' lines on failure.
#
# First-run note: if .last-verify does not exist, the error-log freshness
# check is skipped and a fresh timestamp is written on success. Subsequent
# runs flag only entries newer than the recorded timestamp.
set -u
# Note: this script writes only to stdout. It deliberately does NOT call
# sb_log_error — appending to error-log.jsonl would create a feedback loop
# with check #5 below (which reads that file).
source "$(dirname "$0")/lib.sh"

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LINE_CAP=66
FAILS=()

SLUG=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")

# Check 1: USER.md exists and non-empty
USER_FILE="$BRAIN_DIR/USER.md"
if [ ! -f "$USER_FILE" ]; then
  FAILS+=("verify: FAIL: USER.md — file missing at $USER_FILE")
elif [ ! -s "$USER_FILE" ]; then
  FAILS+=("verify: FAIL: USER.md — file empty at $USER_FILE")
fi

# Check 2: active project's PROJECT.md exists
PROJECT_FILE="$BRAIN_DIR/projects/$SLUG/PROJECT.md"
if [ ! -f "$PROJECT_FILE" ]; then
  FAILS+=("verify: FAIL: PROJECT.md — missing for active slug '$SLUG' at $PROJECT_FILE")
fi

# Check 3: hot tier under line cap
U_LINES=0
P_LINES=0
[ -f "$USER_FILE" ] && U_LINES=$(wc -l < "$USER_FILE" | tr -d ' ')
[ -f "$PROJECT_FILE" ] && P_LINES=$(wc -l < "$PROJECT_FILE" | tr -d ' ')
TOTAL=$((U_LINES + P_LINES))
if [ "$TOTAL" -gt "$LINE_CAP" ]; then
  FAILS+=("verify: FAIL: hot tier — line count $TOTAL exceeds line cap $LINE_CAP")
fi

# Check 4: MCP dist artifact exists
MCP_DIST="$PLUGIN_ROOT/mcp/dist/server.js"
if [ ! -f "$MCP_DIST" ]; then
  FAILS+=("verify: FAIL: mcp — dist/server.js missing at $MCP_DIST (run /second-brain:setup)")
fi

# Check 5: error-log freshness vs .last-verify
ERR_LOG="$BRAIN_DIR/error-log.jsonl"
LAST_VERIFY="$BRAIN_DIR/.last-verify"
if [ -f "$ERR_LOG" ] && [ -f "$LAST_VERIFY" ]; then
  LAST_TS=$(head -1 "$LAST_VERIFY" | tr -d '[:space:]')
  if [ -n "$LAST_TS" ]; then
    if ! sb_require_jq; then
      FAILS+=("verify: FAIL: error-log — jq required for freshness check")
    else
      # Pre-validate the JSONL is parseable. jq's default mode reads
      # whitespace-separated JSON values; -e flips exit on null/false.
      # On any malformed line jq exits non-zero and we surface that as a
      # distinct check failure — never swallow corrupt error-log silently.
      if ! jq -e '.' "$ERR_LOG" >/dev/null; then
        FAILS+=("verify: FAIL: error-log — malformed JSON in $ERR_LOG")
      else
        NEW_COUNT=$(jq -r --arg t "$LAST_TS" 'select(.timestamp > $t) | .timestamp' "$ERR_LOG" | wc -l | tr -d ' ')
        if [ "$NEW_COUNT" -gt 0 ]; then
          FAILS+=("verify: FAIL: error-log — $NEW_COUNT new entries since $LAST_TS")
        fi
      fi
    fi
  fi
fi

# Emit results and update .last-verify timestamp on success
if [ ${#FAILS[@]} -eq 0 ]; then
  echo "verify: ok"
  mkdir -p "$BRAIN_DIR"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$LAST_VERIFY"
  exit 0
else
  for line in "${FAILS[@]}"; do
    echo "$line"
  done
  exit 1
fi
