#!/bin/bash
# Stop-hook orchestrator (v1.2.0). Reads the Stop hook payload, decides
# whether the session was substantive enough to extract from, calls the
# `claude` CLI as a subprocess to produce a structured JSON delta, and
# pipes that delta into merge-project-update.sh.
#
# Replaces the older run-stop-predicate.sh entry that only wrote a flag
# file nobody read. The baseline-vs-current PROJECT.md predicate is no
# longer the gate (PROJECT.md only changes if extraction ran, so it's
# circular). The new gate is "transcript has at least one tool_use" —
# pure Q&A sessions skip the LLM call.
#
# Always exits 0 (fail-soft). A crash in this hook must never block
# Claude's stop event.
#
# Honors env overrides:
#   SB_EXTRACTOR_MODEL — model passed via `claude -p --model <id>`
#                        (default: claude-sonnet-4-6)
#   SB_EXTRACT_TIMEOUT — seconds to wait for `claude` (default: 25)
set -u

# Defensive lib.sh source. If lib.sh is missing the script would crash on
# first $BRAIN_DIR reference under `set -u` and leave no trace. Without
# sb_log_error available we fall back to a raw append so the failure is
# at least diagnosable.
LIB="$(dirname "$0")/lib.sh"
if ! source "$LIB" 2>/dev/null; then
  printf '{"timestamp":"%s","script":"stop-extract.sh","message":"lib.sh source failed: %s","exit_code":0}\n' \
    "$(date -u +%FT%TZ)" "$LIB" >> "$HOME/.second-brain/error-log.jsonl" 2>/dev/null
  exit 0
fi

# Hook trace tag — set by each gate before exit, written by EXIT trap. Lets
# the next /second-brain:status surface exactly which gate the script tripped.
SB_GATE=""
log_gate() { SB_GATE="$1"; }
trap '[ -n "$SB_GATE" ] && sb_log_error "stop-extract.sh" "gate=$SB_GATE" 0' EXIT

EXTRACTOR_MODEL="${SB_EXTRACTOR_MODEL:-claude-sonnet-4-6}"
EXTRACT_TIMEOUT="${SB_EXTRACT_TIMEOUT:-25}"

RAW=$(cat 2>/dev/null || true)
if [ -z "$RAW" ]; then log_gate "empty-stdin"; exit 0; fi

if ! echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  log_gate "stdin-not-json-object"
  exit 0
fi

