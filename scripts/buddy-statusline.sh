#!/bin/bash
# buddy-statusline.sh — the second-brain buddy: a Claude Code statusLine renderer.
# Design: docs/plans/2026-09-22-buddy-companion.md. The buddy is the visible layer between Claude
# and the knowledge base: the line(s) directly under the input box show what memory delivered,
# what Claude read or saved through the MCP tools, which gate is holding, and what waits on the
# user — state the hooks and the server already keep. Zero tokens, no LLM, no hook: it only READS.
#
# Install: `sb buddy install` (writes settings.json statusLine → ~/.second-brain/bin shim → this
# script, backs settings up, chains an existing statusline). Plugins cannot declare statusLine.
# A chained statusline arrives as SB_BUDDY_CHAIN in the environment of the audited settings.json
# command — never from a data file under ~/.second-brain, which nothing guards.
#
# HOT PATH: Claude Code re-runs this on every TUI state change (~300 ms debounce; an update that
# arrives mid-run cancels it). Budget: two jq spawns at most (sid, then everything), no other
# subprocess, bash builtins for all string work, five small files at most. Reads:
# $BRAIN_DIR/buddy.json (identity, name, mute, sprite), .buddy/<sid>.json (session event),
# .buddy/_global.json (MCP + session-agnostic events), .injected/<sid>.json + .phase (goal,
# phase). Width: SB_BUDDY_COLS > COLUMNS (Claude Code sets it) > 120. Layout: ≥ 90 cols →
# telemetry + bubble + sprite; < 90 → telemetry (+ one dim line).
# Kill: SB_BUDDY=off prints nothing; SB_BUDDY_SPRITE=off / SB_HOOK_PROFILE=minimal → telemetry
# only; SB_BUDDY_ASCII=on avoids box glyphs; NO_COLOR drops colour.
set -u
set -f   # event lines are transcript-derived text: never let `*`/`?`/`[` glob against the cwd
[ "${SB_BUDDY:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ "${SB_HOOK_PROFILE:-}" = "minimal" ] && SB_BUDDY_SPRITE=off   # lib-less script: profile shim

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
command -v cygpath >/dev/null 2>&1 && BRAIN_DIR=$(cygpath -u "$BRAIN_DIR" 2>/dev/null || printf '%s' "$BRAIN_DIR")

RAW=""
[ -t 0 ] || IFS= read -r -t 2 -d '' RAW || true      # the payload is one line; -d '' reads to EOF
RAW="${RAW//$'\r'/}"
# Epoch seconds without a subprocess (bash ≥ 4.2); `date` only for bash 3.2.
if printf -v now '%(%s)T' -1 2>/dev/null && [[ "$now" =~ ^[0-9]+$ ]]; then :; else now=$(date +%s); fi

_f() { [ -f "$1" ] && printf '%s' "$1" || printf '%s' /dev/null; }   # --rawfile needs a path
SID=""
if [ -n "$RAW" ]; then SID=$(printf '%s' "$RAW" | jq -r '.session_id // ""' 2>/dev/null) || SID=""; fi
SID="${SID//[^A-Za-z0-9_-]/}"; SID="${SID:0:64}"
CFG=$(_f "$BRAIN_DIR/buddy.json"); CUR=$(_f "$BRAIN_DIR/.buddy/$SID.json"); GLB=$(_f "$BRAIN_DIR/.buddy/_global.json")
MEMO=$(_f "$BRAIN_DIR/.injected/$SID.json")
PHASE=""; [ -f "$BRAIN_DIR/.injected/$SID.phase" ] && { IFS= read -r PHASE < "$BRAIN_DIR/.injected/$SID.phase" 2>/dev/null || true; }
PHASE="${PHASE//[^a-z]/}"

# Fields joined with US (\x1f): `read` collapses runs of whitespace separators, so a tab would
# swallow empty fields and shift every later one. Each file is parsed on its own (`try fromjson`)
# so one torn file never blanks the others.
US=$'\x1f'
IFS="$US" read -r MODEL CTX NAME MUTE SPRITE_CFG SPECIES EYE HAT RARITY SHINY GOAL LINE KIND MOOD < <(
  jq -rn --arg raw "$RAW" --argjson now "$now" \
    --rawfile c "$CFG" --rawfile e "$CUR" --rawfile g "$GLB" --rawfile m "$MEMO" '
    def j: try fromjson catch {};
    def scrub: gsub("[\u0001-\u001f\u007f-\u009f]"; " ");
    def live: select(type=="object" and has("line") and ((.ttl_s // 900) == 0 or ($now - (.ts // 0)) <= (.ttl_s // 900)));
    ($raw | j) as $in | ($c | j) as $c | ($m | j) as $m
    | ([($e | j), ($g | j)] | map(live)) as $ev
    # a fresh ACTIVE session gate holds the bubble; otherwise the newest live event of either key wins
    | ( ($ev | map(select(.kind=="gate" and .mood!="pleased" and ($now - .ts) < 60)) | first) // ($ev | sort_by(.ts) | last) // {} ) as $x
    | [ ($in.model.display_name // $in.model.id // ""),
        (($in.context_window.used_percentage // null) | if . == null then "" else (tostring | split(".")[0]) end),
        ((if ($c.name // "") == "" then null else $c.name end) // $c.identity.default_name // "buddy"),
        (if ($c.mute // false) == true then "1" else "0" end),
        (if ($c.sprite // true) == false then "off" else "on" end),
        ($c.identity.species // ""), ($c.identity.eye // ""), ($c.identity.hat // "none"),
        ($c.identity.rarity // ""), (if ($c.identity.shiny // false) == true then "1" else "0" end),
        (($m.goal // "") | scrub),
        (($x.line // "") | scrub), ($x.kind // ""), ($x.mood // "focused") ]
    | map(tostring | gsub("[\n\r\u001f]"; " ")) | join("\u001f")' 2>/dev/null
) || true
MOOD="${MOOD//$'\r'/}"   # Windows jq ends the line \r\n: the CR lands in the LAST field and no mood case matches
: "${MODEL:=}" "${CTX:=}" "${NAME:=buddy}" "${MUTE:=0}" "${SPRITE_CFG:=on}" "${SPECIES:=}" "${EYE:=}" \
  "${HAT:=none}" "${RARITY:=}" "${SHINY:=0}" "${GOAL:=}" "${LINE:=}" "${KIND:=}" "${MOOD:=focused}"

# --- width: what Claude Code exports, or the override; no tput/stty (no tty in the captured run) --
COLS="${SB_BUDDY_COLS:-${COLUMNS:-}}"
[[ "$COLS" =~ ^[0-9]+$ ]] || COLS=120
USABLE=$(( COLS - 14 )); [ "$USABLE" -lt 40 ] && USABLE=40   # ~14 cols of content-box chrome

if [ -n "${NO_COLOR:-}" ]; then DIM=""; ACC=""; WARN=""; OK=""; RST=""
else DIM=$'\e[2m'; ACC=$'\e[38;2;139;92;246m'; WARN=$'\e[38;2;245;158;11m'; OK=$'\e[38;2;16;185;129m'; RST=$'\e[0m'; fi

# --- line 0: chained statusline (from the settings.json command's own environment) -------------
if [ -n "${SB_BUDDY_CHAIN:-}" ]; then
  printf '%s' "$RAW" | bash -c "$SB_BUDDY_CHAIN" 2>/dev/null | head -n 3 || true
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

# --- lines 2–5: bubble + sprite (wide terminals only; mute = telemetry only) -------------------
[ "$MUTE" = "1" ] && exit 0
[ "${SB_BUDDY_SPRITE:-$SPRITE_CFG}" = "off" ] && exit 0
if [ "$USABLE" -lt 76 ]; then [ -n "$LINE" ] && { _trunc L1 "$LINE" $(( USABLE - 4 )); printf '  %s%s%s\n' "$DIM" "$L1" "$RST"; }; exit 0; fi

# Sprite: three rows, ≤ 9 cols, from the cached account-hash identity (buddy.json.identity —
# mcp/src/buddy-identity.ts, hatched by `sb buddy`). {L}/{R} are the eyes: the identity's glyph
# when focused, a mood pair otherwise. A hat (uncommon+) replaces the head-top row.
case "$MOOD" in
  alert)   L='ò'; R='ó' ;;
  pleased) L='^'; R='^' ;;
  waiting) L='-'; R='-' ;;
  puzzled) L="${EYE:-°}"; R='ô' ;;
  *)       L="${EYE:-°}"; R="${EYE:-°}" ;;
esac
case "$SPECIES" in
  duck)     S1='   __    '; S2='<({L} {R})___'; S3='  (  ._> ' ;;
  goose)    S1='   ({L}{R}>  '; S2='    ||   '; S3='  _(__)_ ' ;;
  cat)      S1='  /\_/\  '; S2=' ={L} ω {R}= '; S3=' (")_(") ' ;;
  dragon)   S1=' /^\  /^\'; S2='< {L}  {R} >'; S3=' `-vvvv-´' ;;
  octopus)  S1='  .----. '; S2=' ( {L}  {R} )'; S3=' /\/\/\/\' ;;
  owl)      S1='  /\  /\ '; S2=' (({L})({R}))'; S3='  `----´ ' ;;
  penguin)  S1='  .---.  '; S2='  ({L}>{R})  '; S3=' /(   )\ ' ;;
  turtle)   S1='  _,--._ '; S2=' ( {L}  {R} )'; S3=' [______]' ;;
  snail)    S1=' {L}{R} .--.'; S2=' \ ( @ ) '; S3=' ~~~~~~~ ' ;;
  ghost)    S1='  .----. '; S2=' / {L}  {R} \'; S3=' ~`~``~`~' ;;
  axolotl)  S1='~(_____)~'; S2='~({L} . {R})~'; S3=' (_/ \_) ' ;;
  capybara) S1=' n_____n '; S2=' ( {L}  {R} )'; S3=' (  oo  )' ;;
  cactus)   S1=' n  _  n '; S2=' |{L}   {R}| '; S3='   |___| ' ;;
  robot)    S1='  .[||]. '; S2=' [ {L}  {R} ]'; S3=' [ ==== ]' ;;
  rabbit)   S1='  (\__/) '; S2=' ( {L}  {R} )'; S3=' (")__(")' ;;
  mushroom) S1='.-o-OO-o.'; S2='(_______)'; S3='  |{L}  {R}| ' ;;
  chonk)    S1=' /\    /\'; S2=' ( {L}  {R} )'; S3='  `----´ ' ;;
  *)        S1='  .----. '; S2=' ( {L}  {R} )'; S3='  `-oo-´ ' ;;   # blob, and the no-identity default
esac
case "$HAT" in
  crown)     S1='  \^^^/  ' ;;  tophat)  S1='  [___]  ' ;;  propeller) S1='   -+-   ' ;;
  halo)      S1='  (   )  ' ;;  wizard)  S1='   /^\   ' ;;  beanie)    S1='  (___)  ' ;;
  tinyduck)  S1='   ,>    ' ;;
