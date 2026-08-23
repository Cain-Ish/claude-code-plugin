#!/usr/bin/env bash
# Importance per wiki page (offline signals only; NO embeddings). Lower score = more
# forgettable. Output TSV (sorted: score ASC, then age DESC as a recency tie-break):
#   score<TAB>slug<TAB>path<TAB>reasons<TAB>protflag
# protflag is empty when the page is eligible for forgetting; otherwise a
# comma-list of PROTECT:category|age|linked.
#
# v4 redundancy/importance correction (spec 2026-06-26 §3, "CORRECTED v4"): the eviction
# score is STRUCTURAL IMPORTANCE only — connectivity (inbound [[links]]) + category weight +
# stub floor. Usage-frequency (access-count) is NOT scored — it is the recsys
# "rich-get-richer" hub bias (the ~10,000x search-boost bug class), shown only as `acc=`
# telemetry. Recency (mtime) does NOT drive the score either; it survives ONLY as (a) the
# PROTECT:age safety floor and (b) the age-DESC tie-break in the final sort ("recency may break
# ties, never drive eviction"). REDUNDANCY is the orthogonal gate downstream in
# wiki-forget-candidates.sh (the live recall-probe), so the forget set = low structural
# importance AND recall-redundant ("dedup-merge + low importance", as a conjunction).
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
# Importance weights (connectivity + category only; v4 dropped the access & recency terms).
# Kept at their original 0.25/0.20 values so the eviction boundary is UNCHANGED for the pages
# FORGET actually targets — old, unaccessed orphans already had s_acc=0 and s_rec=0, so
# removing those two terms moves their score by exactly 0. The behavioral change is only that a
# *recent or frequently-read* low-importance orphan is no longer rescued by recency/frequency
# (the v4 correction); PROTECT:age still hard-protects genuinely fresh (<MINAGE) pages.
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
  # Age from the page's OWN `created:` frontmatter, mtime only as a fallback. Aging by mtime
  # made FORGET structurally inert: shipped maintenance (reindex frontmatter patching, graph
  # projection, backfills) bulk-touches every page, so ALL pages read as fresh and PROTECT:age
  # fired on 100% of the corpus — measured live 2026-08-23: 457/457 pages carried that day's
  # mtime while created: dates spanned 2026-04..2026-08. FORGET had never archived one page.
  # created: forms seen in the wiki: "2026-04-27" and "2026-08-23T11:09:15Z" — take the date
  # part; strict-parse both GNU (date -d) and BSD (date -j -f) before trusting it.
  created=$(sed -n '/^---$/,/^---$/{s/^created:[[:space:]]*"\{0,1\}\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p;}' "$f" | head -1)
  mt=""
  if [ -n "$created" ]; then
    mt=$(date -d "$created" +%s 2>/dev/null || date -j -f '%Y-%m-%d' "$created" +%s 2>/dev/null)
  fi
  [ -n "$mt" ] || mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")  # GNU || BSD/macOS
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
  # access-count (acc) is read for telemetry ONLY (the `acc=` reason field) — it is deliberately
  # NOT folded into the score (v4: usage-frequency is the rich-get-richer hub bias). Recency is
  # likewise unscored (age drives only PROTECT:age + the tie-break). Pass values via -v + coerce
  # to number (x=x+0) so an empty/sparse value can't produce a mawk "syntax error at or near ;".
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
  score=$(awk -v wc="$WC" -v wg="$WG" -v sc="$s_con" -v sg="$s_cat" \
    'BEGIN{printf "%.3f", (wc+0)*(sc+0)+(wg+0)*(sg+0)}')
  pf="$prot"
  [ "$age" -lt "$MINAGE" ] && pf="${pf:+$pf,}PROTECT:age"
  [ "$inb" -gt 0 ] && pf="${pf:+$pf,}PROTECT:linked"
  # Prepend age as a sort-only column; the sort below uses it as the age-DESC recency
  # tie-break, then `cut -f2-` strips it so the emitted columns are unchanged.
  printf '%s\t%s\t%s\t%s\tacc=%s inb=%s age=%sd cat=%s body=%sb\t%s\n' \
    "$age" "$score" "$slug" "$f" "$acc" "$inb" "$age" "$cat" "$body" "$pf"
# score ASC (primary), then age DESC (recency tie-break) — recency only breaks ties, never
# drives eviction (v4). Explicit secondary key avoids relying on a stable sort (BSD sort isn't).
done | sort -t$'\t' -k2,2n -k1,1nr | cut -f2-