TRANSCRIPT=$(echo "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')
CWD=$(echo       "$RAW" | jq -r '.cwd             // empty' 2>/dev/null | tr -d '\r')
if [ -z "$TRANSCRIPT" ]; then log_gate "transcript-path-empty cwd=$CWD"; exit 0; fi
if [ ! -f "$TRANSCRIPT" ]; then log_gate "transcript-file-missing path=$TRANSCRIPT"; exit 0; fi

if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  SLUG=$(sb_resolve_slug "$CWD")
else
  SLUG=$(sb_resolve_slug "$PWD")
fi
if [ -z "$SLUG" ]; then log_gate "slug-empty cwd=$CWD pwd=$PWD"; exit 0; fi

PROJECT_MD="$BRAIN_DIR/projects/$SLUG/PROJECT.md"
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
if [ ! -f "$PROJECT_MD" ]; then
  mkdir -p "$(dirname "$PROJECT_MD")"
  cat > "$PROJECT_MD" <<TMPL
# PROJECT: $SLUG

## Goal
(auto-scaffolded — describe this project's goal)

## State

## Plan

## Conventions

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ) -->
<!-- last_queried_wiki: -->
TMPL
fi
mkdir -p "$KNOWLEDGE_DIR/wiki" 2>/dev/null || true

# --- Determine unprocessed window (disjoint with pre-compact extractions) ---
LAST_LINE=$(sb_get_extraction_marker "$SLUG")
TOTAL_LINES=$(wc -l < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')
NEW_LINES=$((TOTAL_LINES - LAST_LINE))

if [ "$NEW_LINES" -lt 1 ]; then
  log_gate "no-new-lines marker=$LAST_LINE total=$TOTAL_LINES"
  sb_clear_extraction_marker "$SLUG"
  exit 0
fi

START_LINE=$((LAST_LINE + 1))
# Cap at 500 lines for the final window
if [ "$NEW_LINES" -gt 500 ]; then
  START_LINE=$((TOTAL_LINES - 500 + 1))
fi

# Substantive-session gate: count tool_use entries in the window.
TOOL_COUNT=$(sed -n "${START_LINE},${TOTAL_LINES}p" "$TRANSCRIPT" | jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use")
  | .name
' 2>/dev/null | wc -l | tr -d ' ')

if [ "${TOOL_COUNT:-0}" -lt 1 ]; then
  TS_LINES=$NEW_LINES
  TS_FIRST_TYPE=$(sed -n "${START_LINE}p" "$TRANSCRIPT" 2>/dev/null | jq -r '.type // "no-type"' 2>/dev/null | tr -d '\n')
  log_gate "tool-count-zero lines=$TS_LINES first-type=$TS_FIRST_TYPE marker=$LAST_LINE"
  sb_clear_extraction_marker "$SLUG"
  exit 0
fi

PROMPT_FILE="$(dirname "$0")/extract-prompt.txt"
if [ ! -f "$PROMPT_FILE" ]; then log_gate "prompt-file-missing path=$PROMPT_FILE"; exit 0; fi
PROMPT=$(cat "$PROMPT_FILE")

EXTRACT_INPUT=$(mktemp)
EXTRACT_OUT=$(mktemp)
trap 'rm -f "$EXTRACT_INPUT" "$EXTRACT_OUT" 2>/dev/null' EXIT
{
  echo "=== PROJECT.md ==="
  cat "$PROJECT_MD"
  echo
  echo "---SEPARATOR---"
  echo
  echo "=== TRANSCRIPT (preprocessed) ==="
  sed -n "${START_LINE},${TOTAL_LINES}p" "$TRANSCRIPT" | sb_preprocess_transcript
} > "$EXTRACT_INPUT"

DELTA_JSON=""

# sb_call_extractor tries claude CLI then ANTHROPIC_API_KEY fallback, and
# writes a health marker to .extractor-health.json that session-load.sh
# reads to surface broken auth to the user on the next SessionStart.
if sb_call_extractor "$EXTRACT_INPUT" "$EXTRACT_OUT" "$EXTRACTOR_MODEL" "$PROMPT" "$EXTRACT_TIMEOUT"; then
  DELTA_JSON=$(cat "$EXTRACT_OUT")
else
  HEALTH_REASON=$(sb_get_extractor_health | jq -r '.reason // "unknown"' 2>/dev/null)
  sb_log_error "stop-extract.sh" "llm-extraction-failed model=$EXTRACTOR_MODEL output=$HEALTH_REASON" 0
fi

# Deterministic fallback when LLM is unavailable. Records a single [degraded] breadcrumb
# in a SIDECAR (`pending-extraction.log`), NOT in PROJECT.md's Recent decisions — those
# breadcrumbs are not decisions and were crowding real ones off the 5-bullet cap (SP-E).
# The transcript is still archived below, so the out-of-band drainer mines the REAL
# knowledge later; this sidecar just logs the gap. Deduped per day, bounded.
if [ -z "$DELTA_JSON" ]; then
  TODAY=$(date -u +%Y-%m-%d)
  PENDING_LOG="$(dirname "$PROJECT_MD")/pending-extraction.log"
  if grep -qF "[$TODAY] [degraded]" "$PENDING_LOG" 2>/dev/null; then
    # Already recorded today — emit empty delta (merge becomes no-op).
    DELTA_JSON='{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
  else
    # Scratch-path filter: /tmp, /var/tmp, /proc, /dev, /run are session-ephemeral
    # and have no value as future-session context — they only bloat the hot tier.
    FILES_JSON=$(sed -n "${START_LINE},${TOTAL_LINES}p" "$TRANSCRIPT" | jq -rcs '
      [
        .[]
        | select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use")
        | select(.name == "Edit" or .name == "Write" or .name == "MultiEdit")
        | .input.file_path
      ]
      | unique
      | map(select(. != null and . != ""))
      | map(select(test("^/tmp/|^/var/tmp/|^/proc/|^/dev/|^/run/") | not))
      | .[0:5]
    ' 2>/dev/null || echo '[]')
    FILES_JSON=$(sb_safe_json_array "$FILES_JSON")
    FILES_LIST=$(echo "$FILES_JSON" | jq -r 'join(", ")' 2>/dev/null)
    if [ -n "$FILES_LIST" ]; then
      NOTE="[degraded] LLM extraction unavailable; session touched: $FILES_LIST"
    else
      NOTE="[degraded] LLM extraction unavailable; tool-only session (transcript archived)"
    fi
    # Write the breadcrumb to the sidecar (out of PROJECT.md decisions), bounded to 50 lines.
    mkdir -p "$(dirname "$PENDING_LOG")" 2>/dev/null || true
    printf '[%s] %s\n' "$TODAY" "$NOTE" >> "$PENDING_LOG" 2>/dev/null || true
    if [ -f "$PENDING_LOG" ]; then
      tail -n 50 "$PENDING_LOG" > "$PENDING_LOG.tmp" 2>/dev/null && mv "$PENDING_LOG.tmp" "$PENDING_LOG" 2>/dev/null || rm -f "$PENDING_LOG.tmp" 2>/dev/null
    fi
    # Empty delta → the merge never touches PROJECT.md's Recent decisions.
    DELTA_JSON='{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
  fi
fi

# Layer 4 Quality Gate — filter low-quality extractions before merging into PROJECT.md.
# On gate failure, pass through unchanged (fail open — never block a session-end extraction).
GATED_DELTA=$(printf '%s' "$DELTA_JSON" | bash "$(dirname "$0")/extraction-quality-gate.sh" 2>/dev/null)
if [ -n "$GATED_DELTA" ] && printf '%s' "$GATED_DELTA" | jq empty 2>/dev/null; then
  DELTA_JSON="$GATED_DELTA"
fi

MERGE_ERR=$(mktemp)
if ! echo "$DELTA_JSON" \
  | bash "$(dirname "$0")/merge-project-update.sh" \
      --project-md "$PROJECT_MD" --knowledge-dir "$KNOWLEDGE_DIR" >/dev/null 2>"$MERGE_ERR"; then
  ERR_TAIL=$(tr '\n' ' ' < "$MERGE_ERR" | head -c 400)
  log_gate "merge-failed err=$ERR_TAIL"
fi
rm -f "$MERGE_ERR"

# --- Relationship edges (typed, bi-temporal) ---
# Append any relations[] the extractor proposed to ~/knowledge/graph/edges.jsonl.
# Pure-bash + deterministic; best-effort — a failure here must never fail the
# Stop hook. Uses the same quality-gated $DELTA_JSON (the gate preserves the
# relations field, only filtering decisions/blockers/cross_refs).
echo "$DELTA_JSON" | bash "$(dirname "$0")/merge-edges.sh" --knowledge-dir "$KNOWLEDGE_DIR" 2>/dev/null || true

# --- Persona signal extraction ---
PERSONA_SIGNALS=$(echo "$DELTA_JSON" | jq -c '.persona_signals // []')
if echo "$PERSONA_SIGNALS" | jq -e 'length > 0' >/dev/null 2>&1; then
  PERSONA_ERR=$(mktemp)
  if ! echo "$PERSONA_SIGNALS" \
    | bash "$(dirname "$0")/merge-persona-signals.sh" 2>"$PERSONA_ERR"; then
    ERR_TAIL=$(tr '\n' ' ' < "$PERSONA_ERR" | head -c 200)
    log_gate "persona-merge-failed err=$ERR_TAIL"
  fi
  rm -f "$PERSONA_ERR"

  # Auto-pin-suggest: high-confidence signals route to .pin-candidates.jsonl
  # for the session-load.sh banner. Lower-confidence still go through the
  # graduation counter in merge-persona-signals.sh.
  echo "$PERSONA_SIGNALS" | jq -c '.[] | select(.confidence == "high")' 2>/dev/null | while IFS= read -r sig; do
    TEXT=$(printf '%s' "$sig" | jq -r '.signal // empty' 2>/dev/null)
    [ -n "$TEXT" ] && sb_append_pin_candidate "$SLUG" "$TEXT"
  done
fi

# --- Archive preprocessed transcript for dream mining ---
SESSION_ID=$(echo "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null)
sb_archive_transcript "$TRANSCRIPT" "$SLUG" "$SESSION_ID" "$START_LINE" "$TOTAL_LINES" "$TOOL_COUNT" 2>/dev/null || true

# --- Incremental episodic index update ---
PLUGIN_DIST="$(dirname "$0")/../mcp/dist/tools"
if command -v node >/dev/null 2>&1 && [ -f "$PLUGIN_DIST/episodic-index-cli.bundle.js" ]; then
  BRAIN_DIR="$BRAIN_DIR" node "$PLUGIN_DIST/episodic-index-cli.bundle.js" 2>/dev/null &
fi

rm -f "$BRAIN_DIR/.session-baseline-$SLUG.md"
sb_clear_extraction_marker "$SLUG"

exit 0
