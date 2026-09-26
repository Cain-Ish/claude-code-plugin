#!/bin/bash
# buddy-statusline.sh — the second-brain buddy: a Claude Code statusLine renderer.
# Design: docs/plans/2026-09-22-buddy-companion.md. The buddy is the layer between Claude and the
# knowledge base, both ways: the lines directly under the input box show what memory delivered,
# what Claude read or saved through the MCP tools, which gate is holding, what waits on the user,
# and what Claude itself said to the user through `buddy_react`. It only READS: zero tokens, no LLM.
#
# The buddy is one capybara, drawn and animated like Claude Code's native /buddy (v2.1.89–2.1.96,
# src/buddy/sprites.ts + CompanionSprite.tsx): three 5×12 frames, the 15-step idle sequence
# [0,0,0,0,1,0,0,0,-1,0,0,2,0,0,0] (-1 = blink: frame 0, eyes → '-'), and "excited" — every frame in
# turn, no blink — while a line is fresh (< 10 s). The native ticked every 500 ms; a statusLine can
# re-run at most once a second (`refreshInterval: 1`, written by `sb buddy install`), so one step
# per second: a 15 s cycle. Under 90 columns (or 30 rows) it collapses to the native one-line face
# (·oo·). Like the native bubble, a line is bright for 10 s, then dims; with nothing live the bubble
# box is not drawn. Claude's own `buddy_react` line (kind `said`, shown as "Claude: …") holds the
# bubble for 60 s against newer non-gate events, as an active gate does.
# The renderer also drops .buddy/<sid>.seen once per session, and only when the bubble is drawn (not
# muted, sprite on): persona-context only asks Claude for buddy_react in such a session.
#
# Install: `sb buddy install` (settings.json statusLine → ~/.second-brain/bin shim → this script,
# refreshInterval 1, settings backed up, an existing statusline chained). A chained statusline
# arrives as SB_BUDDY_CHAIN in the environment of the audited settings.json command — never from a
# data file under ~/.second-brain, which nothing guards. Its output is cached for 5 s per session
# (.buddy/<sid>.chain), so the per-second animation tick does not re-run it every second.
#
# HOT PATH (runs every second): ONE jq spawn, no other subprocess on a cached tick, bash builtins
# for all string work. Reads $BRAIN_DIR/buddy.json (name, mute, sprite), .buddy/<sid>.json,
# .buddy/_global.json, .injected/<sid>.json + .phase. Width: SB_BUDDY_COLS > COLUMNS > 120.
# Kill: SB_BUDDY=off prints nothing; SB_BUDDY_SPRITE=off / SB_HOOK_PROFILE=minimal → telemetry
# only; SB_BUDDY_ASCII=on avoids box glyphs; NO_COLOR drops colour. SB_BUDDY_NOW pins the clock
# (tests: frame selection is a pure function of the epoch second).
set -u
set -f   # event lines are transcript-derived text: never let `*`/`?`/`[` glob against the cwd
[ "${SB_BUDDY:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ "${SB_HOOK_PROFILE:-}" = "minimal" ] && SB_BUDDY_SPRITE=off   # lib-less script: profile shim

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
# Only a Windows-form path needs cygpath (a fork per tick otherwise, and this runs every second).
case "$BRAIN_DIR" in [A-Za-z]:*|*\\*) command -v cygpath >/dev/null 2>&1 && BRAIN_DIR=$(cygpath -u "$BRAIN_DIR" 2>/dev/null || printf '%s' "$BRAIN_DIR") ;; esac

RAW=""
[ -t 0 ] || IFS= read -r -t 2 -d '' RAW || true      # the payload is one line; -d '' reads to EOF
RAW="${RAW//$'\r'/}"
# Epoch seconds without a subprocess (bash ≥ 4.2); `date` only for bash 3.2.
if [[ "${SB_BUDDY_NOW:-}" =~ ^[0-9]+$ ]]; then now="$SB_BUDDY_NOW"
elif printf -v now '%(%s)T' -1 2>/dev/null && [[ "$now" =~ ^[0-9]+$ ]]; then :; else now=$(date +%s); fi

