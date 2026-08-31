#!/usr/bin/env bash
# Injection gate: PRECISION + RECALL of what actually reaches the model per prompt.
#
# WHY THIS FILE EXISTS. The per-prompt wiki injection gate was dead for the entire life of the
# feature: SB_PERSONA_WIKI_MIN_SCORE defaulted to 0.045 on `score`, but in hybrid mode `score`
# is RRF, whose maximum is 2/(RRF_K+1) = 0.0328 and whose only post-fusion multipliers are the
# stub penalty (x0.5) and recency (x1.3) — a hard ceiling of 0.0426. Nothing could ever clear
# the gate, so 83 injected items over 13 sessions produced 0 reads.
#
# The suite stayed green throughout because every test touching this path pinned the gate open
# (SB_PERSONA_WIKI_MIN_SCORE=0 / KNOWLEDGE_MIN_SCORE=0) and/or disabled embeddings — the failing
# configuration was the only one never exercised. So this test runs the gate at its SHIPPED
# DEFAULTS and asserts the outcome that actually matters: relevant queries inject their page,
# irrelevant queries inject nothing.
#
# Deterministic: BM25-only (no model needed, so it runs in CI's offline lane) over the curated
# eval fixture. Grounding is corpus-SHARE based, so it behaves the same on 11 pages as on 372.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$ROOT/tests/fixtures/eval-wiki"
CLI="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
Q="$ROOT/tests/fixtures/eval-queries.jsonl"
echo "test-injection-gate.sh"
command -v node >/dev/null 2>&1 || { echo "SKIP: node missing"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }
[ -f "$CLI" ] || { echo "FAIL: search CLI missing ($CLI) — run npm run bundle"; exit 1; }

PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

EB=$(mktemp -d); trap 'rm -rf "$EB"' EXIT
# NOTE: no SB_INJECT_* overrides anywhere below — shipped defaults are the subject.
inject(){ KNOWLEDGE_DIR="$CORPUS" BRAIN_DIR="$EB" SB_BRAIN_DIR="$EB" \
  SECOND_BRAIN_DISABLE_EMBEDDINGS=1 node "$CLI" "$1" 2>/dev/null; }

# --- PRECISION: off-topic queries must inject NOTHING -------------------------
# The corpus is entirely about this plugin, so none of these has a legitimate answer in it.
# Before the df-share grounding filter these leaked: `tokenize` has no stopword list, so
# "best"/"way"/"today" grounded a page as well as "pagerank" would.
LEAKS=0
while IFS= read -r q; do
  [ -z "$q" ] && continue
  out=$(inject "$q")
  if [ -n "$out" ]; then
    LEAKS=$((LEAKS + 1))
    echo "    leaked: '$q' -> $(printf '%s' "$out" | head -1 | cut -c1-70)"
  fi
done <<'EOF'
banana smoothie recipe
olympic swimming lane etiquette
best way to grill vegetables
what colour is the sky today
my cat keeps knocking things off the table
how do I bake sourdough bread at home
xyzzy plugh frotz
what is the best way to do this
can you help me with this thing
what did we decide about kubernetes ingress
did we settle on terraform or pulumi for infrastructure
what deadline was agreed for the marketing launch
why was the mobile application rewritten in kotlin
which cloud region runs the production database
EOF
[ "$LEAKS" -eq 0 ] && pass "no off-topic query injects anything (0 leaks)" \
                   || fail "$LEAKS off-topic quer(y|ies) injected a page"

# --- RECALL: on-topic golden queries must mostly inject ----------------------
# Not 100%: the tokenizer does not stem, so a query saying "remove a page" cannot ground on a
# title saying "archives ... pages" (plural/tense mismatch). That is a known, recorded gap —
# see docs/plans/2026-08-20-rethink-delivery-layer.md. The floor guards the property that
# matters (the gate is not dead) and would have caught the 0.045 bug on day one, while leaving
# stemming as a separate improvement rather than a reason to weaken the gate.
TOTAL=0; HITS=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  q=$(printf '%s' "$line" | jq -r '.q' | tr -d '\r')
  TOTAL=$((TOTAL + 1))
  [ -n "$(inject "$q")" ] && HITS=$((HITS + 1))
done < "$Q"
MIN=$(( (TOTAL * 2 + 2) / 3 ))     # >= 2/3 of golden queries inject something
echo "    on-topic injected: $HITS/$TOTAL (floor $MIN)"
[ "$HITS" -ge "$MIN" ] && pass "on-topic queries inject at shipped defaults" \
                       || fail "only $HITS/$TOTAL on-topic queries injected — gate too strict (floor $MIN)"

# --- The regression that started all of this ---------------------------------
# A dead gate injects NOTHING, ever. Assert non-emptiness independently of the ratio above so
# the failure message names the actual disease.
[ "$HITS" -gt 0 ] && pass "gate is not dead (at least one on-topic query injects)" \
                  || fail "GATE IS DEAD: zero on-topic queries injected at shipped defaults"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
