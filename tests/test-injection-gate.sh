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
#
# Two CLIs, two gates. knowledge-search-cli (inject) is the recall/FORGET gate and is what the
# first sections exercise. context-serve-cli (serve) is what the hook ACTUALLY injects per prompt;
# since R1#4 (2026-10) it also refuses stubs, asks cross-project pages for one more grounded term,
# and clamps the need to the discriminative-term count. The R1 sections below hold that ratchet.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$ROOT/tests/fixtures/eval-wiki"
CLI="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
CTX_CLI="$ROOT/mcp/dist/tools/context-serve-cli.bundle.js"
Q="$ROOT/tests/fixtures/eval-queries.jsonl"
echo "test-injection-gate.sh"
command -v node >/dev/null 2>&1 || { echo "SKIP: node missing"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }
[ -f "$CLI" ] || { echo "FAIL: search CLI missing ($CLI) — run npm run bundle"; exit 1; }
[ -f "$CTX_CLI" ] || { echo "FAIL: context-serve CLI missing ($CTX_CLI) — run npm run bundle"; exit 1; }

PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

EB=$(mktemp -d); trap 'rm -rf "$EB"' EXIT
# NOTE: no SB_INJECT_* overrides anywhere below — shipped defaults are the subject.
# D017: `${SECOND_BRAIN_DISABLE_EMBEDDINGS-1}` (no colon — unset-only, not
# empty-or-unset) defaults to the deterministic BM25-only run this file is
# documented as (CI's offline lane), but lets `make production-lane` export
# SECOND_BRAIN_DISABLE_EMBEDDINGS=0 to re-run the SAME gate over the real
# hybrid RRF path — the only place that path is actually exercised.
inject(){ KNOWLEDGE_DIR="$CORPUS" BRAIN_DIR="$EB" SB_BRAIN_DIR="$EB" \
  SECOND_BRAIN_DISABLE_EMBEDDINGS="${SECOND_BRAIN_DISABLE_EMBEDDINGS-1}" node "$CLI" "$1" 2>/dev/null; }
# serve QUERY [ACTIVE_SLUG]: the wiki section the per-prompt hook would inject (the lines before
# the episodic separator). The empty brain dir has no episodic index, so that section is empty.
serve(){ KNOWLEDGE_DIR="$CORPUS" BRAIN_DIR="$EB" SB_BRAIN_DIR="$EB" SB_ACTIVE_SLUG="${2:-}" \
  SB_SESSION_ID=injection-gate-test \
  SECOND_BRAIN_DISABLE_EMBEDDINGS="${SECOND_BRAIN_DISABLE_EMBEDDINGS-1}" node "$CTX_CLI" "$1" 2>/dev/null \
  | awk '$0=="--8<--SB-EPISODIC--8<--"{exit}{print}'; }
has(){ printf '%s\n' "$1" | grep -qF "[[$2]]"; }

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

# --- R1 ratchet (2026-10 memory-usage design, rows #4/#5) ------------------------------------
# Forbid rows: the 12 generic-word R0 prompts of the 2026-10 relevance grading, paraphrased into
# the fixture domain. The trap pages (merge-gate-checklist, results-file-blocks-rebuilds,
# pool-sync-over-cancels-jobs, everything-skills-reference) share only GENERIC words with them
# (check, old, valid, one, added, everything, relevant, a lone "m" from "I'm") plus at most one
# real term. Grounding is shared by both CLIs, so both are held to it.
R0_LEAKS=0
while IFS= read -r q; do
  [ -z "$q" ] && continue
  for via in inject serve; do
    out=$($via "$q")
    if [ -n "$out" ]; then
      R0_LEAKS=$((R0_LEAKS + 1))
      echo "    leaked ($via): '$q' -> $(printf '%s' "$out" | head -1 | cut -c1-70)"
    fi
  done
done <<'EOF'
check what has been implemented and what else we miss in our helper
add a team build for the one faction boss fight
fix the design issues where game inputs have no limiter
do we compare the score of spells that do not fit the lineup
hero data filtering puts S tiers below A ones
check whether the review comments are correct and valid
check that everything is tested then remove the old static page
update everything with the season changes so the order is relevant
are the new mechanics added everywhere or just research
commit and push everything then check the building tabs
check the progress of the agents heading to the final merge
I'm going to sleep so auto approve everything until it is merged
EOF
[ "$R0_LEAKS" -eq 0 ] && pass "generic-word R0 prompts inject nothing through either CLI" \
                      || fail "$R0_LEAKS generic-word R0 injection(s)"