_f() { if [ -f "$2" ]; then printf -v "$1" '%s' "$2"; else printf -v "$1" '%s' /dev/null; fi; }   # --rawfile needs a path; no $( ) fork
# session_id by regex, not jq: the id is [A-Za-z0-9_-] by construction, and this runs every second.
SID=""
[[ "$RAW" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]{1,64})\" ]] && SID="${BASH_REMATCH[1]}"
_f CFG "$BRAIN_DIR/buddy.json"; _f CUR "$BRAIN_DIR/.buddy/$SID.json"; _f GLB "$BRAIN_DIR/.buddy/_global.json"
_f MEMO "$BRAIN_DIR/.injected/$SID.json"
[ -n "$SID" ] || { CUR=/dev/null; MEMO=/dev/null; }
PHASE=""; [ -n "$SID" ] && [ -f "$BRAIN_DIR/.injected/$SID.phase" ] && { IFS= read -r PHASE < "$BRAIN_DIR/.injected/$SID.phase" 2>/dev/null || true; }
PHASE="${PHASE//[^a-z]/}"

# Fields joined with US (\x1f): `read` collapses runs of whitespace separators, so a tab would
# swallow empty fields and shift every later one. Each file is parsed on its own (`try fromjson`)
# so one torn file never blanks the others.
US=$'\x1f'
IFS="$US" read -r MODEL CTX NAME MUTE SPRITE_CFG GOAL LINE KIND ETS MOOD < <(
  jq -rn --arg raw "$RAW" --argjson now "$now" \
    --rawfile c "$CFG" --rawfile e "$CUR" --rawfile g "$GLB" --rawfile m "$MEMO" '
    def j: try fromjson catch {};
    def scrub: gsub("[\u0001-\u001f\u007f-\u009f\u2028\u2029]|\\p{Cf}"; " ");
    def live: select(type=="object" and has("line") and ((.ts // null) | type) == "number"
      and (((.ttl_s // 900) | type) != "number" or .ttl_s == 0 or ($now - .ts) <= .ttl_s));
    ($raw | j) as $in | ($c | j) as $c | ($m | j) as $m
    | ([($e | j), ($g | j | select(.kind? != "said"))] | map(live)) as $ev
    # a fresh ACTIVE gate holds the bubble, then a fresh buddy_react line from Claude (THIS session key),
    # otherwise the newest live event of either key wins
    | ( ($ev | map(select(.kind=="gate" and .mood!="pleased" and ($now - .ts) < 60)) | first)
        // ([($e | j)] | map(live | select(.kind=="said" and ($now - .ts) < 60)) | first)
        // ($ev | sort_by(.ts) | last) // {} ) as $x
    | [ ($in.model.display_name // $in.model.id // ""),
        (($in.context_window.used_percentage // null) | if . == null then "" else (tostring | split(".")[0]) end),
        ((if ($c.name | type) == "string" then $c.name | scrub | .[0:14] else "" end) | if test("\\S") then . else "Kapi" end),
        (if ($c.mute // false) == true then "1" else "0" end),
        (if $c.sprite == false then "off" else "on" end),   # not `// true`: the jq // operator also replaces false
        (($m.goal // "") | scrub),
        (($x.line // "") | scrub), ($x.kind // ""), ($x.ts // 0), ($x.mood // "focused") ]
    | map(tostring | gsub("[\n\r\u001f]"; " ")) | join("\u001f")' 2>/dev/null
) || true
MOOD="${MOOD//$'\r'/}"   # Windows jq ends the line \r\n: the CR lands in the LAST field and no mood case matches
: "${MODEL:=}" "${CTX:=}" "${NAME:=Kapi}" "${MUTE:=0}" "${SPRITE_CFG:=on}" "${GOAL:=}" "${LINE:=}" \
  "${KIND:=}" "${ETS:=0}" "${MOOD:=focused}"
[[ "$ETS" =~ ^[0-9]+$ ]] || ETS=0

# --- width: what Claude Code exports, or the override; no tput/stty (no tty in the captured run) --
COLS="${SB_BUDDY_COLS:-${COLUMNS:-}}"
[[ "$COLS" =~ ^[0-9]+$ ]] || COLS=120
USABLE=$(( COLS - 14 )); [ "$USABLE" -lt 40 ] && USABLE=40   # ~14 cols of content-box chrome

if [ -n "${NO_COLOR:-}" ]; then DIM=""; ACC=""; WARN=""; OK=""; SAID=""; FUR=""; RST=""
else DIM=$'\e[2m'; ACC=$'\e[38;2;139;92;246m'; WARN=$'\e[38;2;245;158;11m'; OK=$'\e[38;2;16;185;129m'
  SAID=$'\e[3;38;2;139;92;246m'; FUR=$'\e[38;2;196;144;98m'; RST=$'\e[0m'; fi

# --- line 0: chained statusline (from the settings.json command's own environment) -------------
# Cached per session for 5 s: the animation tick re-runs this script every second, and a chained
# `npx …` statusline costs ~300 ms a run. At most 3 lines; builtins only on the cached path.
if [ -n "${SB_BUDDY_CHAIN:-}" ]; then
  CH=""; CHF=""; HIT=0; [ -n "$SID" ] && CHF="$BRAIN_DIR/.buddy/$SID.chain"
  if [ -n "$CHF" ] && [ -f "$CHF" ]; then
    _cts=""; { IFS= read -r _cts; IFS= read -r -d '' CH; } < "$CHF" 2>/dev/null || true
    # a hit even when the chained command printed nothing (a broken one must not re-run every tick)
    if [[ "$_cts" =~ ^[0-9]+$ ]] && [ $(( now - _cts )) -ge 0 ] && [ $(( now - _cts )) -lt 5 ]; then HIT=1; else CH=""; fi
  fi
  if [ "$HIT" = "0" ] && [ -n "$CHF" ] && [ -d "$BRAIN_DIR/.buddy" ]; then
    # Stamp first, keeping the old output: Claude Code cancels an in-flight run when the next tick
    # arrives, so a chain slower than a second would otherwise be re-spawned on every tick.
    _old=""; [ -f "$CHF" ] && { IFS= read -r _x; IFS= read -r -d '' _old; } < "$CHF" 2>/dev/null
    printf '%s\n%s' "$now" "$_old" > "$CHF.$$" 2>/dev/null && { mv -f "$CHF.$$" "$CHF" 2>/dev/null || rm -f "$CHF.$$" 2>/dev/null; }
    # The refresh runs DETACHED and writes the cache itself: run in the foreground, a chain slower
    # than the 1 s tick (npx … on Windows: 1-3 s) was cancelled every time, never wrote its cache,
    # and the user's statusline vanished for good. A fast chain still lands on this tick (≤ 0.8 s
    # wait); a slow one shows its last output now and its fresh output next tick. A failing chain is
    # logged once per session (quiet on screen, loud in the log).
    (
      _out=$(printf '%s' "$RAW" | bash -c "$SB_BUDDY_CHAIN" 2> "$CHF.err.$$"); _rc=$?
      printf '%s\n%s' "$now" "$_out" > "$CHF.$$" 2>/dev/null && { mv -f "$CHF.$$" "$CHF" 2>/dev/null || rm -f "$CHF.$$" 2>/dev/null; }
      if [ "$_rc" -ne 0 ] && [ ! -e "$CHF.logged" ]; then
        : > "$CHF.logged"; _e=""; IFS= read -r _e < "$CHF.err.$$" 2>/dev/null
        _row=$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg m "chained statusline exited $_rc: ${_e:0:200}" \
          --argjson rc "$_rc" '{timestamp: $ts, script: "buddy-statusline.sh", message: $m, exit_code: $rc}' 2>/dev/null)
        [ -n "$_row" ] && printf '%s\n' "$_row" >> "$BRAIN_DIR/error-log.jsonl" 2>/dev/null
      fi
      rm -f "$CHF.err.$$" 2>/dev/null
    ) < /dev/null > /dev/null 2>&1 &
    _pid=$!
    for _i in 1 2 3 4 5 6 7 8; do kill -0 "$_pid" 2>/dev/null || break; sleep 0.1; done
    CH="$_old"
    if ! kill -0 "$_pid" 2>/dev/null; then { IFS= read -r _x; IFS= read -r -d '' CH; } < "$CHF" 2>/dev/null || true; fi
  elif [ "$HIT" = "0" ]; then
    CH=$(printf '%s' "$RAW" | bash -c "$SB_BUDDY_CHAIN" 2>/dev/null) || true   # no session key: nowhere to cache
  fi
  if [ -n "$CH" ]; then
    _n=0; while IFS= read -r _l && [ "$_n" -lt 3 ]; do printf '%s\n' "$_l"; _n=$(( _n + 1 )); done <<< "$CH"
  fi
fi

# --- line 1: telemetry — goal · phase · ctx% · model ------------------------------------------
_trunc() { local s="$2" n="$3"; [ "${#s}" -gt "$n" ] && s="${s:0:$((n-1))}…"; printf -v "$1" '%s' "$s"; }
_pad()   { local s="$2" n="$3"; while [ "${#s}" -lt "$n" ]; do s="$s "; done; printf -v "$1" '%s' "$s"; }
SUF=""; SUFP=""
[ -n "$PHASE" ] && { SUF="$SUF ${DIM}·${RST} ${ACC}${PHASE}${RST}"; SUFP="$SUFP · $PHASE"; }
if [ -n "$CTX" ]; then c="$OK"; [ "$CTX" -ge 60 ] 2>/dev/null && c="$WARN"; SUF="$SUF ${DIM}·${RST} ctx ${c}${CTX}%${RST}"; SUFP="$SUFP · ctx ${CTX}%"; fi
if [ -n "$MODEL" ] && [ "$USABLE" -ge 70 ]; then SUF="$SUF ${DIM}· ${MODEL}${RST}"; SUFP="$SUFP · $MODEL"; fi
GW=$(( USABLE - ${#SUFP} - 3 )); [ "$GW" -gt 48 ] && GW=48
T="🧠"
if [ -n "$GOAL" ] && [ "$GW" -ge 12 ]; then _trunc G "$GOAL" "$GW"; T="$T $G"; fi
T="$T$SUF"
[ -z "$GOAL$PHASE" ] && T="$T ${DIM}no goal yet — first coding prompt sets it${RST}"
printf '%s\n' "$T"

# --- the capybara (wide) or its one-line face (narrow); mute / sprite-off = telemetry only -----
[ "$MUTE" = "1" ] && exit 0
[ "${SB_BUDDY_SPRITE:-$SPRITE_CFG}" = "off" ] && exit 0
# Only now is the bubble really on screen: .seen tells persona-context to ask Claude for buddy_react.
# Written before the mute/sprite exits, a muted buddy cost a wasted tool call every turn.
[ -n "$SID" ] && [ -d "$BRAIN_DIR/.buddy" ] && [ ! -e "$BRAIN_DIR/.buddy/$SID.seen" ] && { : > "$BRAIN_DIR/.buddy/$SID.seen"; } 2>/dev/null

# Eyes: the native default glyph, a mood pair when a gate/guard/wait wants attention.
EYE='·'; [ "${SB_BUDDY_ASCII:-off}" = "on" ] && EYE='.'
case "$MOOD" in
  alert)   L='ò'; R='ó' ;;
  pleased) L='^'; R='^' ;;
  waiting) L='_'; R='_' ;;
  puzzled) L="$EYE"; R='ô' ;;
  *)       L="$EYE"; R="$EYE" ;;
esac
FRESH=0; [ "$ETS" -gt 0 ] && [ $(( now - ETS )) -ge 0 ] && [ $(( now - ETS )) -lt 10 ] && FRESH=1
C="$DIM"; case "$KIND" in gate|guard|stumble) C="$WARN" ;; said) [ "$FRESH" = "1" ] && C="$SAID" ;; remembered|delivered|pending|read|retrieved) [ "$FRESH" = "1" ] && C="$OK" ;; esac
[ "$KIND" = "said" ] && [ -n "$LINE" ] && LINE="Claude: $LINE"   # never mistakable for a gate or guard line

ROWS="${LINES:-}"; [[ "$ROWS" =~ ^[0-9]+$ ]] || ROWS=0
if [ "$USABLE" -lt 76 ] || { [ "$ROWS" -gt 0 ] && [ "$ROWS" -lt 30 ]; }; then   # native narrow mode: `(·oo·)` + name, or the quip
  FACE="(${L}oo${R})"
  if [ -n "$LINE" ]; then _trunc Q "$LINE" $(( USABLE - 12 )); printf '  %s%s%s %s%s%s\n' "$FUR" "$FACE" "$RST" "$C" "$Q" "$RST"
  else printf '  %s%s%s %s%s%s\n' "$FUR" "$FACE" "$RST" "$DIM" "$NAME" "$RST"; fi
  exit 0
fi

# Frame: a fresh line (< 10 s) makes it excited — every frame in turn, no blink; otherwise the
# native idle sequence, one step per epoch second.
SEQ=(0 0 0 0 1 0 0 0 -1 0 0 2 0 0 0)
if [ "$FRESH" = "1" ]; then FRAME=$(( now % 3 ))
else FRAME="${SEQ[$(( now % 15 ))]}"; fi
[ "$FRAME" = "-1" ] && { FRAME=0; L='-'; R='-'; }
BACK='´'; [ "${SB_BUDDY_ASCII:-off}" = "on" ] && BACK="'"
S0='            '; S1='  n______n  '; NOSE='oo'
case "$FRAME" in 1) NOSE='Oo' ;; 2) S0='    ~  ~    '; S1='  u______n  ' ;; esac
S2=" ( ${L}    ${R} ) "; S3=" (   ${NOSE}   ) "; S4="  \`------${BACK}  "

if [ "${SB_BUDDY_ASCII:-off}" = "on" ]; then TL='+'; TR='+'; BL='+'; BR='+'; H='-'; V='|'; TAIL='--'
else TL='╭'; TR='╮'; BL='╰'; BR='╯'; H='─'; V='│'; TAIL='──'; fi

# Bubble text: the live event line. Nothing live → no box (the native bubble came and went; a
# filler line would be neither a delivery, a gate, nor a capture).
BUBBLE="$LINE"
# Row = 2 + │ + space + text(BW) + space + │ + 3 (gap or tail) + sprite(12) = BW + 21 ≤ USABLE.
BW=$(( USABLE - 21 )); [ "$BW" -gt 64 ] && BW=64
W1=""; W2=""; W3=""
for w in $BUBBLE; do                                   # set -f above: no globbing here
  if   [ $(( ${#W1} + ${#w} + 1 )) -le "$BW" ] && [ -z "$W2" ]; then W1="${W1:+$W1 }$w"
  elif [ $(( ${#W2} + ${#w} + 1 )) -le "$BW" ] && [ -z "$W3" ]; then W2="${W2:+$W2 }$w"
  elif [ $(( ${#W3} + ${#w} + 1 )) -le "$BW" ]; then W3="${W3:+$W3 }$w"
  else _trunc W3 "$W3 $w" "$BW"; break; fi
done
_pad P1 "$W1" "$BW"; _pad P2 "$W2" "$BW"; _pad P3 "$W3" "$BW"
RULE=""; i=0; while [ "$i" -lt $(( BW + 2 )) ]; do RULE="$RULE$H"; i=$(( i + 1 )); done
_pad GAP "" $(( BW + 7 ))
# Name under the sprite: centred on its 12 columns, or ending at its right edge when longer (a
# 13-14 char name must not overhang the row width).
if [ "${#NAME}" -le 12 ]; then NL=$(( BW + 7 + (12 - ${#NAME}) / 2 )); else NL=$(( BW + 19 - ${#NAME} )); fi
_pad NLEAD "" "$NL"
if [ -z "$BUBBLE" ]; then   # nothing live: the capybara alone, in the same column
  for S in "$S0" "$S1" "$S2" "$S3" "$S4"; do printf '  %s%s%s%s\n' "$GAP" "$FUR" "$S" "$RST"; done
  printf '  %s%s%s%s\n' "$NLEAD" "$DIM" "$NAME" "$RST"
  exit 0
fi
# Every sprite row starts at the same column: closing glyph + 3-col gap (the eyes row's gap IS the tail).
printf '  %s%s%s%s%s   %s%s%s\n'          "$DIM" "$TL" "$RULE" "$TR" "$RST" "$FUR" "$S0" "$RST"
printf '  %s%s%s %s%s%s %s%s%s   %s%s%s\n' "$DIM" "$V" "$RST" "$C" "$P1" "$RST" "$DIM" "$V" "$RST" "$FUR" "$S1" "$RST"
printf '  %s%s%s %s%s%s %s%s%s%s %s%s%s\n' "$DIM" "$V" "$RST" "$C" "$P2" "$RST" "$DIM" "$V" "$TAIL" "$RST" "$FUR" "$S2" "$RST"
printf '  %s%s%s %s%s%s %s%s%s   %s%s%s\n' "$DIM" "$V" "$RST" "$C" "$P3" "$RST" "$DIM" "$V" "$RST" "$FUR" "$S3" "$RST"
printf '  %s%s%s%s%s   %s%s%s\n'          "$DIM" "$BL" "$RULE" "$BR" "$RST" "$FUR" "$S4" "$RST"
printf '  %s%s%s%s\n'                     "$NLEAD" "$DIM" "$NAME" "$RST"
exit 0
