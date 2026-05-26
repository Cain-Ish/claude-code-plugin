#!/usr/bin/env bash
# Select archivable wiki pages: score < floor, unprotected, capped; then a live
# recall-probe drops any page that is the UNIQUE answer to its own topic query.
# Emits one `slug<TAB>path` per archivable page. Exit 2 if the recall guard cannot
# run (fail-safe: the dream FORGET phase then skips archiving entirely).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KD="${KNOWLEDGE_DIR:-$HOME/knowledge}"
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
  qy=$(awk -F': ' '/^title:/{t=$2} /^keywords:/{k=$2} END{print t" "k}' "$path")
  bpath=$(find "$base/wiki" -type f -name "$slug.md" | head -1)
  [ -n "$bpath" ] || continue
  mv "$bpath" "$hold/$slug.md"                       # remove candidate from the copy
  qf=$(mktemp); printf '{"q":%s,"expect":["__none__"]}\n' "$(jq -Rn --arg q "$qy" '$q')" > "$qf"
  without=$(bash "$RECALL" --corpus "$base" --queries "$qf" --k 2 2>/dev/null); rc=$?
  rm -f "$qf"; mv "$hold/$slug.md" "$bpath"          # restore
  [ "$rc" -eq 2 ] && { echo "candidates: recall guard unavailable -> abort (fail-safe)" >&2; exit 2; }
  toks=$(printf '%s' "$without" | grep -oE 'tokens=[0-9]+' | head -1 | sed 's/tokens=//')
  # tokens>0 after removal ⇒ a sibling still answers the topic ⇒ safe to archive.
  # tokens==0 ⇒ this page was the unique answer ⇒ PROTECT (skip).
  [ "${toks:-0}" -gt 0 ] && emit="$emit$slug\t$path\n"
done
printf '%b' "$emit"
