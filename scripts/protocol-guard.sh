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
# PG_TEXT/PG_SUB_LOWER/PG_AGENT_LOWER piggyback on this same spawn so pg_agent/pg_subagent
# never need their own jq+tr just to get a lowercased classification string (review fix:
# Agent/Task path spawn-cost reduction — was ~1.0s/call, dominated by extra jq+tr pairs here).
{ IFS= read -r PG_EVENT; IFS= read -r PG_TOOL; IFS= read -r PG_SID; IFS= read -r PG_CWD; IFS= read -r PG_PATH
  IFS= read -r PG_AGENT_TYPE; IFS= read -r PG_SUB_TYPE; IFS= read -r PG_MODEL
  IFS= read -r PG_TEXT; IFS= read -r PG_SUB_LOWER; IFS= read -r PG_AGENT_LOWER; } < <(printf '%s' "$RAW" \
  | jq -r '.hook_event_name // "", .tool_name // "", .session_id // "", .cwd // "", .tool_input.file_path // "",
           .agent_type // "", .tool_input.subagent_type // "", .tool_input.model // "",
           (((.tool_input.description // "") + " " + (.tool_input.prompt // ""))[0:300] | ascii_downcase | gsub("[\r\n]";" ")),
           (.tool_input.subagent_type // "" | ascii_downcase),
           (.agent_type // "" | ascii_downcase)' 2>/dev/null | tr -d '\r')
: "${PG_EVENT:=}" "${PG_TOOL:=}" "${PG_SID:=}" "${PG_CWD:=$PWD}" "${PG_PATH:=}" "${PG_AGENT_TYPE:=}" "${PG_SUB_TYPE:=}" "${PG_MODEL:=}" \
  "${PG_TEXT:=}" "${PG_SUB_LOWER:=}" "${PG_AGENT_LOWER:=}"
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
  local LC_ALL=C
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
  local slug="" T S Slower M E job tier="unknown" rule="" reason="-" verdict="ok"
  local pinned=0 pinfile="" s_safe hard warn suggest scout_src=""
  local a_fast a_mid a_deep memf line
  T="$PG_TEXT"
  S="$PG_SUB_TYPE"
  Slower="$PG_SUB_LOWER"
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
          model:*)
            # Normalize past quotes/whitespace/trailing comments (bash 3.2 param
            # expansion only, no sed spawn): `model: "haiku"`, `model:  opus`,
            # `model: sonnet  # comment` all resolve to a bare alias.
            E="${line#model:}"
            E="${E#"${E%%[![:space:]]*}"}"
            E="${E%%#*}"
            E="${E%"${E##*[![:space:]]}"}"
            case "$E" in
              \"*\") E="${E#\"}"; E="${E%\"}" ;;
              \'*\') E="${E#\'}"; E="${E%\'}" ;;
            esac
            ;;
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
  if [ -z "$a_fast" ]; then
    sb_log_error "protocol-guard.sh" "model-ladder unreadable at $(sb_model_manifest): tier checks disabled" 1
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

  # -- job classification ([[ =~ ]], no spawn — grep pipelines cost ~150-200ms/call here).
  # think T: leading boundary ONLY (no trailing) so "architecture"/"reviewing"/"designs"
  # still match; "preview" is still excluded by the leading boundary before "review".
  # scout T: carries "which files?" and "does .* exist" (§7; dropped by an earlier pass).
  local think_hit=0 scout_hit=0
  local think_s_re='(review|critic|architect|adversar|audit|devil|design|security)'
  local think_t_re='(^|[^a-z])(review|architect|adversar|trade-?offs?|security|design|root cause|why does)'
  local scout_s_re='(scout|explore|search|find|lookup|locate|grep)'
  local scout_t_re='(^|[^a-z])(find|locate|list|grep|search|scan|inventory|lookup|where is|which files?|does .* exist)([^a-z]|$)'
  if [[ $Slower =~ $think_s_re ]]; then
    think_hit=1
  elif [[ $T =~ $think_t_re ]]; then
    think_hit=1
  fi
  if [ "$S" = "Explore" ]; then
    scout_hit=1; scout_src="agent"
  elif [[ $Slower =~ $scout_s_re ]]; then
    scout_hit=1; scout_src="agent"
  elif [[ $T =~ $scout_t_re ]]; then
    scout_hit=1; scout_src="text"
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
    case "$S" in
      Explore|Plan|general-purpose|"") : ;;          # omitted subagent_type == general-purpose
      second-brain:*) rule="unpinned-no-model" ;;     # our own agent SHOULD carry a pin
      *:*) : ;;                                        # foreign-plugin agent: pin location unresolvable, not absent
      *) rule="unpinned-no-model" ;;
    esac
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

  # -- suggested/rewrite model: ONE source (sb_resolve_model) feeds both the warn text and
  # the opt-in rewrite, so they can never name different models. scout-at-think may rewrite
  # ONLY when the scout signal came from the AGENT itself (Explore, or a scout-named
  # subagent_type) — a text-only prompt match (e.g. "the search indexer") is too weak to
  # override an explicit model on what may really be a DO task; it still warns (the
  # classifier stays measured), it just never forces a downgrade.
  suggest=""
  case "$rule" in
    explore-above-fast) suggest=$(sb_resolve_model fast dispatch) ;;
    scout-at-think) [ "$scout_src" = "agent" ] && suggest=$(sb_resolve_model fast dispatch) ;;
    think-at-scout) suggest=$(sb_resolve_model deep dispatch) ;;
  esac
  if [ "${SB_DELEGATION_REWRITE:-0}" = "1" ] && [ -n "$suggest" ]; then
    PG_REWRITE_MODEL="$suggest"
    verdict="rewrite"
  fi

  if [ "$verdict" != "ok" ]; then
    warn="[Delegation check - $rule] $reason."
    [ -n "$suggest" ] && warn="$warn suggested model: $suggest (SCOUT=$a_fast DO=$a_mid THINK=$a_deep)."
    warn="$warn Advisory; SB_DELEGATION_CHECK=off silences."
    while [ "${#warn}" -gt 300 ]; do warn="${warn%?}"; done
    pg_ctx_add "$warn"
    if [ "$rule" = "plan-no-hard-rules" ]; then
      slug=$(sb_session_slug "$PG_SID")
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
  local LC_ALL=C
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
      local think_s_re='(review|critic|architect|adversar|audit|devil|design|security)'
      local scout_s_re='(scout|explore|search|find|lookup|locate|grep)'
      if [[ $PG_AGENT_LOWER =~ $think_s_re ]]; then
        tier="THINK"
      elif [[ $PG_AGENT_LOWER =~ $scout_s_re ]]; then
        tier="SCOUT"
      else
        tier="DO"
      fi
      ;;
  esac
  pf="$PLUGIN_ROOT/skills/using-second-brain/protocol.md"
  role_block=$(awk "/^<!-- role:${tier}:begin/{f=1;next}/^<!-- role:${tier}:end/{f=0}f" "$pf" 2>/dev/null)
  if [ ! -f "$pf" ] || [ -z "$role_block" ]; then
    sb_log_error "protocol-guard.sh" "protocol.md missing role:$tier block" 1
    sb_log_error "protocol-guard.sh" \
      "gate=role-card agent=$agent_type tier=$tier bytes=0 hard=0 verdict=skip reason=no-role-block sid=$PG_SID" 0
    return 0
  fi
  slug=$(sb_session_slug "$PG_SID")
  a_fast=$(sb_resolve_model fast dispatch)
  a_mid=$(sb_resolve_model mid dispatch)
  a_deep=$(sb_resolve_model deep dispatch)
  role_block="${role_block//\{SCOUT\}/$a_fast}"
  role_block="${role_block//\{DO\}/$a_mid}"
  role_block="${role_block//\{THINK\}/$a_deep}"
  hard=$(sb_rules_hard_lines "$slug" 5)

  # Fixed + variable budget (review fix: the old cut-from-the-END truncation dropped the
  # mandatory Return: line first, and hardn double-counted vs. what actually rendered).
  # `local LC_ALL=C` above makes every ${#...} here a BYTE count, matching the 900 B cap.
  local header_line="[Role card - $tier ($agent_type)]"
  local hard_lbl="HARD (enforced):"
  local ret_line="Return: findings first, files:lines, <=2k tokens, a Gaps: section."
  local fixed="$header_line
