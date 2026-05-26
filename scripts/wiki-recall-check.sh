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
CORPUS=""; QUERIES=""; K=2; GATE=0
while [ $# -gt 0 ]; do case "$1" in
  --corpus)  CORPUS="$2"; shift 2;;
  --queries) QUERIES="$2"; shift 2;;
  --k)       K="$2"; shift 2;;
  --gate)    GATE=1; shift;;
  *) echo "wiki-recall-check: unknown arg $1" >&2; exit 2;;
esac; done
command -v node >/dev/null 2>&1 || { echo "recall: node missing" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "recall: jq missing"   >&2; exit 2; }
[ -f "$CLI" ]     || { echo "recall: search CLI missing ($CLI)" >&2; exit 2; }
[ -f "$QUERIES" ] || { echo "recall: queries file missing ($QUERIES)" >&2; exit 2; }
[ -d "$CORPUS/wiki" ] || { echo "recall: corpus has no wiki/ ($CORPUS)" >&2; exit 2; }

hits=0; total=0; bytes=0; misses=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  q=$(printf '%s' "$line" | jq -r '.q')
  out=$(KNOWLEDGE_DIR="$CORPUS" SECOND_BRAIN_DISABLE_EMBEDDINGS=1 node "$CLI" "$q" 2>/dev/null) \
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
recall=$(awk "BEGIN{ if($total==0){print \"0.0\"} else {printf \"%.3f\", $hits/$total} }")
echo "recall@$K=$recall tokens=$tokens queries=$total hits=$hits"
[ -n "$misses" ] && echo "misses:$misses"
if [ "$GATE" -eq 1 ]; then
  MINR="${SB_EVAL_MIN_RECALL:-0.8}"; MAXT="${SB_EVAL_MAX_TOKENS:-8000}"
  awk "BEGIN{exit !($recall < $MINR)}" && { echo "GATE FAIL: recall $recall < $MINR"; exit 1; }
  [ "$tokens" -gt "$MAXT" ] && { echo "GATE FAIL: tokens $tokens > $MAXT"; exit 1; }
  echo "GATE PASS"
fi
exit 0