esac
S1="${S1//\{L\}/$L}"; S1="${S1//\{R\}/$R}"
S2="${S2//\{L\}/$L}"; S2="${S2//\{R\}/$R}"
S3="${S3//\{L\}/$L}"; S3="${S3//\{R\}/$R}"
case "$RARITY" in
  uncommon)  SPC="$OK";  STARS='★★' ;;      rare)      SPC=$'\e[38;2;59;130;246m'; STARS='★★★' ;;
  epic)      SPC="$ACC"; STARS='★★★★' ;;    legendary) SPC=$'\e[38;2;234;179;8m';  STARS='★★★★★' ;;
  common)    SPC="$DIM"; STARS='★' ;;       *)         SPC="$ACC"; STARS='' ;;
esac
[ -n "${NO_COLOR:-}" ] && SPC=""
[ "$SHINY" = "1" ] && STARS="✨$STARS"
SPW=10
if [ "${SB_BUDDY_ASCII:-off}" = "on" ]; then TL='+'; TR='+'; BL='+'; BR='+'; H='-'; V='|'; TAIL='--'
else TL='╭'; TR='╮'; BL='╰'; BR='╯'; H='─'; V='│'; TAIL='──'; fi

# Bubble text: the event line, or the ambient state when nothing is live.
BUBBLE="$LINE"
if [ -z "$BUBBLE" ]; then
  case "$PHASE" in
    plan)      BUBBLE="Say the plan — goal, files, verify command — and I'll keep us on it." ;;
    implement) BUBBLE="Implementing. Memory reads and saves show here; tests flip me to verify." ;;
    verify)    BUBBLE="Verifying — evidence before assertions." ;;
    *)         BUBBLE="Hot tier loaded. I'll show what memory delivers, what Claude reads, what gets saved." ;;
  esac
