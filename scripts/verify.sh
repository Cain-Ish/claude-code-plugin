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
# Note: verify.sh's main path does not call sb_log_error directly — appending
# to error-log.jsonl would create a feedback loop with check #5 below (which
# reads that file). The only indirect path is via sb_require_jq when jq is
# missing, which is a real error worth logging and benign here: with jq
# missing the freshness check can't run anyway, so the entry surfaces on the
# next run as a real failure rather than self-flagging noise.
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
elif ! grep -q '^## Intent$' "$USER_FILE"; then
  FAILS+=("verify: FAIL: USER.md — missing '## Intent' section (run migrate-to-1.2.0.sh or /second-brain:upgrade)")
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

# Check 4: MCP dist artifact exists. The runtime launches the BUNDLE
# (mcp.json → dist/server.bundle.js); the per-file tsc output is no longer
# tracked (build hygiene, 0.26.0), so probe the bundle that actually runs.
MCP_DIST="$PLUGIN_ROOT/mcp/dist/server.bundle.js"
if [ ! -f "$MCP_DIST" ]; then
  FAILS+=("verify: FAIL: mcp — dist/server.bundle.js missing at $MCP_DIST (run /second-brain:setup)")
fi

# Check 4b: knowledge wiki dir exists.
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
WIKI_DIR="$KNOWLEDGE_DIR/wiki"
if [ ! -d "$WIKI_DIR" ]; then
  FAILS+=("verify: FAIL: wiki — directory missing at $WIKI_DIR (run /second-brain:setup)")
fi

# Check 4c: wiki index.md exists.
WIKI_INDEX="$WIKI_DIR/index.md"
if [ -d "$WIKI_DIR" ] && [ ! -f "$WIKI_INDEX" ]; then
  WIKI_COUNT=$(find "$WIKI_DIR" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$WIKI_COUNT" -gt 0 ]; then
    FAILS+=("verify: FAIL: index.md — missing but $WIKI_COUNT wiki pages exist (run knowledge_reindex MCP tool)")
  fi
fi

# Check 5b: stale or unreviewed dreams
DREAMS_DIR="$BRAIN_DIR/dreams"
if [ -d "$DREAMS_DIR" ]; then
  for sf in "$DREAMS_DIR"/drm_*/status.json; do
    [ -f "$sf" ] || continue
    DSTATUS=$(jq -r '.status' "$sf" 2>/dev/null | tr -d '\r')
    DID=$(jq -r '.id' "$sf" 2>/dev/null | tr -d '\r')
    if [ "$DSTATUS" = "running" ]; then
      STARTED=$(jq -r '.started_at // ""' "$sf" 2>/dev/null | tr -d '\r')
      if [ -n "$STARTED" ] && [ "$STARTED" != "null" ]; then
        STARTED_DATE=$(echo "$STARTED" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | tr -d '\r' || echo "")
        TODAY=$(date -u +%Y-%m-%d)
        if [ -n "$STARTED_DATE" ] && [ "$STARTED_DATE" \< "$TODAY" ]; then
          FAILS+=("verify: FAIL: dream — $DID still running (started $STARTED), may be stale")
        fi
      fi
    elif [ "$DSTATUS" = "completed" ]; then
      ENDED=$(jq -r '.ended_at // ""' "$sf" 2>/dev/null)
      ARCHIVED=$(jq -r '.archived_at // ""' "$sf" 2>/dev/null | tr -d '\r')
      if [ "$ARCHIVED" = "null" ] || [ -z "$ARCHIVED" ]; then
        FAILS+=("verify: FAIL: dream — $DID completed but not reviewed (ended $ENDED)")
      fi
    fi
  done
fi

# Check 5: error-log freshness vs .last-verify
ERR_LOG="$BRAIN_DIR/error-log.jsonl"
LAST_VERIFY="$BRAIN_DIR/.last-verify"
# `-s` (size>0) instead of `-f` (exists): an empty file is the normal post-
# clear state (`: > error-log.jsonl`) and has nothing to validate. The old
# `-f` + `jq -e '.'` pair tripped `jq` on the empty file and reported a
# spurious "malformed JSON" — confused users into thinking their cleared
# log was corrupt. Verified by tests/test-verify.sh subtest 9b.
if [ -s "$ERR_LOG" ] && [ -f "$LAST_VERIFY" ]; then
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
