#!/bin/bash
# buddy-statusline.sh — the second-brain buddy: a Claude Code statusLine renderer.
# Design: docs/plans/2026-09-22-buddy-companion.md (thought-cloud redesign: 2026-09-26). The buddy
# is the layer between Claude and the knowledge base, both ways: the lines directly under the input
# box show what memory delivered, what Claude read or saved through the MCP tools, which gate is
# holding, what waits on the user, and what Claude itself said to the user through `buddy_react`.
# It only READS: zero tokens, no LLM.
#
# Layout: line 1 is always the telemetry line (🧠 goal · phase · ctx% · model). While Claude is
# working on this turn, a fixed 3-column dot slot right after 🧠 animates (·, ··, ···, one step per
# epoch second) — driven by $BRAIN_DIR/.buddy/<sid>.busy, written by persona-context.sh at the very
# start of UserPromptSubmit and cleared by sar-summary.sh on every Stop. When a line is LIVE (the
# same gate-holds-then-said-holds-then-newest-live selection as before), a thought cloud hangs below
# the brain: a small steam dot, a bigger one, then the box, ≤3 word-wrapped rows. Nothing live →
# line 1 alone, no empty box. Narrow terminals (< 76 usable cols or < 30 rows) collapse the cloud
# to one row: ` ○ <line, truncated>` (or nothing, when nothing is live).
#
# Install: `sb buddy install` (settings.json statusLine → ~/.second-brain/bin shim → this script,
# refreshInterval 1, settings backed up, an existing statusline chained). A chained statusline
# arrives as SB_BUDDY_CHAIN in the environment of the audited settings.json command — never from a
# data file under ~/.second-brain, which nothing guards. Its output is cached for 5 s per session
# (.buddy/<sid>.chain), so the per-second animation tick does not re-run it every second.
#
# HOT PATH (runs every second): ONE jq spawn, no other subprocess on a cached tick, bash builtins
# for all string work. Reads $BRAIN_DIR/buddy.json (name, mute, sprite), .buddy/<sid>.json,
# .buddy/_global.json, .buddy/<sid>.busy, .injected/<sid>.json + .phase. Width: SB_BUDDY_COLS >
# COLUMNS > 120.
# Kill: SB_BUDDY=off prints nothing; SB_BUDDY_SPRITE=off / SB_HOOK_PROFILE=minimal → telemetry line
# only (no cloud, no dots — "sprite" now names the thought cloud, kept for config compatibility);
# NO_COLOR drops colour. SB_BUDDY_NOW pins the clock (tests: the animation is a pure function of
# the epoch second).
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

if [ -n "${NO_COLOR:-}" ]; then DIM=""; ACC=""; WARN=""; OK=""; SAID=""; RST=""
else DIM=$'\e[2m'; ACC=$'\e[38;2;139;92;246m'; WARN=$'\e[38;2;245;158;11m'; OK=$'\e[38;2;16;185;129m'
  SAID=$'\e[3;38;2;139;92;246m'; RST=$'\e[0m'; fi

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
    # and the user's statusline vanished for good. A fast chain still lands on this tick (≤ 5 polls
    # of 0.1 s — each sleep is its own process on MSYS, so the tick stays under 1 s); a slow one
    # shows its last output now and its fresh output next tick. A failing chain is
    # logged once per session (quiet on screen, loud in the log).
    (
      _out=$(printf '%s' "$RAW" | bash -c "$SB_BUDDY_CHAIN" 2> "$CHF.err.$$"); _rc=$?
      printf '%s\n%s' "$now" "$_out" > "$CHF.$$" 2>/dev/null && { mv -f "$CHF.$$" "$CHF" 2>/dev/null || rm -f "$CHF.$$" 2>/dev/null; }
      if [ "$_rc" -ne 0 ] && [ ! -e "$CHF.logged" ]; then
        : > "$CHF.logged"; _e=""; IFS= read -r _e < "$CHF.err.$$" 2>/dev/null
        _row=$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg m "chained statusline exited $_rc: ${_e:0:200}" \
          --argjson rc "$_rc" '{timestamp: $ts, script: "buddy-statusline.sh", message: $m, exit_code: $rc}' 2>/dev/null)
        _row="${_row//$'\r'/}"   # Windows jq: \r\n
        [ -n "$_row" ] && printf '%s\n' "$_row" >> "$BRAIN_DIR/error-log.jsonl" 2>/dev/null
      fi
      rm -f "$CHF.err.$$" 2>/dev/null
    ) < /dev/null > /dev/null 2>&1 &
    _pid=$!
    for _i in 1 2 3 4 5; do kill -0 "$_pid" 2>/dev/null || break; sleep 0.1; done
    CH="$_old"
    if ! kill -0 "$_pid" 2>/dev/null; then { IFS= read -r _x; IFS= read -r -d '' CH; } < "$CHF" 2>/dev/null || true; fi
  elif [ "$HIT" = "0" ]; then
    CH=$(printf '%s' "$RAW" | bash -c "$SB_BUDDY_CHAIN" 2>/dev/null) || true   # no session key: nowhere to cache
  fi
  if [ -n "$CH" ]; then
    _n=0; while IFS= read -r _l && [ "$_n" -lt 3 ]; do printf '%s\n' "$_l"; _n=$(( _n + 1 )); done <<< "$CH"
  fi