fi
BW=$(( USABLE - SPW - 6 )); [ "$BW" -gt 64 ] && BW=64
W1=""; W2=""
for w in $BUBBLE; do                                   # set -f above: no globbing here
  if [ $(( ${#W1} + ${#w} + 1 )) -le "$BW" ]; then W1="${W1:+$W1 }$w"
  elif [ $(( ${#W2} + ${#w} + 1 )) -le "$BW" ]; then W2="${W2:+$W2 }$w"
  else _trunc W2 "$W2 $w" "$BW"; break; fi
done
_pad P1 "$W1" "$BW"; _pad P2 "$W2" "$BW"
RULE=""; i=0; while [ "$i" -lt $(( BW + 2 )) ]; do RULE="$RULE$H"; i=$(( i + 1 )); done
C="$DIM"; case "$KIND" in gate|guard|stumble) C="$WARN" ;; remembered|delivered|pending|read|retrieved) C="$OK" ;; esac
# Every sprite row starts at the same column: closing glyph + 3-col gap (row 2's gap IS the tail).
printf '  %s%s%s%s%s   %s\n'              "$DIM" "$TL" "$RULE" "$TR" "$RST" "$S1"
printf '  %s%s%s %s%s%s %s%s%s%s %s%s%s\n' "$DIM" "$V" "$RST" "$C" "$P1" "$RST" "$DIM" "$V" "$TAIL" "$RST" "$SPC" "$S2" "$RST"
printf '  %s%s%s %s%s%s %s%s%s   %s\n'    "$DIM" "$V" "$RST" "$C" "$P2" "$RST" "$DIM" "$V" "$RST" "$S3"
printf '  %s%s%s%s%s   %s%s %s%s\n'       "$DIM" "$BL" "$RULE" "$BR" "$RST" "$DIM" "$NAME" "$STARS" "$RST"
exit 0
