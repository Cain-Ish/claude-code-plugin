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

# score-eligible = score < FLOOR and empty protflag, capped
mapfile -t cand < <(printf '%s\n' "$scored" | awk -F'\t' -v fl="$FLOOR" '($1+0)<fl && $5==""{print $2"\t"$3}' | head -n "$CAP")
[ "${#cand[@]}" -eq 0 ] && exit 0

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
    # No title/keywords -> topic not answerable by definition -> archivable.
    mv "$bpath" "$hold/$slug.md"; emit="$emit$slug\t$path\n"; continue
  fi
  mv "$bpath" "$hold/$slug.md"                        # remove candidate from the copy
  qf=$(mktemp); printf '{"q":%s,"expect":["__none__"]}\n' "$(jq -Rn --arg q "$qy" '$q')" > "$qf"
  without=$(bash "$RECALL" --corpus "$base" --queries "$qf" --k 2 2>/dev/null); rc=$?
  rm -f "$qf"
  [ "$rc" -eq 2 ] && { echo "candidates: recall guard unavailable -> abort (fail-safe)" >&2; exit 2; }
  toks=$(printf '%s' "$without" | grep -oE 'tokens=[0-9]+' | head -1 | sed 's/tokens=//')
  if [ "${toks:-0}" -gt 0 ]; then
    # A sibling still answers the topic -> safe to archive. LEAVE it removed so a
    # later near-duplicate is probed against a corpus that already lacks this one
    # (prevents archiving BOTH copies of a topic — the cascade bug).
    emit="$emit$slug\t$path\n"
  else
    mv "$hold/$slug.md" "$bpath"                      # unique answer -> PROTECT -> restore
  fi
done
printf '%b' "$emit"
