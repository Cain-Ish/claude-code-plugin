#!/bin/bash
# Validate an improve proposal against the friction log.
# Ensures cited evidence actually exists and criteria are met.
# Exit 0 = proposal is valid, exit 1 = rejected.

BRAIN_DIR="$HOME/.second-brain"
PROPOSAL="$BRAIN_DIR/.improve-proposal.json"
FRICTION_LOG="$BRAIN_DIR/friction-log.jsonl"
ERRORS=0

if [ ! -f "$PROPOSAL" ]; then
  echo "FAIL: no proposal file at $PROPOSAL"
  exit 1
fi

if ! jq empty "$PROPOSAL" 2>/dev/null; then
  echo "FAIL: proposal is not valid JSON"
  exit 1
fi

# Check required top-level fields
for field in title description evidence changes; do
  if ! jq -e ".$field" "$PROPOSAL" >/dev/null 2>&1; then
    echo "FAIL: proposal missing required field '$field'"
    ERRORS=$((ERRORS + 1))
  fi
done

if [ $ERRORS -gt 0 ]; then
  echo "TOTAL: $ERRORS structural error(s)"
  exit 1
fi

# Validate evidence array is non-empty
EVIDENCE_COUNT=$(jq '.evidence | length' "$PROPOSAL" 2>/dev/null)
if [ "$EVIDENCE_COUNT" -lt 1 ]; then
  echo "FAIL: proposal has no evidence entries — every improvement must cite friction signals"
  exit 1
fi

# Validate each evidence entry has required fields and exists in friction log.
# Also collect distinct sessions/timestamps so we can require independent evidence
# (not the same incident cited twice).
VERIFIED=0
DISTINCT_SESSIONS=$(jq -r '[.evidence[] | .session_id] | map(select(. != null and . != "")) | unique | length' "$PROPOSAL" 2>/dev/null)
DISTINCT_TIMESTAMPS=$(jq -r '[.evidence[] | .timestamp] | map(select(. != null and . != "")) | unique | length' "$PROPOSAL" 2>/dev/null)
DISTINCT_SESSIONS=${DISTINCT_SESSIONS:-0}
DISTINCT_TIMESTAMPS=${DISTINCT_TIMESTAMPS:-0}

for i in $(seq 0 $((EVIDENCE_COUNT - 1))); do
  TYPE=$(jq -r ".evidence[$i].type // \"\"" "$PROPOSAL")
  TIMESTAMP=$(jq -r ".evidence[$i].timestamp // \"\"" "$PROPOSAL")
  SESSION=$(jq -r ".evidence[$i].session_id // \"\"" "$PROPOSAL")

  if [ -z "$TYPE" ] || [ -z "$TIMESTAMP" ]; then
    echo "FAIL: evidence[$i] missing type or timestamp"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Verify this evidence exists in friction log via structured field match
  if [ -f "$FRICTION_LOG" ]; then
    if jq -se --arg t "$TIMESTAMP" 'any(.[]; .timestamp == $t)' "$FRICTION_LOG" >/dev/null 2>&1; then
      VERIFIED=$((VERIFIED + 1))
    else
      echo "WARN: evidence[$i] timestamp '$TIMESTAMP' not found in friction log — may be from learnings.md"
    fi
  fi
done

# Check recurrence: need 2+ evidence entries from distinct sessions OR distinct timestamps
if [ "$EVIDENCE_COUNT" -lt 2 ]; then
  echo "FAIL: only $EVIDENCE_COUNT evidence entry — need 2+ to prove recurrence"
  ERRORS=$((ERRORS + 1))
elif [ "$DISTINCT_SESSIONS" -lt 2 ] && [ "$DISTINCT_TIMESTAMPS" -lt 2 ]; then
  echo "FAIL: evidence entries are not independent — need 2+ distinct sessions or distinct timestamps (got $DISTINCT_SESSIONS sessions, $DISTINCT_TIMESTAMPS timestamps)"
  ERRORS=$((ERRORS + 1))
fi

# Check changes array is non-empty
CHANGES_COUNT=$(jq '.changes | length' "$PROPOSAL" 2>/dev/null)
if [ "$CHANGES_COUNT" -lt 1 ]; then
  echo "FAIL: proposal has no changes listed"
  ERRORS=$((ERRORS + 1))
fi

# Validate each change targets a file inside the plugin.
# Normalize paths so backslashes/forward-slashes both work on Windows + Unix.
# Uses `tr` for the lowercase step so this works on BSD sed (macOS) too —
# `\L` in sed is GNU-only.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
norm_path() {
  local p="$1"
  p="${p//\\//}"        # backslashes → forward slashes
  p="${p%/}"            # strip trailing slash
  case "$p" in
    [A-Za-z]:*)
      local drive rest
      drive=$(printf '%s' "${p:0:1}" | tr '[:upper:]' '[:lower:]')
      rest="${p:1}"
      printf '%s%s' "$drive" "$rest"
      ;;
    *) printf '%s' "$p" ;;
  esac
}
PLUGIN_ROOT_NORM=$(norm_path "$PLUGIN_ROOT")

for i in $(seq 0 $((CHANGES_COUNT - 1))); do
  FILE=$(jq -r ".changes[$i].file // \"\"" "$PROPOSAL")
  ACTION=$(jq -r ".changes[$i].action // \"\"" "$PROPOSAL")

  if [ -z "$FILE" ] || [ -z "$ACTION" ]; then
    echo "FAIL: changes[$i] missing file or action"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Block changes outside plugin root (normalized comparison)
  FILE_NORM=$(norm_path "$FILE")
  case "$FILE_NORM" in
    "$PLUGIN_ROOT_NORM"/*|"$PLUGIN_ROOT_NORM") ;;
    *)
      echo "FAIL: changes[$i] targets '$FILE' which is outside plugin root"
      ERRORS=$((ERRORS + 1))
      ;;
  esac

  # Block changes to plugin.json version
  if echo "$FILE" | grep -q "plugin.json"; then
    if [ "$ACTION" = "version" ] || jq -e ".changes[$i].description | test(\"version\")" "$PROPOSAL" >/dev/null 2>&1; then
      echo "FAIL: changes[$i] attempts to modify plugin version — not allowed"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

if [ $ERRORS -eq 0 ]; then
  echo "OK: proposal valid — $EVIDENCE_COUNT evidence entries ($VERIFIED verified in friction log), $CHANGES_COUNT changes"
  exit 0
else
  echo "TOTAL: $ERRORS error(s) — proposal rejected"
  exit 1
fi
