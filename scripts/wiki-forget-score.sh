#!/usr/bin/env bash
# Composite importance per wiki page (offline signals only; NO embeddings).
# Lower score = more forgettable. Output TSV (sorted ascending):
#   score<TAB>slug<TAB>path<TAB>reasons<TAB>protflag
# protflag is empty when the page is eligible for forgetting; otherwise a
# comma-list of PROTECT:category|age|linked. Signals: access-count (sparse-ok),
# recency (mtime), connectivity (inbound [[links]]), category weight + stub floor.
set -u
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"; KD="${KD/#\~/$HOME}"; WIKI="$KD/wiki"
BD="${BRAIN_DIR:-$HOME/.second-brain}"; AC="$BD/access-counts.json"
MINAGE="${SB_FORGET_MIN_AGE_DAYS:-30}"
WA="${SB_FORGET_W_ACCESS:-0.30}"; WR="${SB_FORGET_W_RECENCY:-0.25}"
WC="${SB_FORGET_W_CONNECTIVITY:-0.25}"; WG="${SB_FORGET_W_CATEGORY:-0.20}"
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
  age=$(( (now - $(stat -c %Y "$f")) / 86400 )); body=$(wc -c < "$f")
  inb=$(inbound "$slug"); acc=$(acount "$slug")
  # Pass values via -v + coerce to number (x=x+0) so an empty/sparse value can't produce a
  # mawk "syntax error at or near ;" (do NOT string-interpolate into the awk program).
  s_acc=$(awk -v a="$acc" 'BEGIN{a=a+0; v=(a<=0)?0:(log(a+1)/log(20)); print (v>1)?1:v}')
  s_rec=$(awk -v d="$age" 'BEGIN{d=d+0; print (d>=180)?0:(1-d/180)}')
  s_con=$(awk -v c="$inb" 'BEGIN{c=c+0; print (c>=3)?1:c/3}')
  case "$cat" in
    learnings|decisions|concepts|themes) s_cat=1.0; prot="PROTECT:category";;
    entities|sources|patterns|issues) s_cat=0.5; prot="";;
    *) s_cat=0.2; prot="";;
  esac
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
