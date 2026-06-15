#!/usr/bin/env bash
# Measure recall@k + injected-token cost of knowledge_search over a corpus.
# Exit: 0 = ok / gate passed; 1 = gate recall|token failure; 2 = infra failure.
#
# Shared by the release gate (fixed fixture corpus) and the dream FORGET phase's
# live recall-probe. BM25-only (SECOND_BRAIN_DISABLE_EMBEDDINGS=1) for determinism
# and offline fidelity. Recall = fraction of queries whose expected slug appears in
# the top-k slug lines the search CLI emits; tokens = bytes of that output / 4.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
CORPUS=""; QUERIES=""; K=2; GATE=0; LIVE_TITLES=0
while [ $# -gt 0 ]; do case "$1" in
  --corpus)  CORPUS="$2"; shift 2;;
  --queries) QUERIES="$2"; shift 2;;
  --k)       K="$2"; shift 2;;
  --gate)    GATE=1; shift;;
  --live-titles) CORPUS="$2"; LIVE_TITLES=1; shift 2;;
  *) echo "wiki-recall-check: unknown arg $1" >&2; exit 2;;
esac; done
command -v node >/dev/null 2>&1 || { echo "recall: node missing" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "recall: jq missing"   >&2; exit 2; }
# Hermetic brain dir (R2.2): the search CLI reads AND writes access-counts.json
# under BRAIN_DIR. Without this, eval runs ranked with the user's live access
# boosts (non-deterministic gate) and wrote fixture slugs into real state.
EVAL_BRAIN=$(mktemp -d); QUERIES_TMP=""
trap 'rm -rf "$EVAL_BRAIN"; [ -n "$QUERIES_TMP" ] && rm -f "$QUERIES_TMP"' EXIT
[ -f "$CLI" ]     || { echo "recall: search CLI missing ($CLI)" >&2; exit 2; }
[ -d "$CORPUS/wiki" ] || { echo "recall: corpus has no wiki/ ($CORPUS)" >&2; exit 2; }

# --live-titles (R2.2): generate one golden query per wiki page from its own
# title — invariant: a page's title must return its own slug in the top-K.
# This is exactly the class the hub-boost bug broke (MCP-SEARCH-1) and the
# fixed-fixture gate couldn't see (MCP-EVAL-1). Pages without a title line and
# index.md are skipped; sample cap via SB_EVAL_TITLE_SAMPLE (default all).
if [ "$LIVE_TITLES" -eq 1 ]; then
  QUERIES_TMP=$(mktemp); QUERIES="$QUERIES_TMP"
  CAP="${SB_EVAL_TITLE_SAMPLE:-0}"; case "$CAP" in ''|*[!0-9]*) CAP=0 ;; esac
  n=0; SEEN_NORMS=""
  while IFS= read -r f; do
    slug=$(basename "$f" .md)
    title=$(sed -n 's/^title:[[:space:]]*["'\'']\{0,1\}\(.*[^"'\'' ]\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$f" | head -1)
    [ -n "$title" ] || continue
    # Dedupe titles that collapse to the same effective query: the engine drops
    # pure-number (date) tokens, so daily series like "Digest — 2026-06-10" all
    # become ONE query — only 2 can occupy top-2, and probing each would flood
    # the report with false "misses" (deep-review premise-1; bash-3.2-safe list).
    norm=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' | tr ' ' '\n' | grep -vE '^[0-9]*$' | tr '\n' ' ')
    [ -n "${norm// /}" ] || continue
    printf '%s\n' "$SEEN_NORMS" | grep -qxF "$norm" && continue
    SEEN_NORMS="$SEEN_NORMS$norm
"
    jq -nc --arg q "$title" --arg e "$slug" '{q:$q, expect:[$e]}' >> "$QUERIES"
    n=$((n+1)); [ "$CAP" -gt 0 ] && [ "$n" -ge "$CAP" ] && break
  done < <(find "$CORPUS/wiki" -name '*.md' ! -name 'index.md' | sort)
  [ -s "$QUERIES" ] || { echo "recall: no titled pages found under $CORPUS/wiki" >&2; exit 2; }
fi
[ -f "$QUERIES" ] || { echo "recall: queries file missing ($QUERIES)" >&2; exit 2; }

hits=0; total=0; bytes=0; misses=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  q=$(printf '%s' "$line" | jq -r '.q' | tr -d '\r')
  out=$(KNOWLEDGE_DIR="$CORPUS" BRAIN_DIR="$EVAL_BRAIN" SB_BRAIN_DIR="$EVAL_BRAIN" SECOND_BRAIN_DISABLE_EMBEDDINGS=1 node "$CLI" "$q" 2>/dev/null) \
    || { echo "recall: search errored on query: $q" >&2; exit 2; }
  bytes=$(( bytes + ${#out} ))
  got=$(printf '%s' "$out" | grep -oE '\[\[[^]]+\]\]' | sed -E 's/\[\[|\]\]//g' | head -n "$K")
  total=$(( total + 1 )); hit=0
  while IFS= read -r exp; do
    [ -z "$exp" ] && continue
    printf '%s\n' "$got" | grep -qxF "$exp" && { hit=1; break; }
  done < <(printf '%s' "$line" | jq -r '.expect[]')
  [ "$hit" -eq 1 ] && hits=$(( hits + 1 )) || misses="$misses '$q'"
done < "$QUERIES"

tokens=$(( bytes / 4 ))
recall=$(awk -v t="$total" -v h="$hits" 'BEGIN{ t=t+0; h=h+0; if(t==0){print "0.0"} else {printf "%.3f", h/t} }')
echo "recall@$K=$recall tokens=$tokens queries=$total hits=$hits"
[ -n "$misses" ] && echo "misses:$misses"
if [ "$GATE" -eq 1 ]; then
  MINR="${SB_EVAL_MIN_RECALL:-0.8}"; MAXT="${SB_EVAL_MAX_TOKENS:-8000}"
  awk -v r="$recall" -v m="$MINR" 'BEGIN{ exit !((r+0) < (m+0)) }' && { echo "GATE FAIL: recall $recall < $MINR"; exit 1; }
  [ "$tokens" -gt "$MAXT" ] && { echo "GATE FAIL: tokens $tokens > $MAXT"; exit 1; }
  echo "GATE PASS"
fi
exit 0
