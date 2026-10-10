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
# D7: every page is scored in two awk passes over shared inputs. The old per-page loop started ~10
# processes per page (0.7 s/page on Windows), so a ~950-page wiki overran dream_accept's 600 s timeout.
_t=$(mktemp -d) || { echo "forget-score: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$_t"' EXIT
: > "$_t/acc"; : > "$_t/dates"
# Inbound link counts ("count target" rows). D6: a link target is its slug: drop |alias and
# #heading, a cat/ path prefix, and padding.
grep -rhoE '\[\[[^]]+\]\]' "$WIKI" 2>/dev/null | sed -E 's/\[\[|\]\]//g; s/[|#].*//; s#.*/##; s/^[[:space:]]+//; s/[[:space:]]+$//' | sort | uniq -c > "$_t/links"
# access-counts.json stores {slug: {count, last_accessed}} (older builds used a flat number).
# `//` does not catch jq errors, so a flat number errors on .count and reads 0, as the old
# per-slug lookup did; `try` keeps that one entry from ending the whole listing.
[ -s "$AC" ] && jq -r 'to_entries[] | "\(.key)\t\(try (.value.count // .value // 0) catch 0)"' "$AC" 2>/dev/null | tr -d '\r' > "$_t/acc"
# Size, mtime and path of every page in one stat run.
if stat -c %Y "$WIKI" >/dev/null 2>&1; then _so=-c; _sf='%s %Y %n'; else _so=-f; _sf='%z %m %N'; fi   # GNU stat -c || BSD/macOS stat -f
find "$WIKI" -type f -name '*.md' ! -name 'index.md' -not -path '*/.*' -exec stat "$_so" "$_sf" {} + > "$_t/stat"

# Pass 1, per page: path, size, mtime, created: date, body bytes.
# Age comes from the page's OWN `created:` frontmatter, mtime only as a fallback. Aging by mtime
# made FORGET structurally inert: shipped maintenance (reindex frontmatter patching, graph
# projection, backfills) bulk-touches every page, so ALL pages read as fresh and PROTECT:age
# fired on 100% of the corpus — measured live 2026-08-23: 457/457 pages carried that day's
# mtime while created: dates spanned 2026-04..2026-08. FORGET had never archived one page.
# created: forms seen in the wiki: "2026-04-27" and "2026-08-23T11:09:15Z" — take the date part,
# from the first match inside a /^---$/,/^---$/ range (sed range semantics: it re-arms after
# closing). Body byte-count is PROSE-ONLY: strip the authored ai-block so a uniform block can't
# lift every page over the stub floor (spec §5b). Only strip when a COMPLETE block exists (a
# closing ai:end is present) — an unterminated ai:begin is NOT a block, so it stays a raw
# byte-exact count (matches the TS stripAiBlock no-op; never eats a real page toward FORGET).
# C locale: length() counts bytes, like the `wc -c` it replaces.
LC_ALL=C awk -v dl="$_t/dates" '
  { size = $1; mt = $2; p = $0; sub(/^[^ ]+ [^ ]+ /, "", p)
    cr = ""; inr = 0; hasend = 0; skip = 0; strip = 0
    while ((getline l < p) > 0) {
      if (inr) {
        if (cr == "" && l ~ /^created:[[:space:]]*"?[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
          v = l; sub(/^created:[[:space:]]*"?/, "", v); cr = substr(v, 1, 10)
        }
        if (l ~ /^---$/) inr = 0
      } else if (l ~ /^---$/) inr = 1
      if (l ~ /<!--[[:space:]]*ai:end[[:space:]]*-->/) hasend = 1
      if (l ~ /<!--[[:space:]]*ai:begin/) skip = 1
      if (skip) { if (l ~ /<!--[[:space:]]*ai:end[[:space:]]*-->/) skip = 0 }
      else strip += length(l) + 1
    }
    close(p)
    if (cr != "" && !(cr in seen)) { seen[cr] = 1; print cr > dl }
    print p "\t" mt "\t" cr "\t" (hasend ? strip : size)
  }' "$_t/stat" > "$_t/pages"
# created: dates to epochs, once per distinct date: one GNU `date -f` call, else the per-date
# GNU-then-BSD pair the old per-page code ran. A date that does not parse falls back to mtime.
if date --version >/dev/null 2>&1; then
  date -f "$_t/dates" '+%Y-%m-%d %s' > "$_t/epochs" 2>/dev/null
else
  while IFS= read -r _d; do
    _e=$(date -d "$_d" +%s 2>/dev/null || date -j -f '%Y-%m-%d' "$_d" +%s 2>/dev/null) && printf '%s %s\n' "$_d" "$_e"
  done < "$_t/dates" > "$_t/epochs"
fi

# Pass 2: score. access-count (acc) is telemetry ONLY (the `acc=` reason field) — it is
# deliberately NOT folded into the score (v4: usage-frequency is the rich-get-richer hub bias).
# Recency is likewise unscored (age drives only PROTECT:age + the tie-break). s_con keeps the
# old %.6g rounding (it used to cross a process boundary as printed text).
# Category protection tier from kb-schema.json: PROTECTED -> never forget; DISCOUNTED -> mild;
# else default. Auto-generated noise (ULID evolve logs, session-digest recap pages) is
# forgettable even inside an otherwise-protected category — clear the category protection (age +
# inbound-link protections and the recall probe still guard it). D190: anchored to the generated
# prefixes, not a bare `*session*` substring (real learnings/decisions mention "session").
LC_ALL=C awk -F'\t' -v now="$now" -v minage="$MINAGE" -v wc="$WC" -v wg="$WG" \
  -v prot=" $SB_FORGET_PROTECTED " -v disc=" $SB_FORGET_DISCOUNTED " \
  -v lf="$_t/links" -v af="$_t/acc" -v ef="$_t/epochs" '
  BEGIN {
    while ((getline l < lf) > 0) { n = l; sub(/^[[:space:]]*[0-9]+ /, "", n); split(l, x, " "); if (!(n in inb)) inb[n] = x[1] }
    while ((getline l < af) > 0) { i = index(l, "\t"); if (i) acc[substr(l, 1, i - 1)] = substr(l, i + 1) }
    while ((getline l < ef) > 0) { split(l, x, " "); ep[x[1]] = x[2] }
  }
  { p = $1; mt = $2; cr = $3; body = $4
    slug = p; sub(/.*\//, "", slug); sub(/\.md$/, "", slug)
    cat = p; sub(/\/[^\/]*$/, "", cat); sub(/.*\//, "", cat)
    m = (cr != "" && (cr in ep)) ? ep[cr] : mt
    age = int((now - m) / 86400)
    n = (slug in inb) ? inb[slug] : 0
    a = (slug in acc) ? acc[slug] : 0
    sc = (n + 0 >= 3) ? 1 : (n + 0) / 3; sc = sprintf("%.6g", sc) + 0
    sg = 0.2; pr = ""
    if (index(prot, " " cat " ")) { sg = 1.0; pr = "PROTECT:category" }
    if (pr == "" && index(disc, " " cat " ")) sg = 0.5
    if (substr(slug, 1, 9) == "evolve-01" || substr(slug, 1, 15) == "session-digest-") { sg = 0.1; pr = "" }
    if (body + 0 < 200 && sg > 0.2) sg = 0.2
    score = sprintf("%.3f", (wc + 0) * sc + (wg + 0) * sg)
    pf = pr
    if (age < minage + 0) pf = pf (pf != "" ? "," : "") "PROTECT:age"
    if (n + 0 > 0) pf = pf (pf != "" ? "," : "") "PROTECT:linked"
    # age is a leading sort-only column: the sort below uses it as the age-DESC tie-break, then
    # `cut -f2-` strips it so the emitted columns are unchanged.
    printf "%s\t%s\t%s\t%s\tacc=%s inb=%s age=%sd cat=%s body=%sb\t%s\n", age, score, slug, p, a, n, age, cat, body, pf
  }' "$_t/pages" |
# score ASC (primary), then age DESC (recency tie-break) — recency only breaks ties, never
# drives eviction (v4). Explicit secondary key avoids relying on a stable sort (BSD sort isn't).
sort -t$'\t' -k2,2n -k1,1nr | cut -f2-
