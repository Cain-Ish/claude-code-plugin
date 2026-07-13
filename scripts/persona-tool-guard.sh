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

# ONE jq for the four single-line fields (0.33.38 hot-path audit: this guard ran
# one jq per field on EVERY tool call — ~1.2s/call on Windows at ~33ms/spawn).
# Line-per-field -r protocol, NOT @tsv: @tsv backslash-escapes values, which would
# corrupt Windows file_path backslashes; -r lines need no unescaping, and these
# four fields are single-line by nature. The multiline-capable field (command) is
# read in a second spawn below. Garbage stdin → jq fails → TOOL empty → exit 0
# (same fail-soft as the old per-field form).
{
  IFS= read -r TOOL
  IFS= read -r SESSION_ID
  IFS= read -r CWD
  IFS= read -r PATH_INPUT
} < <(printf '%s' "$RAW" \
      | jq -r '.tool_name // "", .session_id // "", .cwd // "", .tool_input.file_path // ""' 2>/dev/null \
      | tr -d '\r')
[ -z "${TOOL:-}" ] && exit 0
[ -z "${CWD:-}" ] && CWD="$PWD"
: "${SESSION_ID:=}" "${PATH_INPUT:=}"

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Source lib.sh for sb_log_audit. Fail-soft: if the source fails, define a
# no-op so guard decisions still emit JSON to Claude (the guard's primary
# job) even when audit logging is unavailable.
if ! source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null; then
  sb_log_audit() { :; }
  sb_normalize_path() {
    local p="${1//\\//}"
    p="${p#"//?/"}"   # \\?\C:\… extended-length prefix (minimal mirror of lib.sh's canonical)
    case "$p" in [A-Za-z]:/*) command -v cygpath >/dev/null 2>&1 && p=$(cygpath -u "$p" 2>/dev/null || printf '%s' "$p") ;; esac
    printf '%s' "$p"
  }
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

# command is the one MULTILINE payload field (heredocs) — its own -r spawn keeps
# real newlines intact, which the rule regexes below match against.
CMD=$(printf '%s' "$RAW" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')
# Windows git-bash sends 'C:\…' paths; the scope allowlist and self-edit regexes
# are all forward-slash / $HOME-prefix based, so an un-normalized backslash path
# matches NOTHING (drive-letter absolutes fall through to the "$CWD/…" relative
# case and then trivially prefix-match $CWD — the resource-scope fail-open).
# Normalize both the working dir and the target to the /c/… POSIX form first.
CWD=$(sb_normalize_path "$CWD")
PATH_INPUT=$(sb_normalize_path "$PATH_INPUT")

# --- v2.10.0 tool-scope guard (HarnessAudit sar_tool) --------------------
# Ask before a tool is invoked when it's outside the declared allowlist.
# Per HarnessAudit, out-of-scope tool use is one of three L1 boundary-
# violation channels (alongside resource-scope and info-flow). Disabled
# by default — opt-in via tool_scope.enabled=true in persona-rules.json
# or per-session via SB_TOOL_SCOPE_EXTRA (colon-separated, like PATH).
# Run BEFORE resource-scope: if the tool itself is off-limits, the path
# check is moot. Kill switch: SB_TOOL_SCOPE=off.
# Both scope-enabled flags in ONE spawn (they live in the same rules file); the
# allowlist walks below stay lazy — they only spawn when a scope is actually enabled
# (off by default, so the common path pays nothing extra).
{
  IFS= read -r TS_ENABLED
  IFS= read -r RS_ENABLED
} < <(jq -r '(.tool_scope.enabled // false), (.resource_scope.enabled // false)' "$RULES_FILE" 2>/dev/null | tr -d '\r')

if [ "${SB_TOOL_SCOPE:-on}" != "off" ]; then
  if [ "${TS_ENABLED:-false}" = "true" ]; then
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
  if [ "${RS_ENABLED:-false}" = "true" ]; then
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

# Iterate matching rules. ONE jq enumerates every tool-matching rule as a fixed
# 6-line frame (name/action/match_command/match_path/replace/reason) + a \x01
# sentinel line — the old form re-parsed the whole rules file per index and then
# spawned one jq per FIELD (1+5N spawns; ~8 default Bash rules ≈ 40 spawns/call).
# Raw -r lines preserve regex strings byte-for-byte (no @tsv backslash mangling);
# rule fields are single-line by construction, and reason/replace get their
# newlines folded defensively so a multiline value cannot break the framing.
RULE_STREAM=$(jq -r --arg t "$TOOL" '
  .rules[] | select(.tool == $t) |
    (.name // "anonymous"),
    (.action // ""),
    (.match_command // ""),
    (.match_path // ""),
    ((.replace // "") | gsub("[\r\n]"; " ")),
    ((.reason // "") | gsub("[\r\n]"; " ")),
    "--SB-RULE-END--"
' "$RULES_FILE" 2>/dev/null | tr -d '\r')
[ -z "$RULE_STREAM" ] && exit 0

while IFS= read -r rule_name && IFS= read -r action && IFS= read -r match_cmd \
      && IFS= read -r match_path && IFS= read -r replace && IFS= read -r reason \
      && IFS= read -r _sentinel; do
  # Frame check: the 7th line of every rule frame is the sentinel token (non-empty: $() strips trailing newlines, so an empty sentinel would silently drop the LAST rule). A
  # non-empty value here means a field slipped the frame (multiline leak) —
  # stop matching rather than mis-apply rules to the wrong fields. Fail-soft.
  [ "$_sentinel" = "--SB-RULE-END--" ] || break

  if [ -n "$match_cmd" ]; then
    [ -z "$CMD" ] && continue
    if ! printf '%s' "$CMD" | grep -qE "$match_cmd"; then continue; fi
  fi
  if [ -n "$match_path" ]; then
    [ -z "$PATH_INPUT" ] && continue
    if ! printf '%s' "$PATH_INPUT" | grep -qE "$match_path"; then continue; fi
  fi

  target="${PATH_INPUT:-${CMD:0:200}}"

  case "$action" in
    rewrite)
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
done <<< "$RULE_STREAM"

exit 0
