#!/bin/bash
# persona-tool-guard.sh — Layer 3 PreToolUse hook, rules-based (no LLM)
# Reads tool_input from STDIN JSON, matches against persona-rules.json (user) or
# persona-rules.default.json (plugin shipped). Returns hookSpecificOutput with
# permissionDecision and optional updatedInput.
#
# Kill switch: SB_PERSONA_GATE=off
# Always exits 0.
set -u

[ "${SB_PERSONA_GATE:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0

TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null)
[ -z "$TOOL" ] && exit 0

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

USER_RULES="$BRAIN_DIR/persona-rules.json"
DEFAULT_RULES="$PLUGIN_ROOT/scripts/persona-rules.default.json"
RULES_FILE=""
if [ -f "$USER_RULES" ]; then
  RULES_FILE="$USER_RULES"
elif [ -f "$DEFAULT_RULES" ]; then
  RULES_FILE="$DEFAULT_RULES"
fi
[ -z "$RULES_FILE" ] && exit 0

CMD=$(printf '%s' "$RAW" | jq -r '.tool_input.command // empty' 2>/dev/null)
PATH_INPUT=$(printf '%s' "$RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Iterate matching rules (filter by tool first via jq, then test each in bash).
MATCH_COUNT=$(jq --arg t "$TOOL" '[.rules[] | select(.tool == $t)] | length' "$RULES_FILE")
[ "$MATCH_COUNT" = "0" ] || [ -z "$MATCH_COUNT" ] && exit 0

i=0
while [ "$i" -lt "$MATCH_COUNT" ]; do
  rule=$(jq -c --arg t "$TOOL" --argjson i "$i" '[.rules[] | select(.tool == $t)] | .[$i]' "$RULES_FILE")
  i=$((i + 1))

  match_cmd=$(printf '%s' "$rule" | jq -r '.match_command // empty')
  match_path=$(printf '%s' "$rule" | jq -r '.match_path // empty')
  action=$(printf '%s' "$rule" | jq -r '.action')
  reason=$(printf '%s' "$rule" | jq -r '.reason')

  if [ -n "$match_cmd" ]; then
    [ -z "$CMD" ] && continue
    if ! printf '%s' "$CMD" | grep -qE "$match_cmd"; then continue; fi
  fi
  if [ -n "$match_path" ]; then
    [ -z "$PATH_INPUT" ] && continue
    if ! printf '%s' "$PATH_INPUT" | grep -qE "$match_path"; then continue; fi
  fi

  case "$action" in
    rewrite)
      replace=$(printf '%s' "$rule" | jq -r '.replace // ""')
      NEW_CMD=$(printf '%s' "$CMD" | sed -E "s|$match_cmd|$replace|g")
      jq -nc --arg c "$NEW_CMD" --arg r "$reason" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "allow",
          permissionDecisionReason: $r,
          updatedInput: { command: $c }
        }
      }' 2>/dev/null || true
      exit 0
      ;;
    ask)
      jq -nc --arg r "$reason" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "ask",
          permissionDecisionReason: $r
        }
      }' 2>/dev/null || true
      exit 0
      ;;
    deny)
      jq -nc --arg r "$reason" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: $r
        }
      }' 2>/dev/null || true
      exit 0
      ;;
  esac
done

exit 0