# Stubs are retrievable and grounded (the recall CLI injects them, so this is not vacuous) but
# never served per prompt.
STUB_BAD=0
for s in quokka-relay-checkpoint marmot-quill-compaction pangolin-burrow-sweep; do
  q=$(printf '%s' "$s" | tr '-' ' ')
  has "$(inject "$q")" "$s" || { STUB_BAD=$((STUB_BAD + 1)); echo "    stub $s not retrievable — the serve check would prove nothing"; }
  has "$(serve "$q")" "$s" && { STUB_BAD=$((STUB_BAD + 1)); echo "    stub $s injected per prompt"; }
done
[ "$STUB_BAD" -eq 0 ] && pass "stubs are never injected per prompt" || fail "$STUB_BAD stub check(s) failed"

# SessionStart wiki enrichment (session-load.sh) reads knowledge-search-cli with SB_INJECT_GATE=1:
# it injects into the session just like the per-prompt hook, so the same stubs must stay out,
# while the legacy (recall/FORGET) path above still retrieves them.
enrich(){ KNOWLEDGE_DIR="$CORPUS" BRAIN_DIR="$EB" SB_BRAIN_DIR="$EB" SB_INJECT_GATE=1 \
  SECOND_BRAIN_DISABLE_EMBEDDINGS="${SECOND_BRAIN_DISABLE_EMBEDDINGS-1}" node "$CLI" "$1" 2>/dev/null; }
ENRICH_BAD=0
for s in quokka-relay-checkpoint marmot-quill-compaction pangolin-burrow-sweep; do
  q=$(printf '%s' "$s" | tr '-' ' ')
  has "$(enrich "$q")" "$s" && { ENRICH_BAD=$((ENRICH_BAD + 1)); echo "    stub $s injected by SessionStart enrichment"; }
done
[ "$ENRICH_BAD" -eq 0 ] && pass "SessionStart enrichment (SB_INJECT_GATE=1) refuses stubs" || fail "$ENRICH_BAD stub(s) injected at SessionStart"

# Digits ground: "rotation" is a discriminative term no page carries, so the need is 2 and only
# the "8" can supply the second grounded term ("season 8" in the graded R2 prompt #27).
has "$(serve "season 8 rotation" gamehelper)" season-8-artifact-swap \
  && pass "a digit grounds (season 8)" || fail "season 8 did not ground on the digit"

# One discriminative term among filler injects an in-project page. The old clamp,
# min(2, query_terms=5), asked for 2 grounded terms when only 1 could exist.
has "$(serve "what about the squads thing" gamehelper)" supreme-arena-squads \
  && pass "a 1-discriminative-term query injects an in-project page" \
  || fail "1-discriminative-term query injected nothing (unsatisfiable clamp)"

# Cross-project (brainplug page, gamehelper session): one more grounded term, clamped. Grounding
# on every discriminative term injects; grounding on 2 of 3 does not, although the recall CLI,
# which has no cross-project rule, injects that same page for that same query.
has "$(serve "version bump tripwire" gamehelper)" version-bump-tripwire \
  && pass "cross-project page grounding on every term is injected" \
  || fail "cross-project page grounding on every discriminative term was not injected"
if has "$(serve "version bump cadence" gamehelper)" version-bump-tripwire; then
  fail "cross-project page grounding 2 of 3 terms was injected"
elif ! has "$(inject "version bump cadence")" version-bump-tripwire; then
  fail "recall CLI no longer retrieves version-bump-tripwire — the cross-project check proves nothing"
else
  pass "cross-project page needs one more grounded term"
fi

# In-project paraphrases of graded R2 topics are still served.
R2_MISS=0
while IFS='|' read -r q want; do
  [ -z "$q" ] && continue
  has "$(serve "$q" gamehelper)" "$want" || { R2_MISS=$((R2_MISS + 1)); echo "    not served: '$q' (want $want)"; }
done <<'EOF'
supreme arena defense squads|supreme-arena-squads
does the arena feed an enemy list to scoring|enemy-team-data-flow
arena level normalization for artifacts|arena-mode-normalization
EOF
[ "$R2_MISS" -eq 0 ] && pass "graded-R2 paraphrases are served per prompt" || fail "$R2_MISS R2 paraphrase(s) not served"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
