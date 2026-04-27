#!/bin/bash
# Persona drift detector.
#
# Scans the most recent assistant turns in the transcript for high-precision
# phrases that ~/.second-brain/persona.md explicitly forbids (filler phrases,
# AI-attribution markers, narration patterns). Each hit is appended as a
# JSONL line to ~/.second-brain/drift-log.jsonl so /second-brain:drift-check
# can later report drift and propose fixes.
#
# Wired into the Stop hook so it runs after every assistant turn. Stays cheap:
# scans only the LAST 20 assistant messages (not the full transcript) and
# bails out fast if jq isn't installed or there's no transcript path.

BRAIN_DIR="$HOME/.second-brain"
DRIFT_LOG="$BRAIN_DIR/drift-log.jsonl"
SIGNALS_FILE="$BRAIN_DIR/persona.signals.json"
MAX_LINES=5000          # rotate threshold (matches friction-log.sh)
SCAN_LAST_N=20          # only inspect the last N assistant turns per run

mkdir -p "$BRAIN_DIR"

# Hard requirement: jq. Match the silent-exit pattern used by other hooks so a
# missing jq doesn't crash the SessionStart chain — the preflight in
# session-load.sh already loudly tells the user about it.
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)

# Resolve transcript by session_id fallback (matches extract-learnings.sh:28-35).
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "unknown" ]; then
    POSSIBLE="$HOME/.claude/sessions/$SESSION_ID.jsonl"
    [ -f "$POSSIBLE" ] && TRANSCRIPT_PATH="$POSSIBLE"
  fi
fi
[ -f "$TRANSCRIPT_PATH" ] || exit 0

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Built-in high-precision drift signals. Each entry is "id|claim|extended-regex".
# These are the patterns that show up reliably in assistant output and that
# persona.md explicitly forbids. Keep the list short and high-precision; false
# positives erode trust. Users can override by writing persona.signals.json
# (same format, JSON-encoded).
DEFAULT_SIGNALS='[
  {"id":"filler-certainly","claim":"No filler phrase: Certainly!","pattern":"(^|[^A-Za-z])Certainly[!.,]"},
  {"id":"filler-great-question","claim":"No filler phrase: Great question","pattern":"(^|[^A-Za-z])Great question([^A-Za-z]|$)"},
  {"id":"filler-happy-to","claim":"No filler phrase: I would be happy to","pattern":"(^|[^A-Za-z])(I.?d be happy to|I would be happy to|Happy to)([^A-Za-z]|$)"},
  {"id":"filler-sure-thing","claim":"No filler phrase: Sure thing","pattern":"(^|[^A-Za-z])Sure thing[!.,]"},
  {"id":"narration-let-me-explain","claim":"No narration: Let me explain","pattern":"(^|[^A-Za-z])(Let me explain|Here.?s what I did|Here.?s a (function|component|class) that)([^A-Za-z]|$)"},
  {"id":"ai-attribution-coauthor","claim":"No Co-Authored-By markers","pattern":"Co-?Authored-?By:"},
  {"id":"ai-attribution-generated","claim":"No AI generation attribution","pattern":"(Generated (with|by) (\\[?Claude|AI)|Claude Code]\\()"},
  {"id":"narration-i-will-now","claim":"No narration: I will now / I am going to","pattern":"(^|[^A-Za-z])(I will now|I am going to|I.?ll now proceed to)([^A-Za-z]|$)"}
]'

# Use override file if present and valid, otherwise the built-in list.
if [ -f "$SIGNALS_FILE" ]; then
  SIGNALS_JSON=$(jq '.forbidden_phrases // .' "$SIGNALS_FILE" 2>/dev/null)
  if [ -z "$SIGNALS_JSON" ] || [ "$SIGNALS_JSON" = "null" ]; then
    SIGNALS_JSON="$DEFAULT_SIGNALS"
  fi
else
  SIGNALS_JSON="$DEFAULT_SIGNALS"
fi

# Pull the last N assistant text turns from the transcript. Claude Code stores
# assistant messages with .type=="assistant", .message.role=="assistant", and
# .message.content is an array of content blocks; we want only the .text fields
# of text blocks. tail-grabbing keeps memory bounded for long sessions.
ASSISTANT_TEXTS=$(jq -r '
  select(.type=="assistant")
  | .message.content // []
  | map(select(.type=="text") | .text // "")
  | join("\n")
' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n "$((SCAN_LAST_N * 50))")

[ -z "$ASSISTANT_TEXTS" ] && exit 0

# Walk each signal, grep the assistant text, append a drift entry per hit.
# We do at most ONE entry per signal per run to avoid log spam — a single bad
# turn shouldn't write 12 lines for the same phrase.
echo "$SIGNALS_JSON" | jq -c '.[]' 2>/dev/null | while IFS= read -r SIGNAL; do
  ID=$(echo "$SIGNAL" | jq -r '.id // empty')
  CLAIM=$(echo "$SIGNAL" | jq -r '.claim // empty')
  PATTERN=$(echo "$SIGNAL" | jq -r '.pattern // empty')
  [ -z "$ID" ] || [ -z "$PATTERN" ] && continue

  # grep -E against the extended regex; capture first match for excerpt.
  # Wrap in `timeout 1` to defuse ReDoS from a malicious persona.signals.json
  # pattern with nested quantifiers like (a+)+b. timeout(1) is GNU coreutils;
  # if missing (rare), fall back to ungated grep.
  if command -v timeout >/dev/null 2>&1; then
    MATCH=$(printf '%s\n' "$ASSISTANT_TEXTS" | timeout 1 grep -Eom1 ".{0,40}${PATTERN}.{0,40}" 2>/dev/null)
  else
    MATCH=$(printf '%s\n' "$ASSISTANT_TEXTS" | grep -Eom1 ".{0,40}${PATTERN}.{0,40}" 2>/dev/null)
  fi
  [ -z "$MATCH" ] && continue

  # Trim to 80 chars max for the log excerpt.
  EXCERPT=$(printf '%s' "$MATCH" | cut -c1-80)

  jq -nc \
    --arg t "$TIMESTAMP" \
    --arg s "$SESSION_ID" \
    --arg id "$ID" \
    --arg c "$CLAIM" \
    --arg ex "$EXCERPT" \
    '{timestamp:$t, session_id:$s, signal_id:$id, claim:$c, excerpt:$ex}' \
    >> "$DRIFT_LOG"
done

# Rotation: same policy as friction-log.sh — keep most recent half.
if [ -f "$DRIFT_LOG" ]; then
  LINES=$(wc -l < "$DRIFT_LOG" 2>/dev/null | tr -d ' ')
  LINES=${LINES:-0}
  if [ "$LINES" -gt "$MAX_LINES" ]; then
    KEEP=$((MAX_LINES / 2))
    tail -n "$KEEP" "$DRIFT_LOG" > "$DRIFT_LOG.tmp" && mv "$DRIFT_LOG.tmp" "$DRIFT_LOG"
  fi
fi

exit 0
