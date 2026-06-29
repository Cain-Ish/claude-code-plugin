#!/usr/bin/env bash
# Select archivable wiki pages: score < floor, unprotected, capped; then a live
# recall-probe drops any page that is the UNIQUE answer to its own topic query.
# Emits one `slug<TAB>path` per archivable page. Exit 2 if the recall guard cannot
# run (fail-safe: the dream FORGET phase then skips archiving entirely).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"; KD="${KD/#\~/$HOME}"
FLOOR="${SB_FORGET_FLOOR:-0.15}"; CAP="${SB_FORGET_MAX_PER_DREAM:-5}"
PROBE_MIN="${SB_FORGET_PROBE_MIN_SCORE:-0.1}"
SCORER="$ROOT/scripts/wiki-forget-score.sh"
RECALL="$ROOT/scripts/wiki-recall-check.sh"
[ -x "$SCORER" ] || chmod +x "$SCORER" 2>/dev/null
[ -x "$RECALL" ] || chmod +x "$RECALL" 2>/dev/null
command -v jq >/dev/null 2>&1 || { echo "candidates: jq missing" >&2; exit 2; }

scored=$(bash "$SCORER") || { echo "candidates: scorer failed" >&2; exit 2; }

# score-eligible = score < FLOOR and empty protflag, capped.
# Portable array fill (NOT `mapfile`/`readarray` — bash 4+, absent on macOS /bin/bash 3.2).
cand=()
while IFS= read -r _l; do [ -n "$_l" ] && cand+=("$_l"); done \
  < <(printf '%s\n' "$scored" | awk -F'\t' -v fl="$FLOOR" '($1+0)<fl && $5==""{print $2"\t"$3}' | head -n "$CAP")
[ "${#cand[@]}" -eq 0 ] && exit 0

# FORGET redundancy cross-check (0.33.27): a candidate the recall-probe deems redundant is only
# archived if MinHash ALSO confirms a genuine near-dup twin (body sim >= forget threshold). This
# stops the recall-probe from false-forgetting a distinct-but-same-TOPIC page (e.g. "indexing
# basics" vs "advanced indexing", which share tags so the probe sees coverage, yet are NOT dups).
# When the MinHash engine is unavailable (no node/bundle, or SB_REDUNDANCY=off), fall back to the
# PRIOR recall-probe-only behavior (no regression) — announced on stderr, never a silent no-op.
REDUN="$ROOT/scripts/wiki-redundancy.sh"
REDUN_BUNDLE="$ROOT/mcp/dist/tools/wiki-redundancy-cli.bundle.js"
[ -x "$REDUN" ] || chmod +x "$REDUN" 2>/dev/null
FTHRESH="${SB_FORGET_REDUNDANCY_THRESHOLD:-0.8}"
MINHASH_OK=0
{ command -v node >/dev/null 2>&1 && [ -f "$REDUN_BUNDLE" ] && [ "${SB_REDUNDANCY:-on}" != "off" ]; } && MINHASH_OK=1
pairs=""
if [ "$MINHASH_OK" -eq 1 ]; then
  # tr -d '\r': jq 1.8.1 stdout is text-mode on Windows (\n -> \r\n), so a CR rides on every
  # second slug -> grep -qxF would miss it -> is_neardup=0 for all -> FORGET silently archives
  # nothing. Strip at the source (same fix as wiki-recall-check.sh). project_jq_windows_crlf_stdout.
  pairs=$(SB_REDUNDANCY_THRESHOLD="$FTHRESH" bash "$REDUN" --knowledge-dir "$KD" 2>/dev/null \
    | jq -r '.[] | "\(.a)\t\(.b)"' 2>/dev/null | tr -d '\r')
else
  echo "candidates: MinHash redundancy cross-check unavailable — FORGET using recall-probe only" >&2
fi
# slugs with a genuine near-dup twin (membership test) + a twins lookup (for the keep->=1-per-cluster
# guard). Slug-keyed: a duplicate slug across categories errs SAFE (a false membership only permits a
# forget the recall-probe already approved; a false twin-protection only KEEPS a page).
neardup_slugs=$(printf '%s\n' "$pairs" | tr '\t' '\n' | grep -v '^$' | sort -u)
twins_of() { printf '%s\n' "$pairs" | awk -F'\t' -v s="$1" '$1==s{print $2} $2==s{print $1}'; }
protected_twins=""   # newline-list of slugs whose near-dup twin was archived this run

