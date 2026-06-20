#!/bin/bash
# persona-tool-guard.sh — Layer 3 PreToolUse hook, rules-based (no LLM)
# Reads tool_input from STDIN JSON, matches against persona-rules.json (user) or
# persona-rules.default.json (plugin shipped). Returns hookSpecificOutput with
# permissionDecision and optional updatedInput.
#
# v2.9.0: every verdict (ask/deny/rewrite) is appended to audit-log.jsonl
# via sb_log_audit so /second-brain:audit can summarize what the safety
# layer did this session.
#
# Kill switch: SB_PERSONA_GATE=off
# Always exits 0.
set -u

[ "${SB_PERSONA_GATE:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0

TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')
[ -z "$TOOL" ] && exit 0

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Source lib.sh for sb_log_audit. Fail-soft: if the source fails, define a
# no-op so guard decisions still emit JSON to Claude (the guard's primary
# job) even when audit logging is unavailable.
if ! source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null; then
  sb_log_audit() { :; }
fi

USER_RULES="$BRAIN_DIR/persona-rules.json"
DEFAULT_RULES="$PLUGIN_ROOT/scripts/persona-rules.default.json"
RULES_FILE=""
if [ -f "$USER_RULES" ]; then
  RULES_FILE="$USER_RULES"
elif [ -f "$DEFAULT_RULES" ]; then
  RULES_FILE="$DEFAULT_RULES"
fi
[ -z "$RULES_FILE" ] && exit 0

SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')
CWD=$(printf '%s' "$RAW" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')
[ -z "$CWD" ] && CWD="$PWD"
CMD=$(printf '%s' "$RAW" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')
PATH_INPUT=$(printf '%s' "$RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null | tr -d '\r')

# --- v2.10.0 tool-scope guard (HarnessAudit sar_tool) --------------------
# Ask before a tool is invoked when it's outside the declared allowlist.
# Per HarnessAudit, out-of-scope tool use is one of three L1 boundary-
# violation channels (alongside resource-scope and info-flow). Disabled
# by default — opt-in via tool_scope.enabled=true in persona-rules.json
# or per-session via SB_TOOL_SCOPE_EXTRA (colon-separated, like PATH).
# Run BEFORE resource-scope: if the tool itself is off-limits, the path
# check is moot. Kill switch: SB_TOOL_SCOPE=off.
if [ "${SB_TOOL_SCOPE:-on}" != "off" ]; then
  TS_ENABLED=$(jq -r '.tool_scope.enabled // false' "$RULES_FILE" 2>/dev/null | tr -d '\r')
  if [ "$TS_ENABLED" = "true" ]; then
    in_tool_scope=0
    while IFS= read -r allowed_tool; do
      [ -z "$allowed_tool" ] && continue
      if [ "$allowed_tool" = "$TOOL" ]; then in_tool_scope=1; break; fi
    done < <(
      jq -r '.tool_scope.allowlist[]?' "$RULES_FILE" 2>/dev/null | tr -d '\r'
      printf '%s\n' "${SB_TOOL_SCOPE_EXTRA:-}" | tr ':' '\n'
    )
    if [ "$in_tool_scope" = "0" ]; then
      TS_REASON="Tool '$TOOL' is not in the declared tool_scope allowlist. HarnessAudit treats out-of-scope tool use as one of three L1 boundary-violation channels. Confirm intent or extend via SB_TOOL_SCOPE_EXTRA (colon-separated)."
      sb_log_audit "persona-tool-guard.sh" "ask" "tool-scope-out-of-scope" "$TOOL" "$TS_REASON" "$SESSION_ID"
      jq -nc --arg r "$TS_REASON" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "ask",
          permissionDecisionReason: $r
        }
      }' 2>/dev/null || true
      exit 0
    fi
  fi
fi

# --- v2.9.0 resource-scope guard (HarnessAudit Layer 1) ------------------
# Ask before file-touching tools target a path outside the configured
# allowlist. Per the paper: 50%+ of agents apply reasonable tools to
# unauthorized RESOURCES — this is the dominant boundary-violation mode.
# Run BEFORE rule iteration so an out-of-scope path is gated even when no
# named rule matches it. Kill switch: SB_RESOURCE_SCOPE=off.
if [ "${SB_RESOURCE_SCOPE:-on}" != "off" ] && [ -n "$PATH_INPUT" ]; then
  SCOPE_ENABLED=$(jq -r '.resource_scope.enabled // false' "$RULES_FILE" 2>/dev/null | tr -d '\r')
  if [ "$SCOPE_ENABLED" = "true" ]; then
    # Is this tool subject to scope checking?
    TOOL_IN_SCOPE_LIST=$(jq -r --arg t "$TOOL" \
      '.resource_scope.tools // [] | index($t) | if . == null then "no" else "yes" end' \
      "$RULES_FILE" 2>/dev/null)
    if [ "$TOOL_IN_SCOPE_LIST" = "yes" ]; then
      # Resolve target to absolute. Hooks generally get absolute paths from
      # Claude Code, but be defensive: relative -> resolve against $CWD.
      case "$PATH_INPUT" in
        /*)  abs_path="$PATH_INPUT" ;;
        ~/*) abs_path="$HOME/${PATH_INPUT#~/}" ;;
        *)   abs_path="$CWD/$PATH_INPUT" ;;
      esac
      # Walk allowlist (with $CWD / $HOME interpolation) + SB_RESOURCE_SCOPE_EXTRA.
      in_scope=0
      while IFS= read -r prefix; do
        [ -z "$prefix" ] && continue
        # Variable substitution. Order matters — substitute $HOME before $CWD
        # so a literal "$CWD" inside $HOME doesn't double-expand.
        prefix="${prefix//\$HOME/$HOME}"
        prefix="${prefix//\$CWD/$CWD}"
        case "$abs_path" in
          "$prefix"|"$prefix"/*) in_scope=1; break ;;
        esac
      done < <(
        jq -r '.resource_scope.allowlist[]?' "$RULES_FILE" 2>/dev/null | tr -d '\r'
        # User can append extra paths via env, colon-separated like $PATH.
        # %s\n ensures `read` sees the final path even when EXTRA has no
        # trailing newline (which it never does as an env var value).
        printf '%s\n' "${SB_RESOURCE_SCOPE_EXTRA:-}" | tr ':' '\n'
      )
      if [ "$in_scope" = "0" ]; then
        SCOPE_REASON="Path '$abs_path' is outside the project resource scope. HarnessAudit shows agents most often violate boundaries by applying reasonable tools to unauthorized resources. Confirm intent or extend scope via SB_RESOURCE_SCOPE_EXTRA."
        sb_log_audit "persona-tool-guard.sh" "ask" "resource-scope-out-of-scope" "$abs_path" "$SCOPE_REASON" "$SESSION_ID"
        jq -nc --arg r "$SCOPE_REASON" '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "ask",
            permissionDecisionReason: $r
          }
        }' 2>/dev/null || true
        exit 0
      fi
    fi
  fi
fi

# Iterate matching rules (filter by tool first via jq, then test each in bash).
MATCH_COUNT=$(jq --arg t "$TOOL" '[.rules[] | select(.tool == $t)] | length' "$RULES_FILE")
[ "$MATCH_COUNT" = "0" ] || [ -z "$MATCH_COUNT" ] && exit 0

i=0
while [ "$i" -lt "$MATCH_COUNT" ]; do
  rule=$(jq -c --arg t "$TOOL" --argjson i "$i" '[.rules[] | select(.tool == $t)] | .[$i]' "$RULES_FILE")
  i=$((i + 1))

  match_cmd=$(printf '%s' "$rule" | jq -r '.match_command // empty' | tr -d '\r')
  match_path=$(printf '%s' "$rule" | jq -r '.match_path // empty' | tr -d '\r')
  action=$(printf '%s' "$rule" | jq -r '.action' | tr -d '\r')
  reason=$(printf '%s' "$rule" | jq -r '.reason' | tr -d '\r')

  if [ -n "$match_cmd" ]; then
    [ -z "$CMD" ] && continue
    if ! printf '%s' "$CMD" | grep -qE "$match_cmd"; then continue; fi
  fi
  if [ -n "$match_path" ]; then
    [ -z "$PATH_INPUT" ] && continue
    if ! printf '%s' "$PATH_INPUT" | grep -qE "$match_path"; then continue; fi
  fi

  rule_name=$(printf '%s' "$rule" | jq -r '.name // "anonymous"' | tr -d '\r')
  target="${PATH_INPUT:-${CMD:0:200}}"

  case "$action" in
    rewrite)
      replace=$(printf '%s' "$rule" | jq -r '.replace // ""' | tr -d '\r')
      # v2.10.0: use SOH (\x01) as the sed delimiter instead of `|`. The
      # old `s|$match_cmd|$replace|g` form errored ("unknown option to s")
      # whenever match_cmd contained a `|` — which is common for grouped
      # regex alternations — and silently zeroed-out NEW_CMD. SOH cannot
      # appear in a shell command, so it's a safe delimiter. If either
      # operand somehow contains SOH (the user is doing something exotic)
      # we skip rewrite and pass the command through unchanged rather
      # than risk corruption.
      SOH=$'\x01'
      case "$match_cmd$replace" in
        *"$SOH"*) NEW_CMD="$CMD" ;;
        *) NEW_CMD=$(printf '%s' "$CMD" | sed -E "s${SOH}${match_cmd}${SOH}${replace}${SOH}g") ;;
      esac
      sb_log_audit "persona-tool-guard.sh" "rewrite" "$rule_name" "$target" "$reason" "$SESSION_ID"
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
      sb_log_audit "persona-tool-guard.sh" "ask" "$rule_name" "$target" "$reason" "$SESSION_ID"
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
      sb_log_audit "persona-tool-guard.sh" "deny" "$rule_name" "$target" "$reason" "$SESSION_ID"
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
