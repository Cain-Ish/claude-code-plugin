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
pg_card() {
  pg_lib || return 0
  local pf card a_fast a_mid a_deep bytes
  pf="$PLUGIN_ROOT/skills/using-second-brain/protocol.md"
  if [ ! -f "$pf" ]; then
    sb_log_error "protocol-guard.sh" "protocol.md missing" 1
    return 0
  fi
  card=$(awk '/^<!-- card:begin/{f=1;next}/^<!-- card:end/{f=0}f' "$pf" 2>/dev/null)
  if [ -z "$card" ]; then
    sb_log_error "protocol-guard.sh" "protocol.md missing card block" 1
    return 0
  fi
  a_fast=$(sb_resolve_model fast dispatch)
  a_mid=$(sb_resolve_model mid dispatch)
  a_deep=$(sb_resolve_model deep dispatch)
  card="${card//\{SCOUT\}/$a_fast}"
  card="${card//\{DO\}/$a_mid}"
  card="${card//\{THINK\}/$a_deep}"
  card="[Working agreement - protocol card; tiers resolved from model-ladder.json]
$card"
  # Truncate at a LINE boundary, never mid-line (mirror session-load.sh's codemap-spine loop).
  while [ "${#card}" -gt 1200 ]; do
    case "$card" in
      *$'\n'*) card="${card%$'\n'*}" ;;
      *) card=""; break ;;
    esac
  done
  [ -n "$card" ] || return 0
  bytes=${#card}
  printf '%s\n\n' "$card"
  sb_log_error "protocol-guard.sh" "gate=protocol-card bytes=$bytes scout=$a_fast do=$a_mid think=$a_deep sid=$PG_SID" 0
  sb_buddy_event "$PG_SID" delivered focused "Protocol card delivered: SCOUT=$a_fast DO=$a_mid THINK=$a_deep" protocol-guard 600
}
# --- end pg_card ---
# --- pg_agent (Slice 1) ---
pg_agent() {
  pg_lib || return 0
  local slug T S Slower M E job tier="unknown" rule="" reason="-" verdict="ok"
  local pinned=0 pinfile="" s_safe hard warn suggest
  local a_fast a_mid a_deep memf line
  slug=$(sb_session_slug "$PG_SID")
  T=$(printf '%s' "$RAW" | jq -r \
    '((.tool_input.description // "") + " " + (.tool_input.prompt // ""))[0:300] | ascii_downcase' \
    2>/dev/null | tr -d '\r')
  S="$PG_SUB_TYPE"
  Slower=$(printf '%s' "$S" | tr 'A-Z' 'a-z')
  M="$PG_MODEL"
  s_safe="${S//[\\\/]/}"

  # -- effective model E: explicit tool_input.model > frontmatter pin > Explore cap > inherit.
  E=""
  if [ -n "$M" ]; then
    E="$M"
  else
    case "$S" in
      second-brain:*) pinfile="$PLUGIN_ROOT/agents/${s_safe#second-brain:}.md" ;;
      "") pinfile="" ;;
      *)
        if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/agents/$s_safe.md" ]; then
          pinfile="$CLAUDE_PROJECT_DIR/.claude/agents/$s_safe.md"
        elif [ -f "$HOME/.claude/agents/$s_safe.md" ]; then
          pinfile="$HOME/.claude/agents/$s_safe.md"
        fi
        ;;
    esac
    if [ -n "$pinfile" ] && [ -f "$pinfile" ]; then
      local _n=0
      while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
          '---') _n=$((_n + 1)); [ "$_n" -ge 2 ] && break; continue ;;
        esac
        case "$line" in
          model:*) E="${line#model:}"; E="${E# }" ;;
        esac
      done < "$pinfile"
    fi
    if [ -n "$E" ]; then
      pinned=1
    else
      E="inherit"
    fi
  fi

  # -- tier aliases: ONE jq producing three lines, memoized per-session so later Agent
  # calls in this session read the memo with `read` builtins instead of spawning jq again.
  memf="$BRAIN_DIR/.injected/$PG_SID.pg.json"
  a_fast=""; a_mid=""; a_deep=""
  if [ -n "$PG_SID" ] && [ -f "$memf" ]; then
    IFS= read -r line < "$memf" 2>/dev/null
    line="${line%$'\r'}"
    case "$line" in
      *'"fast":"'*'"mid":"'*'"deep":"'*)
        a_fast="${line#*\"fast\":\"}"; a_fast="${a_fast%%\"*}"
        a_mid="${line#*\"mid\":\"}"; a_mid="${a_mid%%\"*}"
        a_deep="${line#*\"deep\":\"}"; a_deep="${a_deep%%\"*}"
        ;;
    esac
  fi
  if [ -z "$a_fast" ] || [ -z "$a_mid" ] || [ -z "$a_deep" ]; then
    { IFS= read -r a_fast; IFS= read -r a_mid; IFS= read -r a_deep; } < <(jq -r \
      '.ladders.dispatch.fast[0] // "", .ladders.dispatch.mid[0] // "", .ladders.dispatch.deep[0] // ""' \
      "$(sb_model_manifest)" 2>/dev/null | tr -d '\r')
    if [ -n "$PG_SID" ] && [ -n "$a_fast" ]; then
      mkdir -p "$BRAIN_DIR/.injected" 2>/dev/null
      jq -nc --arg f "$a_fast" --arg m "$a_mid" --arg d "$a_deep" '{fast:$f,mid:$m,deep:$d}' 2>/dev/null \
        | tr -d '\r' > "$memf.tmp.$$" 2>/dev/null \
        && mv -f "$memf.tmp.$$" "$memf" 2>/dev/null || rm -f "$memf.tmp.$$" 2>/dev/null
    fi
  fi

  # -- tier of E
  case "$E" in
    "$a_fast") tier="fast" ;;
    "$a_mid") tier="mid" ;;
    "$a_deep") tier="deep" ;;
    claude-haiku-*) tier="fast" ;;
    claude-sonnet-*) tier="mid" ;;
    claude-opus-*) tier="deep" ;;
    inherit)
      tier="unknown"
      [ -z "$M" ] && [ "$pinned" = "0" ] && [ "$S" = "Explore" ] && tier="fast"
      ;;
    *) tier="unknown" ;;
  esac

  # -- job classification (word-boundary-safe ERE: no \b — BSD grep treats it as literal).
  local think_hit=0 scout_hit=0
  if printf '%s' "$Slower" | grep -qE -- '(review|critic|architect|adversar|audit|devil|design|security)'; then
    think_hit=1
  elif printf '%s' "$T" | grep -qE -- \
    '(^|[^a-z])(review|architect|adversarial|adversary|trade-?offs?|security|design|root cause|why does)([^a-z]|$)'; then
    think_hit=1
  fi
  if [ "$S" = "Explore" ]; then
    scout_hit=1
  elif printf '%s' "$Slower" | grep -qE -- '(scout|explore|search|find|lookup|locate|grep)'; then
    scout_hit=1
  elif printf '%s' "$T" | grep -qE -- \
    '(^|[^a-z])(find|locate|list|grep|search|scan|inventory|lookup|where is|which file)([^a-z]|$)'; then
    scout_hit=1
  fi
  if [ "$S" = "Plan" ]; then
    job="plan"
  elif [ "$think_hit" = "1" ]; then
    job="think"
  elif [ "$scout_hit" = "1" ]; then
    job="scout"
  else
    job="do"
  fi

  # -- rules (first match, warn-only); Explore's documented cap is checked ahead of the
  # generic scout/deep rule so its own, more specific message is the one reported.
  if [ "$S" = "Explore" ]; then
    case "$tier" in mid|deep) rule="explore-above-fast" ;; esac
  fi
  if [ -z "$rule" ] && [ "$job" = "scout" ] && [ "$tier" = "deep" ]; then
    rule="scout-at-think"
  fi
  if [ -z "$rule" ] && [ "$job" = "think" ] && [ "$tier" = "fast" ]; then
    rule="think-at-scout"
  fi
  if [ -z "$rule" ] && [ -z "$M" ] && [ "$pinned" = "0" ]; then
    case "$S" in Explore|Plan|general-purpose) : ;; *) rule="unpinned-no-model" ;; esac
  fi
  if [ -z "$rule" ] && [ "$job" = "plan" ]; then
    case "$T" in *"hard rules"*) : ;; *) rule="plan-no-hard-rules" ;; esac
  fi

  case "$rule" in
    explore-above-fast) reason="Explore is capped at fast; requested/effective tier is higher" ;;
    scout-at-think) reason="a lookup-only job dispatched at THINK tier" ;;
    think-at-scout) reason="a review/architecture job dispatched at SCOUT tier" ;;
    unpinned-no-model) reason="no model requested and no frontmatter pin found" ;;
    plan-no-hard-rules) reason="Plan prompt does not carry this repo's HARD rules" ;;
  esac
  [ -n "$rule" ] && verdict="warn"

  # -- opt-in rewrite (rules 1-3 only; each targets the CORRECT tier, never a literal model).
  if [ "${SB_DELEGATION_REWRITE:-0}" = "1" ]; then
    case "$rule" in
      scout-at-think|explore-above-fast) PG_REWRITE_MODEL=$(sb_resolve_model fast dispatch) ;;
      think-at-scout) PG_REWRITE_MODEL=$(sb_resolve_model deep dispatch) ;;
    esac
    [ -n "$PG_REWRITE_MODEL" ] && verdict="rewrite"
  fi

  if [ "$verdict" != "ok" ]; then
    suggest=""
    case "$rule" in
      scout-at-think|explore-above-fast) suggest="$a_fast" ;;
      think-at-scout) suggest="$a_deep" ;;
    esac
    warn="[Delegation check - $rule] $reason."
    [ -n "$suggest" ] && warn="$warn suggested model: $suggest (SCOUT=$a_fast DO=$a_mid THINK=$a_deep)."
    warn="$warn Advisory; SB_DELEGATION_CHECK=off silences."
    while [ "${#warn}" -gt 300 ]; do warn="${warn%?}"; done
    pg_ctx_add "$warn"
    if [ "$rule" = "plan-no-hard-rules" ]; then
      hard=$(sb_rules_hard_lines "$slug" 5)
      [ -n "$hard" ] && pg_ctx_add "HARD rules for this repo - put these in the Plan prompt:
$hard"
    fi
    sb_log_audit "protocol-guard.sh" "$verdict" "delegation:$rule" "$S" "$reason" "$PG_SID"
  fi

  sb_log_error "protocol-guard.sh" \
    "gate=delegation tool=$PG_TOOL agent=${S:--} job=$job model=${M:-unset} effective=$E tier=$tier verdict=$verdict rule=${rule:--} sid=$PG_SID" 0
}
# --- end pg_agent ---
# --- pg_subagent (Slice 1) ---
pg_subagent() {
  local agent_type="$PG_AGENT_TYPE" tier="" card slug hard hardn=0 bytes pf role_block
  local a_fast a_mid a_deep
  if [ -z "$agent_type" ]; then
    pg_lib && sb_log_error "protocol-guard.sh" \
      "gate=role-card agent=- tier=- bytes=0 hard=0 verdict=skip reason=no-agent-type sid=$PG_SID" 0
    return 0
  fi
  case "$agent_type" in
    second-brain:*)
      pg_lib && sb_log_error "protocol-guard.sh" \
        "gate=role-card agent=$agent_type tier=- bytes=0 hard=0 verdict=skip reason=second-brain-agent sid=$PG_SID" 0
      return 0
      ;;
    Plan)
      pg_lib && sb_log_error "protocol-guard.sh" \
        "gate=role-card agent=Plan tier=- bytes=0 hard=0 verdict=skip reason=plan sid=$PG_SID" 0
      return 0
      ;;
  esac
  pg_lib || return 0
  case "$agent_type" in
    Explore) tier="SCOUT" ;;
    general-purpose) tier="DO" ;;
    *)
      if printf '%s' "$agent_type" | tr 'A-Z' 'a-z' | grep -qE -- '(review|critic|architect|adversar|audit|devil|design|security)'; then
        tier="THINK"
      elif printf '%s' "$agent_type" | tr 'A-Z' 'a-z' | grep -qE -- '(scout|explore|search|find|lookup|locate|grep)'; then
        tier="SCOUT"
      else
        tier="DO"
      fi
      ;;
  esac
  pf="$PLUGIN_ROOT/skills/using-second-brain/protocol.md"
  role_block=$(awk "/^<!-- role:${tier}:begin/{f=1;next}/^<!-- role:${tier}:end/{f=0}f" "$pf" 2>/dev/null)
  slug=$(sb_session_slug "$PG_SID")
  a_fast=$(sb_resolve_model fast dispatch)
  a_mid=$(sb_resolve_model mid dispatch)
  a_deep=$(sb_resolve_model deep dispatch)
  role_block="${role_block//\{SCOUT\}/$a_fast}"
  role_block="${role_block//\{DO\}/$a_mid}"
  role_block="${role_block//\{THINK\}/$a_deep}"
  hard=$(sb_rules_hard_lines "$slug" 5)
  if [ -n "$hard" ]; then
    hardn=$(printf '%s\n' "$hard" | grep -c '^-')
  fi
  card="[Role card - $tier ($agent_type)]
$role_block
HARD (enforced):
${hard:-(none)}
Return: findings first, files:lines, <=2k tokens, a Gaps: section."
  while [ "${#card}" -gt 900 ]; do
    case "$card" in
      *$'\n'*) card="${card%$'\n'*}" ;;
      *) card=""; break ;;
    esac
  done
  [ -n "$card" ] || return 0
  bytes=${#card}
  jq -nc --arg c "$card" '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$c}}' 2>/dev/null | tr -d '\r'
  sb_log_error "protocol-guard.sh" \
    "gate=role-card agent=$agent_type tier=$tier bytes=$bytes hard=$hardn verdict=ok reason=- sid=$PG_SID" 0
}
# --- end pg_subagent ---
# --- pg_jit (Slice 2) ---
pg_jit() { :; }
# --- end pg_jit ---
# --- pg_search (Slice 3) ---
pg_search() { :; }
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
