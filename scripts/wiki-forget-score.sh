#!/usr/bin/env bash
# Composite importance per wiki page (offline signals only; NO embeddings).
# Lower score = more forgettable. Output TSV (sorted ascending):
#   score<TAB>slug<TAB>path<TAB>reasons<TAB>protflag
# protflag is empty when the page is eligible for forgetting; otherwise a
# comma-list of PROTECT:category|age|linked. Signals: access-count (sparse-ok),
# recency (mtime), connectivity (inbound [[links]]), category weight + stub floor.
set -u
# Category protection tiers come from the KB source of truth (kb-schema.json). Fallbacks below are
# identical to the manifest and only used if jq/the manifest is unavailable (fail-safe: same tiers).
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]:-$0}")/kb-schema.sh" 2>/dev/null || true
: "${SB_FORGET_PROTECTED:=learnings decisions concepts security themes projects}"
: "${SB_FORGET_DISCOUNTED:=entities sources issues}"
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"; KD="${KD/#\~/$HOME}"; WIKI="$KD/wiki"
BD="${BRAIN_DIR:-$HOME/.second-brain}"; AC="$BD/access-counts.json"
MINAGE="${SB_FORGET_MIN_AGE_DAYS:-30}"
WA="${SB_FORGET_W_ACCESS:-0.30}"; WR="${SB_FORGET_W_RECENCY:-0.25}"
WC="${SB_FORGET_W_CONNECTIVITY:-0.25}"; WG="${SB_FORGET_W_CATEGORY:-0.20}"
# Recency decay window (days): s_rec ramps 1 (fresh) → 0 at this horizon. Was a
# hard-coded 180, which — against the 0.15 candidate floor plus the category
# floor (0.04–0.10) — left a page above the floor until ~110+ days old (never,
# for discounted types), so FORGET emitted zero candidates for any realistic
# corpus. 90d lets a ~3-month unaccessed orphan reach s_rec≈0 → its score
# collapses to the category floor, well under 0.15.
REC_FULL_DAYS="${SB_FORGET_RECENCY_DAYS:-90}"
command -v jq >/dev/null 2>&1 || { echo "forget-score: jq missing" >&2; exit 2; }
[ -d "$WIKI" ] || { echo "forget-score: no wiki at $WIKI" >&2; exit 2; }
now=$(date +%s)
links=$(grep -rhoE '\[\[[^]]+\]\]' "$WIKI" 2>/dev/null | sed -E 's/\[\[|\]\]//g' | sort | uniq -c)
inbound(){ printf '%s\n' "$links" | awk -v s="$1" '$2==s{print $1; f=1} END{if(!f)print 0}' | head -1; }
# access-counts.json stores {slug: {count, last_accessed}} (older builds used a flat
# number); read .count first, fall back to a bare number, else 0.
acount(){ local v; v=$( [ -s "$AC" ] && jq -r --arg s "$1" '(.[$s].count // .[$s] // 0)' "$AC" 2>/dev/null ); echo "${v:-0}"; }

find "$WIKI" -type f -name '*.md' ! -name 'index.md' -not -path '*/.*' | while read -r f; do
  slug=$(basename "$f" .md); cat=$(basename "$(dirname "$f")")
  mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")  # GNU || BSD/macOS
  age=$(( (now - mt) / 86400 ))
  # body byte-count is PROSE-ONLY: strip the authored ai-block so a uniform block can't lift
  # every page over the stub floor (spec §5b). Only strip when a COMPLETE block exists (a
  # closing ai:end is present) — an unterminated ai:begin is NOT a block, so it stays a raw
  # byte-exact count (matches the TS stripAiBlock no-op; never eats a real page toward FORGET).
  if grep -qE '<!--[[:space:]]*ai:end[[:space:]]*-->' "$f"; then
    body=$(awk '
      /<!--[[:space:]]*ai:begin/ { skip=1 }
      skip==1 { if ($0 ~ /<!--[[:space:]]*ai:end[[:space:]]*-->/) skip=0; next }
      { print }
    ' "$f" | wc -c)
  else
    body=$(wc -c < "$f")
  fi
  inb=$(inbound "$slug"); acc=$(acount "$slug")
  # Pass values via -v + coerce to number (x=x+0) so an empty/sparse value can't produce a
  # mawk "syntax error at or near ;" (do NOT string-interpolate into the awk program).
  s_acc=$(awk -v a="$acc" 'BEGIN{a=a+0; v=(a<=0)?0:(log(a+1)/log(20)); print (v>1)?1:v}')
  s_rec=$(awk -v d="$age" -v w="$REC_FULL_DAYS" 'BEGIN{d=d+0; w=w+0; if(w<=0)w=90; print (d>=w)?0:(1-d/w)}')
  s_con=$(awk -v c="$inb" 'BEGIN{c=c+0; print (c>=3)?1:c/3}')
  # Category protection tier from kb-schema.json: PROTECTED -> never forget; DISCOUNTED -> mild;
  # else default. (Fixes the old hardcoded case that omitted `security` -> 0.2 and listed a dead
  # `patterns` category.)
  s_cat=0.2; prot=""
  case " $SB_FORGET_PROTECTED " in *" $cat "*) s_cat=1.0; prot="PROTECT:category";; esac
  [ -z "$prot" ] && case " $SB_FORGET_DISCOUNTED " in *" $cat "*) s_cat=0.5;; esac
  # auto-generated noise (ULID evolve logs, session-narrative) is forgettable even
  # inside an otherwise-protected category — clear the category protection (age +
  # inbound-link protections and the recall probe still guard it).
  case "$slug" in evolve-01*|*session*) s_cat=0.1; prot="";; esac
  [ "$body" -lt 200 ] && s_cat=$(awk -v x="$s_cat" 'BEGIN{x=x+0; print (x<0.2)?x:0.2}')
  score=$(awk -v wa="$WA" -v wr="$WR" -v wc="$WC" -v wg="$WG" -v sa="$s_acc" -v sr="$s_rec" -v sc="$s_con" -v sg="$s_cat" \
    'BEGIN{printf "%.3f", (wa+0)*(sa+0)+(wr+0)*(sr+0)+(wc+0)*(sc+0)+(wg+0)*(sg+0)}')
  pf="$prot"
  [ "$age" -lt "$MINAGE" ] && pf="${pf:+$pf,}PROTECT:age"
  [ "$inb" -gt 0 ] && pf="${pf:+$pf,}PROTECT:linked"
  printf '%s\t%s\t%s\tacc=%s inb=%s age=%sd cat=%s body=%sb\t%s\n' \
    "$score" "$slug" "$f" "$acc" "$inb" "$age" "$cat" "$body" "$pf"
done | sort -n