fi

# --- effective sprite/mute state, computed ahead of line 1: the thinking-dot slot and the thought
# cloud both key off it. SB_BUDDY_SPRITE=off / SB_HOOK_PROFILE=minimal (already mapped above) and
# mute all mean the same "telemetry only" they always did — "sprite" now names the thought cloud
# rather than a capybara, kept as a config key for compatibility.
SPRITE_OFF=0; [ "${SB_BUDDY_SPRITE:-$SPRITE_CFG}" = "off" ] && SPRITE_OFF=1

# --- thinking animation: a fixed 3-column dot slot right after 🧠, one step per epoch second,
# while $BRAIN_DIR/.buddy/<sid>.busy holds the epoch of the last UserPromptSubmit (written by
# persona-context.sh) and no Stop (sar-summary.sh) has cleared it since. Stale (no dots) when the
# marker is older than 600 s, or when a fresh `said` event (Claude's own buddy_react, ETS) is newer
# than the marker — the turn that marker announced has already ended. A muted or sprite-off buddy
# shows no dots either, same as it shows no bubble. Builtins only: `read` slurps the one-line marker.
DOTS_SUF=""
if [ "$MUTE" != "1" ] && [ "$SPRITE_OFF" != "1" ] && [ -n "$SID" ]; then
  BUSYF="$BRAIN_DIR/.buddy/$SID.busy"
  if [ -f "$BUSYF" ]; then
    BM=""; IFS= read -r BM < "$BUSYF" 2>/dev/null || true
    if [[ "$BM" =~ ^[0-9]+$ ]] && [ $(( now - BM )) -lt 600 ] && { [ "$KIND" != "said" ] || [ "$ETS" -le "$BM" ]; }; then
      # F4 (portability): fixed literals, not a byte-counting pad loop — `·` is 2 bytes in UTF-8,
      # so `${#DOTS_SUF}` counts BYTES (not glyphs) under a C/no locale, common when Claude Code
      # is launched from PowerShell/cmd. The old `while [ "${#DOTS_SUF}" -lt 3 ]` loop then built
      # 2/2/3 glyphs across the three phases instead of a fixed 3 (the byte count hit 3 before a
      # real 3rd glyph was added), so the dot slot — and everything after it on line 1 — shifted
      # width every 3 s.
      case $(( now % 3 + 1 )) in 1) DOTS_SUF='·  ' ;; 2) DOTS_SUF='·· ' ;; *) DOTS_SUF='···' ;; esac
    fi
  fi
fi

# --- line 1: telemetry — goal · phase · ctx% · model ------------------------------------------
_trunc() { local s="$2" n="$3"; [ "${#s}" -gt "$n" ] && s="${s:0:$((n-1))}…"; printf -v "$1" '%s' "$s"; }
_pad()   { local s="$2" n="$3"; while [ "${#s}" -lt "$n" ]; do s="$s "; done; printf -v "$1" '%s' "$s"; }
SUF=""; SUFP=""
[ -n "$PHASE" ] && { SUF="$SUF ${DIM}·${RST} ${ACC}${PHASE}${RST}"; SUFP="$SUFP · $PHASE"; }
if [ -n "$CTX" ]; then c="$OK"; [ "$CTX" -ge 60 ] 2>/dev/null && c="$WARN"; SUF="$SUF ${DIM}·${RST} ctx ${c}${CTX}%${RST}"; SUFP="$SUFP · ctx ${CTX}%"; fi
if [ -n "$MODEL" ] && [ "$USABLE" -ge 70 ]; then SUF="$SUF ${DIM}· ${MODEL}${RST}"; SUFP="$SUFP · $MODEL"; fi
GW=$(( USABLE - ${#SUFP} - 3 )); [ -n "$DOTS_SUF" ] && GW=$(( GW - 3 )); [ "$GW" -gt 48 ] && GW=48
T="🧠${DOTS_SUF}"
if [ -n "$GOAL" ] && [ "$GW" -ge 12 ]; then _trunc G "$GOAL" "$GW"; T="$T $G"; fi
T="$T$SUF"
[ -z "$GOAL$PHASE" ] && T="$T ${DIM}no goal yet — first coding prompt sets it${RST}"
printf '%s\n' "$T"

# --- the thought cloud (wide) or its one-row cue (narrow); mute / sprite-off = telemetry only --
[ "$MUTE" = "1" ] && exit 0
[ "$SPRITE_OFF" = "1" ] && exit 0
# Only now is the bubble really on screen: .seen tells persona-context to ask Claude for buddy_react.
# Written before the mute/sprite exits, a muted buddy cost a wasted tool call every turn.
[ -n "$SID" ] && [ -d "$BRAIN_DIR/.buddy" ] && [ ! -e "$BRAIN_DIR/.buddy/$SID.seen" ] && { : > "$BRAIN_DIR/.buddy/$SID.seen"; } 2>/dev/null

FRESH=0; [ "$ETS" -gt 0 ] && [ $(( now - ETS )) -ge 0 ] && [ $(( now - ETS )) -lt 10 ] && FRESH=1
C="$DIM"; case "$KIND" in gate|guard|stumble) C="$WARN" ;; said) [ "$FRESH" = "1" ] && C="$SAID" ;; remembered|delivered|pending|read|retrieved) [ "$FRESH" = "1" ] && C="$OK" ;; esac
[ "$KIND" = "said" ] && [ -n "$LINE" ] && LINE="Claude: $LINE"   # never mistakable for a gate or guard line

