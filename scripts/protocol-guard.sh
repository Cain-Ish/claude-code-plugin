#!/bin/bash
# protocol-guard.sh — class-5 working-agreement delivery + checks (docs/plans/2026-09-24-repo-brain.md).
# Modes (argv[1]): card | pre | subagent — hooks.json wires each to its event.
#   card      SessionStart : protocol card (<=1200 B, plain stdout)                    — Slice 1
#   pre       PreToolUse   : Agent|Task -> pg_agent (tier warn, opt-in model rewrite)   — Slice 1
#                            Read|Edit|Write|MultiEdit -> pg_jit (path-triggered memory) — Slice 2
#                            Write of a NEW path -> pg_search (search-before-create)     — Slice 3
#   subagent  SubagentStart: role card per agent_type (<=900 B); skips second-brain:* and Plan — Slice 1
# Protocol lock (CONSTITUTION.md class 5): inject capped text, return warn (additionalContext),
# write telemetry; opt-in SB_DELEGATION_REWRITE=1 may set updatedInput.model. Never dispatches,
# never edits settings, never blocks a Stop. Fail-open: any error -> exit 0, no output.
# Kill switches: SB_PROTOCOL_GUARD=off (all modes) · SB_PROTOCOL_CARD=off · SB_DELEGATION_CHECK=off
#   · SB_DELEGATION_REWRITE (default off; =1 enables) · SB_ROLE_CARDS=off · SB_JIT=off · SB_SEARCH_FIRST=off
set -u
[ "${SB_HOOK_PROFILE:-}" = "minimal" ] && : "${SB_PROTOCOL_GUARD:=off}"   # hook-profile shim (prose-locks pair)
[ "${SB_PROTOCOL_GUARD:-on}" = "off" ] && exit 0
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0
MODE="${1:-}"
RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
command -v cygpath >/dev/null 2>&1 && BRAIN_DIR=$(cygpath -u "$BRAIN_DIR" 2>/dev/null || printf '%s' "$BRAIN_DIR")
# ONE jq for every single-line field any mode needs (line-per-field -r protocol, CR-stripped).
{ IFS= read -r PG_EVENT; IFS= read -r PG_TOOL; IFS= read -r PG_SID; IFS= read -r PG_CWD; IFS= read -r PG_PATH
  IFS= read -r PG_AGENT_TYPE; IFS= read -r PG_SUB_TYPE; IFS= read -r PG_MODEL; } < <(printf '%s' "$RAW" \
  | jq -r '.hook_event_name // "", .tool_name // "", .session_id // "", .cwd // "", .tool_input.file_path // "",
           .agent_type // "", .tool_input.subagent_type // "", .tool_input.model // ""' 2>/dev/null | tr -d '\r')
: "${PG_EVENT:=}" "${PG_TOOL:=}" "${PG_SID:=}" "${PG_CWD:=$PWD}" "${PG_PATH:=}" "${PG_AGENT_TYPE:=}" "${PG_SUB_TYPE:=}" "${PG_MODEL:=}"
PG_SID="${PG_SID//[^A-Za-z0-9_-]/}"; PG_SID="${PG_SID:0:64}"
SB_MANIFEST_SESSION_ID="$PG_SID"
PG_CTX=""            # accumulated additionalContext for pre mode; empty = emit nothing
PG_REWRITE_MODEL=""  # set ONLY by pg_agent under SB_DELEGATION_REWRITE=1
pg_lib() { command -v sb_log_error >/dev/null 2>&1 || source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null || return 1; }
pg_ctx_add() { PG_CTX="${PG_CTX:+$PG_CTX

}$1"; }
pg_emit_pre() {  # ONE envelope per call. A rewrite carries the FULL original tool_input + model.
  if [ -n "$PG_REWRITE_MODEL" ]; then
    printf '%s' "$RAW" | jq -c --arg m "$PG_REWRITE_MODEL" --arg c "$PG_CTX" '{hookSpecificOutput:({hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"protocol-guard: tier rewrite (SB_DELEGATION_REWRITE=1)",updatedInput:((.tool_input // {}) + {model:$m})} + (if $c == "" then {} else {additionalContext:$c} end))}' 2>/dev/null | tr -d '\r'
  elif [ -n "$PG_CTX" ]; then
    jq -nc --arg c "$PG_CTX" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null | tr -d '\r'
  fi
}
# ---- mode bodies. Each slice replaces ONLY the body between its own anchor comments. ----
# --- pg_card (Slice 1) ---
pg_card() { :; }
# --- end pg_card ---
# --- pg_agent (Slice 1) ---
pg_agent() { :; }
# --- end pg_agent ---
# --- pg_subagent (Slice 1) ---
pg_subagent() { :; }
# --- end pg_subagent ---
# --- pg_jit (Slice 2) ---
pg_jit() { :; }
# --- end pg_jit ---
# --- pg_search (Slice 3) ---
pg_search() {
  [ -n "$PG_PATH" ] || return 0
  # normalize backslashes so MSYS `[ -e 'C:/x' ]` reliably resolves
  local p="${PG_PATH//\\//}"
  [ -e "$p" ] && return 0   # only fires for a WRITE of a path that does not yet exist

  # root/rel normalization duplicated inline (Slice 2's pg_jit does its own copy —
  # no shared state between mode bodies; each slice owns only its own anchor region).
  local root="$PG_CWD" rel="$p"
  case "$p" in
    "$PG_CWD"/*) rel="${p#"$PG_CWD"/}" ;;
  esac
  local base="${p##*/}"
  [ -n "$base" ] || return 0

  pg_lib || return 0
  local dir="$BRAIN_DIR/.injected"
  mkdir -p "$dir" 2>/dev/null || return 0
  local lsf="$dir/$PG_SID.lsfiles"
  if [ ! -f "$lsf" ]; then
    { git -C "$root" ls-files 2>/dev/null | tr -d '\r' > "$lsf.tmp.$$" && mv -f "$lsf.tmp.$$" "$lsf"; } \
      || { rm -f "$lsf.tmp.$$" 2>/dev/null; : > "$lsf"; }
  fi
  local cmf="$dir/$PG_SID.codemap.tsv"
  if [ ! -f "$cmf" ]; then
    local slug="" slugf="$dir/$PG_SID.slug"
    [ -f "$slugf" ] && { IFS= read -r slug < "$slugf" 2>/dev/null || slug=""; slug="${slug//$'\r'/}"; }
    local graph="$BRAIN_DIR/projects/$slug/codemap/graph.json"
    if [ -n "$slug" ] && [ -s "$graph" ]; then
      jq -r '.files[]?.id // empty' "$graph" 2>/dev/null | tr -d '\r' > "$cmf.tmp.$$" \
        && mv -f "$cmf.tmp.$$" "$cmf" || { rm -f "$cmf.tmp.$$" 2>/dev/null; : > "$cmf"; }
    else
      : > "$cmf"
    fi
  fi

  local hits="" n=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$n" -ge 5 ] && break
    case "$f" in
      "$rel") continue ;;
      */"$base"|"$base")
        case ",$hits," in *",$f,"*) continue ;; esac
        hits="${hits:+$hits,}$f"; n=$((n + 1)) ;;
    esac
  done < "$lsf"
  if [ "$n" -lt 5 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$n" -ge 5 ] && break
      case "$f" in
        "$rel") continue ;;
        */"$base"|"$base")
          case ",$hits," in *",$f,"*) continue ;; esac
          hits="${hits:+$hits,}$f"; n=$((n + 1)) ;;
      esac
    done < "$cmf"
  fi

  if [ "$n" -gt 0 ]; then
    pg_ctx_add "[Search before creating — $base already exists at: $hits. Check code_neighbors <path> / Grep before adding a duplicate; if this is intentional, proceed.]"
    sb_log_audit "protocol-guard.sh" "warn" "search-first" "$rel" "$base already exists at: $hits" "$PG_SID"
    sb_log_error "protocol-guard.sh" "gate=search-first tool=Write path=$rel matches=$n hits=$hits verdict=warn sid=$PG_SID" 0
  else
    sb_log_error "protocol-guard.sh" "gate=search-first tool=Write path=$rel matches=0 hits=none verdict=ok sid=$PG_SID" 0
  fi
}
# --- end pg_search ---
# ---- dispatcher (director-owned; slices do not edit) ----
case "$MODE" in
  card)     [ "${SB_PROTOCOL_CARD:-on}" = "off" ] || pg_card ;;
  subagent) [ "${SB_ROLE_CARDS:-on}" = "off" ] || pg_subagent ;;
  pre)
    case "$PG_TOOL" in
      Agent|Task) [ "${SB_DELEGATION_CHECK:-on}" = "off" ] || pg_agent ;;
      Read|Edit|Write|MultiEdit)
        [ "${SB_JIT:-on}" = "off" ] || pg_jit
        if [ "$PG_TOOL" = "Write" ] && [ "${SB_SEARCH_FIRST:-on}" != "off" ]; then pg_search; fi ;;
    esac
    pg_emit_pre ;;
esac
exit 0