# One working copy of the corpus; toggle each candidate out for its probe so the
# real/staging wiki is never mutated and we copy only once.
base=$(mktemp -d); trap 'rm -rf "$base"' EXIT
cp -r "$KD/." "$base/" 2>/dev/null
[ -d "$base/wiki" ] || { echo "candidates: corpus copy has no wiki/" >&2; exit 2; }
hold="$base/.hold"; mkdir -p "$hold"
export KNOWLEDGE_MIN_SCORE="$PROBE_MIN"   # zero-overlap pages (score 0) won't count as coverage

emit=""
for row in "${cand[@]}"; do
  slug="${row%%$'\t'*}"; path="${row#*$'\t'}"
  # Resolve the exact file in the copy from the row's REAL path (a slug-only find
  # would pick the wrong file when the same slug exists in two categories).
  rel="${path#$KD/}"; bpath="$base/$rel"
  [ -f "$bpath" ] || continue
  # keep >=1 per near-dup cluster: if a twin of this page was already archived this run, KEEP this
  # one (leave it in the corpus copy) so two near-dup copies are never both forgotten.
  if [ -n "$protected_twins" ] && printf '%s\n' "$protected_twins" | grep -qxF "$slug"; then continue; fi
  # cross-check membership: does this page have a genuine MinHash near-dup twin? (0 when MinHash off)
  is_neardup=0
  [ "$MINHASH_OK" -eq 1 ] && printf '%s\n' "$neardup_slugs" | grep -qxF "$slug" && is_neardup=1
  # Topic query from the MAINTAINED, distinctive field: tags: (strip [ ] and commas),
  # then description:, then title:. Real wiki pages use tags:, never keywords:; title
  # text ("Foobar note A") carries generic words that spuriously match unrelated pages.
  qy=$(awk -F': ' '
        /^tags:/        {t=$2; gsub(/[][,]/," ",t)}
        /^description:/ {d=$2}
        /^title:/       {ti=$2}
        END{ q=(t ~ /[^ ]/)?t:((d!="")?d:ti); print q }' "$path" \
      | sed 's/"//g; s/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ -z "$qy" ]; then
    # No title/keywords -> topic not answerable. Archive only if the cross-check allows: a
    # confirmed near-dup twin, or MinHash unavailable (prior behavior). A unique, untitled page
    # with no near-dup is KEPT (unfindable but distinct — forgetting it would lose content).
    if [ "$MINHASH_OK" -eq 0 ] || [ "$is_neardup" -eq 1 ]; then
      mv "$bpath" "$hold/$slug.md"; emit="$emit$slug\t$path\n"
      protected_twins="$protected_twins
$(twins_of "$slug")"
    fi
    continue
  fi
  mv "$bpath" "$hold/$slug.md"                        # remove candidate from the copy
  qf=$(mktemp); printf '{"q":%s,"expect":["__none__"]}\n' "$(jq -Rn --arg q "$qy" '$q')" > "$qf"
  without=$(bash "$RECALL" --corpus "$base" --queries "$qf" --k 2 2>/dev/null); rc=$?
  rm -f "$qf"
  [ "$rc" -eq 2 ] && { echo "candidates: recall guard unavailable -> abort (fail-safe)" >&2; exit 2; }
  toks=$(printf '%s' "$without" | grep -oE 'tokens=[0-9]+' | head -1 | sed 's/tokens=//')
  if [ "${toks:-0}" -gt 0 ] && { [ "$MINHASH_OK" -eq 0 ] || [ "$is_neardup" -eq 1 ]; }; then
    # A sibling still answers the topic AND (MinHash off OR a genuine near-dup twin exists) ->
    # safe to archive. LEAVE it removed so a later near-duplicate is probed against a corpus that
    # already lacks this one (cascade-safe), and protect its twins so >=1 copy always survives.
    emit="$emit$slug\t$path\n"
    protected_twins="$protected_twins
$(twins_of "$slug")"
  else
    # unique answer, OR topic-covered but NOT a genuine near-dup (distinct same-topic) -> restore.
    mv "$hold/$slug.md" "$bpath"
  fi
done
printf '%b' "$emit"