$role_block
$hard_lbl
$ret_line"
  local budget=$(( 900 - ${#fixed} - 1 ))
  [ "$budget" -lt 0 ] && budget=0

  local hardblock="" hn=0 total_lines=0 cand hline remaining
  if [ -n "$hard" ]; then
    total_lines=$(printf '%s\n' "$hard" | grep -c '^- ')
    while IFS= read -r hline; do
      [ -n "$hline" ] || continue
      if [ -z "$hardblock" ]; then cand="$hline"; else cand="$hardblock
$hline"; fi
      if [ "${#cand}" -le $(( budget - 13 )) ]; then
        hardblock="$cand"
        hn=$((hn + 1))
      else
        break
      fi
    done <<HARDEOF
$hard
HARDEOF
    if [ "$hn" -lt "$total_lines" ]; then
      remaining=$((total_lines - hn))
      if [ -z "$hardblock" ]; then hardblock="(+$remaining more)"; else hardblock="$hardblock
(+$remaining more)"; fi
    fi
  fi
  [ -n "$hardblock" ] || hardblock="(none)"
  hardn=$hn

  card="$header_line
$role_block
$hard_lbl
$hardblock
$ret_line"
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
pg_search() {
  [ -n "$PG_PATH" ] && [ -n "$PG_SID" ] || return 0
  # normalize backslashes so MSYS `[ -e 'C:/x' ]` reliably resolves
  local p="${PG_PATH//\\//}"
  [ -e "$p" ] && return 0   # only fires for a WRITE of a path that does not yet exist

  # root/rel normalization duplicated inline (Slice 2's pg_jit does its own copy —
  # no shared state between mode bodies; each slice owns only its own anchor region).
  # `root` keeps its drive letter (needed by `git -C` below); the compare-only copies
  # `pn`/`rootn` are what get drive-stripped, mirroring pg_jit's own normalization —
  # review fix: `root` used to be the RAW $PG_CWD, so a Windows-form (backslash) cwd
  # never matched the forward-slash-converted $p and `rel` fell back to the full
  # absolute path in both the audit-log row and the self-exclusion check.
  local root="${CLAUDE_PROJECT_DIR:-$PG_CWD}" rel="$p"
  root="${root//\\//}"
  local pn="$p" rootn="$root"
  case "$pn" in [A-Za-z]:*) pn="${pn#??}" ;; esac
  case "$rootn" in [A-Za-z]:*) rootn="${rootn#??}" ;; esac
  case "$pn" in
    "$rootn"/*) rel="${pn#"$rootn"/}" ;;
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
    # NOTE: the memo is written with `printf '%s'` (no trailing newline —
    # session-load.sh:70), so `read` hits EOF instead of a delimiter and returns 1
    # even though it DID populate the variable — `read ... || slug=""` would clobber
    # a real value on every read (same bug class as pg_jit's own comment above, and
    # sb_session_slug's — review fix: this copy still had the clobber).
    [ -f "$slugf" ] && { IFS= read -r slug < "$slugf" 2>/dev/null; slug="${slug//$'\r'/}"; }
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
    sb_log_audit "protocol-guard.sh" "warn" "search-first" "$rel" "$base already exists at: $hits" "$PG_SID"
    sb_log_error "protocol-guard.sh" "gate=search-first tool=Write path=$rel matches=$n hits=$hits verdict=warn sid=$PG_SID" 0
    # Model-context copy only: the audit-log line above keeps the full, uncapped hit
    # list — this is what reaches the model, so it is sanitized (no brackets/backticks
    # that could break out of the bracketed advisory) and capped at <=300 bytes total
    # (review fix — an unbounded hit list from many/long namesakes was going straight
    # into additionalContext with no cap at all).
    local chits="${hits//[\`\[\]]/}"
    if [ "${#chits}" -gt 150 ]; then
      chits="${chits:0:150}"
      chits="${chits%,*}"
    fi
    local ctx="[Search before creating — $base already exists at: $chits. Check code_neighbors <path> / Grep before adding a duplicate; if this is intentional, proceed.]"
    pg_ctx_add "${ctx:0:300}"
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