# Steam-dot colour: warn-toned for a gate/guard/stumble (matches the text's colour), dim otherwise
# — the richer said/remembered/read palette above is for the TEXT, not the steam.
DOTC="$DIM"; case "$KIND" in gate|guard|stumble) DOTC="$WARN" ;; esac
DOT_S='o'; DOT_B='○'; [ "${SB_BUDDY_ASCII:-off}" = "on" ] && DOT_B='O'

ROWS="${LINES:-}"; [[ "$ROWS" =~ ^[0-9]+$ ]] || ROWS=0
if [ "$USABLE" -lt 76 ] || { [ "$ROWS" -gt 0 ] && [ "$ROWS" -lt 30 ]; }; then   # narrow: one steam-dot row, or nothing
  if [ -n "$LINE" ]; then
    _trunc Q "$LINE" $(( USABLE - 4 ))
    printf ' %s%s%s %s%s%s\n' "$DOTC" "$DOT_B" "$RST" "$C" "$Q" "$RST"
  fi
  exit 0
fi

# Bubble text: the live event line. Nothing live → no cloud at all (the native bubble came and
# went; a filler line would be neither a delivery, a gate, nor a capture) — line 1 stands alone.
BUBBLE="$LINE"
[ -z "$BUBBLE" ] && exit 0

if [ "${SB_BUDDY_ASCII:-off}" = "on" ]; then TL='+'; TR='+'; BL='+'; BR='+'; H='-'; V='|'
else TL='╭'; TR='╮'; BL='╰'; BR='╯'; H='─'; V='│'; fi

# Row = 4 (indent) + │ + space + text(BW) + space + │ = BW + 8 ≤ USABLE (no sprite column now).
BW=$(( USABLE - 8 )); [ "$BW" -lt 8 ] && BW=8; [ "$BW" -gt 64 ] && BW=64
W1=""; W2=""; W3=""
for w in $BUBBLE; do                                   # set -f above: no globbing here
  if   [ $(( ${#W1} + ${#w} + 1 )) -le "$BW" ] && [ -z "$W2" ]; then W1="${W1:+$W1 }$w"
  elif [ $(( ${#W2} + ${#w} + 1 )) -le "$BW" ] && [ -z "$W3" ]; then W2="${W2:+$W2 }$w"
  elif [ $(( ${#W3} + ${#w} + 1 )) -le "$BW" ]; then W3="${W3:+$W3 }$w"
  else _trunc W3 "$W3 $w" "$BW"; break; fi
done
RULE=""; i=0; while [ "$i" -lt $(( BW + 2 )) ]; do RULE="$RULE$H"; i=$(( i + 1 )); done

printf ' %s%s%s\n'              "$DOTC" "$DOT_S" "$RST"
printf '  %s%s%s %s%s%s%s%s\n'  "$DOTC" "$DOT_B" "$RST" "$DIM" "$TL" "$RULE" "$TR" "$RST"
_pad P1 "$W1" "$BW"; printf '    %s%s%s %s%s%s %s%s%s\n' "$DIM" "$V" "$RST" "$C" "$P1" "$RST" "$DIM" "$V" "$RST"
if [ -n "$W2" ]; then _pad P2 "$W2" "$BW"; printf '    %s%s%s %s%s%s %s%s%s\n' "$DIM" "$V" "$RST" "$C" "$P2" "$RST" "$DIM" "$V" "$RST"; fi
if [ -n "$W3" ]; then _pad P3 "$W3" "$BW"; printf '    %s%s%s %s%s%s %s%s%s\n' "$DIM" "$V" "$RST" "$C" "$P3" "$RST" "$DIM" "$V" "$RST"; fi
printf '    %s%s%s%s%s\n' "$DIM" "$BL" "$RULE" "$BR" "$RST"
exit 0
