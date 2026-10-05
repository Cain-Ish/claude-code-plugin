#!/usr/bin/env bash
# run-all-timeout: 300   (measured 59-81s alone on MSYS 2026-10-05 with the SB_INJECT_PRECISION hook rows: 4 persona-context.sh + 2 session-load.sh runs; 18s before them; the 120s default is a coin flip under run-all load)
# pins: SB_INJECT_GATE — enrich() sets =1 because SessionStart enrichment's gated path is the subject
# pins: SB_INJECT_PRECISION — the rollback-switch rows set off / 0 / bogus through the real hooks: the switch is the subject
# pins: SB_ACTIVE_SLUG — serve()/enrich() set the session's project, because the cross-project rule is the subject
# pins: SB_BRAIN_DIR — every CLI helper sandboxes the brain dir to a scratch dir (never the real one)
# pins: SB_SESSION_ID — serve() passes a session id the way the hook does (the sandbox holds no episodes; only the wiki section is read)
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
# The last section drives the real hooks (persona-context.sh, session-load.sh) with the
# SB_INJECT_PRECISION rollback switch set, and reads what lands in the sandboxed brain dir's logs.
set -u
# Shipped defaults are the subject of every section but the last, which sets the switch itself; the
# hooks' headless-child gate keys on the CLAUDE_CODE_* pair, so a suite launched from `claude -p` (or
# a session whose values leak in) would turn every hook row into a no-op.
unset SB_INJECT_PRECISION CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED CLAUDE_PROJECT_DIR \
      SB_HEADLESS_CONTEXT SB_MACHINE_TURN_SKIP SB_NESTED_SPAWN SB_PERSONA_GATE
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
EB=$(mktemp -d); trap 'rm -rf "$EB"' EXIT

# A CLI that crashes prints nothing, and "injects nothing" is exactly what the precision sections
# assert, so a dead bundle used to pass them. Every helper below records a non-zero exit in
# $CLI_FAILS (a file: the helpers run inside $(...) subshells), and every verdict checks it: a
# section in which any CLI call exited non-zero FAILS, whatever its own assertion said.
CLI_FAILS="$EB/cli-failures"; : > "$CLI_FAILS"; CLI_SEEN=0
cli_rc(){ [ "$2" -eq 0 ] || printf '%s rc=%s q=%s\n' "$1" "$2" "$3" >> "$CLI_FAILS"; return "$2"; }
cli_crashed(){
  local n; n=$(grep -c . "$CLI_FAILS" 2>/dev/null | tr -d ' \r'); n=${n:-0}
  [ "$n" -gt "$CLI_SEEN" ] || return 1
  echo "    CLI exited non-zero: $(tail -n $((n - CLI_SEEN)) "$CLI_FAILS" | head -3 | tr '\n' ';')"
  CLI_SEEN=$n
  return 0
}
pass(){ if cli_crashed; then FAIL=$((FAIL+1)); echo "  FAIL: $1 (but a CLI exited non-zero in this section, so it proves nothing)"; else PASS=$((PASS+1)); echo "  PASS: $1"; fi; }
fail(){ cli_crashed; FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
# NOTE: the gate knobs (SB_INJECT_MIN_GROUNDED / _MIN_RELEVANCE, KNOWLEDGE_MIN_SCORE) are never
# overridden — shipped defaults are the subject. The only SB_INJECT_* this file sets are the gate
# SELECTORS: SB_INJECT_GATE=1 in enrich() (the path session-load.sh takes) and SB_INJECT_PRECISION
# in the last section, where the rollback switch itself is under test.
# D017: `${SECOND_BRAIN_DISABLE_EMBEDDINGS-1}` (no colon — unset-only, not
# empty-or-unset) defaults to the deterministic BM25-only run this file is
# documented as (CI's offline lane), but lets `make production-lane` export
# SECOND_BRAIN_DISABLE_EMBEDDINGS=0 to re-run the SAME gate over the real
# hybrid RRF path — the only place that path is actually exercised.
inject(){ local o rc; o=$(KNOWLEDGE_DIR="$CORPUS" BRAIN_DIR="$EB" SB_BRAIN_DIR="$EB" \
  SECOND_BRAIN_DISABLE_EMBEDDINGS="${SECOND_BRAIN_DISABLE_EMBEDDINGS-1}" node "$CLI" "$1" 2>/dev/null); rc=$?
  [ -z "$o" ] || printf '%s\n' "$o"; cli_rc inject "$rc" "$1"; }
# serve QUERY [ACTIVE_SLUG]: the wiki section the per-prompt hook would inject (the lines before
# the episodic separator). The empty brain dir has no episodic index, so that section is empty.
# The CLI's own exit status is captured BEFORE the awk split (a pipe would report awk's).
serve(){ local o rc; o=$(KNOWLEDGE_DIR="$CORPUS" BRAIN_DIR="$EB" SB_BRAIN_DIR="$EB" SB_ACTIVE_SLUG="${2:-}" \
  SB_SESSION_ID=injection-gate-test \
  SECOND_BRAIN_DISABLE_EMBEDDINGS="${SECOND_BRAIN_DISABLE_EMBEDDINGS-1}" node "$CTX_CLI" "$1" 2>/dev/null); rc=$?
  [ -z "$o" ] || printf '%s\n' "$o" | awk '$0=="--8<--SB-EPISODIC--8<--"{exit}{print}'; cli_rc serve "$rc" "$1"; }
# enrich QUERY [ACTIVE_SLUG]: SessionStart wiki enrichment (session-load.sh) reads knowledge-search-cli
# with SB_INJECT_GATE=1: it injects into the session like the per-prompt hook, so it takes the same gate.
enrich(){ local o rc; o=$(KNOWLEDGE_DIR="$CORPUS" BRAIN_DIR="$EB" SB_BRAIN_DIR="$EB" SB_INJECT_GATE=1 SB_ACTIVE_SLUG="${2:-}" \
  SECOND_BRAIN_DISABLE_EMBEDDINGS="${SECOND_BRAIN_DISABLE_EMBEDDINGS-1}" node "$CLI" "$1" 2>/dev/null); rc=$?
  [ -z "$o" ] || printf '%s\n' "$o"; cli_rc enrich "$rc" "$1"; }
has(){ printf '%s\n' "$1" | grep -qF "[[$2]]"; }

# Harness self-check: a crashed CLI (here: a bundle path that does not exist) must turn the next
# verdict into a FAIL. Probed in this shell, then consumed, so it cannot leak into a real section.
_ctx_cli="$CTX_CLI"; CTX_CLI="$EB/no-such-bundle.js"; serve "harness self check" >/dev/null; CTX_CLI="$_ctx_cli"
if cli_crashed; then PASS=$((PASS+1)); echo "  PASS: a crashed CLI is recorded and fails its section (exit status propagates through serve)"
else FAIL=$((FAIL+1)); echo "  FAIL: a crashed CLI went unnoticed — 'injects nothing' sections could pass on a dead bundle"; fi

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
# Positive controls, one per CLI: each MUST inject its page. Every "injects nothing" row below is
# only meaningful if the same CLI demonstrably injects something on this corpus.
CTL_BAD=0
has "$(inject "version bump tripwire")" version-bump-tripwire || { CTL_BAD=$((CTL_BAD + 1)); echo "    inject control: version-bump-tripwire not injected"; }
has "$(serve "supreme arena defense squads" gamehelper)" supreme-arena-squads || { CTL_BAD=$((CTL_BAD + 1)); echo "    serve control: supreme-arena-squads not served"; }
has "$(enrich "version bump tripwire" brainplug)" version-bump-tripwire || { CTL_BAD=$((CTL_BAD + 1)); echo "    enrich control: version-bump-tripwire not enriched"; }
[ "$CTL_BAD" -eq 0 ] && pass "positive controls: inject, serve and enrich each inject their page" \
                     || fail "$CTL_BAD positive control(s) injected nothing — the precision rows below would prove nothing"

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

# SessionStart enrichment (enrich, SB_INJECT_GATE=1) keeps the same stubs out, while the legacy
# (recall/FORGET) path above still retrieves them.
ENRICH_BAD=0
for s in quokka-relay-checkpoint marmot-quill-compaction pangolin-burrow-sweep; do
  q=$(printf '%s' "$s" | tr '-' ' ')
  has "$(enrich "$q")" "$s" && { ENRICH_BAD=$((ENRICH_BAD + 1)); echo "    stub $s injected by SessionStart enrichment"; }
done
[ "$ENRICH_BAD" -eq 0 ] && pass "SessionStart enrichment (SB_INJECT_GATE=1) refuses stubs" || fail "$ENRICH_BAD stub(s) injected at SessionStart"

# Digits never ground a page on their own (TS engine, R1 review): "fix items 3 8 review" shares
# only the digits 3 and 8 with phase-8-3-cutover's head, which once made 2 grounded terms and served
# the page (the real-wiki "8-3" hole). A digit still counts toward ranking, and a real second term
# still serves: "new season 8 artifacts" (graded R2 prompt #27's topic) grounds on season + artifacts.
if has "$(serve "fix items 3 8 review" gamehelper)" phase-8-3-cutover; then
  fail "a digits-only overlap (3, 8) served phase-8-3-cutover per prompt"
elif ! has "$(serve "phase 8-3 cutover of the quarry shards" gamehelper)" phase-8-3-cutover; then
  fail "phase-8-3-cutover is not served even for its own topic — the digits-only check proves nothing"
else
  pass "a digits-only overlap does not ground a page"
fi
has "$(serve "new season 8 artifacts" gamehelper)" season-8-artifact-swap \
  && pass "season 8 plus a real second term still serves (season, artifacts)" \
  || fail "\"new season 8 artifacts\" did not serve season-8-artifact-swap"

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
# The same rule for SessionStart enrichment (SB_INJECT_GATE=1): a cross-project page grounding only
# on the base need (2 of 3 terms) is not enriched; grounding on every term is.
if has "$(enrich "version bump cadence" gamehelper)" version-bump-tripwire; then
  fail "enrich (SB_INJECT_GATE=1) served a cross-project page grounding only on the base need (2 of 3 terms)"
elif ! has "$(enrich "version bump tripwire" gamehelper)" version-bump-tripwire; then
  fail "enrich no longer serves a cross-project page grounding on every term — the cross-project check proves nothing"
else
  pass "enrich (SB_INJECT_GATE=1) asks a cross-project page for one more grounded term"
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

# --- SB_INJECT_PRECISION through the REAL hooks (the R1 rollback switch) ----------------------
# The hooks run the CLIs with stderr discarded, so a warning printed there never reaches anyone.
# These rows drive scripts/persona-context.sh (per prompt: context-serve-cli) and
# scripts/session-load.sh (SessionStart enrichment: knowledge-search-cli with SB_INJECT_GATE=1)
# over the same fixture corpus and the rebuilt bundle, each against its own sandboxed brain dir,
# and read that dir's logs:
#   off / 0  -> the stub the R1 gate refuses is injected, plus ONE gate=inject-precision TRACE row
#               in audit-log.jsonl, in sb_log_error's rerouted gate-row shape;
#   bogus    -> the R1 gate holds, plus an error row in error-log.jsonl naming the CLI;
#   unset    -> the R1 gate holds, and the switch writes nothing at all.
# The hooks write rows of their own into the same files, so every count below is filtered to the
# switch's rows. The hooks also fail open (a dead CLI = no context, exit 0), so cli_rc cannot see a
# crash here: the off row is this section's liveness control, and the "R1 holds" rows count only
# when it injected.
STUB_SLUG=quokka-relay-checkpoint
HOOK_PROMPT="explain the quokka relay checkpoint"   # >= 4 words: shorter prompts exit before retrieval
# hook_prompt MODE BRAIN: the additionalContext persona-context.sh emits for $HOOK_PROMPT with
# SB_INJECT_PRECISION=MODE ("" = unset), its brain dir sandboxed to BRAIN (fresh session id).
hook_prompt(){
  ( [ -n "$1" ] && export SB_INJECT_PRECISION="$1"
    printf '{"prompt":"%s","session_id":"prec-%s","cwd":"%s"}' "$HOOK_PROMPT" "${1:-unset}" "$2" \
      | BRAIN_DIR="$2" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$CORPUS" KNOWLEDGE_DIR="$CORPUS" \
        SECOND_BRAIN_DISABLE_EMBEDDINGS="${SECOND_BRAIN_DISABLE_EMBEDDINGS-1}" \
        bash "$ROOT/scripts/persona-context.sh" 2>"$2/hook-stderr.log" ) \
    | jq -r '.hookSpecificOutput.additionalContext // ""' | tr -d '\r'
}
# hook_session MODE BRAIN: the SessionStart output of session-load.sh for a registered project
# whose PROJECT.md goal is the stub's title, so the enrichment queries "checkpoint quokka relay".
hook_session(){
  local pd="$2/quokka-demo"
  mkdir -p "$pd" "$2/projects/quokka-demo" "$2/transcripts"
  printf '# PROJECT: quokka-demo\n## Goal\nQuokka relay checkpoint\n' > "$2/projects/quokka-demo/PROJECT.md"
  printf '{"slug":"quokka-demo","path":"%s","plan_done":0,"plan_total":0}\n' "$pd" > "$2/projects.jsonl"
  ( [ -n "$1" ] && export SB_INJECT_PRECISION="$1"
    printf '{"hook_event_name":"SessionStart","session_id":"prec-sl-%s","cwd":"%s"}' "${1:-unset}" "$pd" \
      | CLAUDE_PROJECT_DIR="$pd" BRAIN_DIR="$2" KNOWLEDGE_DIR="$CORPUS" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$CORPUS" \
        SECOND_BRAIN_DISABLE_EMBEDDINGS="${SECOND_BRAIN_DISABLE_EMBEDDINGS-1}" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/session-load.sh" 2>"$2/hook-stderr.log" ) | tr -d '\r'
}
# prec_rows FILE SCRIPT: rows the switch wrote for SCRIPT (any shape) — the "writes nothing" probe.
prec_rows(){ [ -f "$1" ] || { echo 0; return; }; grep -F "\"script\":\"$2\"" "$1" | grep -cE 'inject-precision|SB_INJECT_PRECISION' | tr -d ' \r'; }
# trace_rows FILE SCRIPT: audit rows in EXACTLY the shape bash sb_log_error gives a rerouted gate row.
trace_rows(){
  [ -f "$1" ] || { echo 0; return; }
  grep -cE '^\{"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z","script":"'"$2"'","message":"gate=inject-precision mode=off","exit_code":0\}$' "$1" | tr -d ' \r'
}
# bogus_rows FILE SCRIPT: error rows naming the unrecognised value, exit_code 1.
bogus_rows(){ [ -f "$1" ] || { echo 0; return; }; grep -F "\"script\":\"$2\"" "$1" | grep -F 'SB_INJECT_PRECISION=\"bogus\" is not recognised' | grep -cF '"exit_code":1}' | tr -d ' \r'; }

PB_OFF="$EB/prec-off"; PB_ZERO="$EB/prec-zero"; PB_BOGUS="$EB/prec-bogus"; PB_UNSET="$EB/prec-unset"
mkdir -p "$PB_OFF" "$PB_ZERO" "$PB_BOGUS" "$PB_UNSET"
CTX_OFF=$(hook_prompt off "$PB_OFF")
if has "$CTX_OFF" "$STUB_SLUG"; then
  pass "persona-context.sh, SB_INJECT_PRECISION=off: the per-prompt hook injects the stub the R1 gate refuses"
  [ "$(trace_rows "$PB_OFF/audit-log.jsonl" context-serve-cli)" = 1 ] \
    && pass "off: exactly one gate=inject-precision TRACE row from context-serve-cli in audit-log.jsonl (sb_log_error gate-row shape)" \
    || fail "off: expected one '{timestamp,script:context-serve-cli,message:gate=inject-precision mode=off,exit_code:0}' row in audit-log.jsonl, got $(trace_rows "$PB_OFF/audit-log.jsonl" context-serve-cli): $(grep -F inject-precision "$PB_OFF/audit-log.jsonl" 2>/dev/null | head -2 | tr '\n' ';')"
  [ "$(prec_rows "$PB_OFF/error-log.jsonl" context-serve-cli)" = 0 ] \
    && pass "off: a recognised value leaves no error row" \
    || fail "off: a recognised value wrote an SB_INJECT_PRECISION error row"
  has "$(hook_prompt 0 "$PB_ZERO")" "$STUB_SLUG" && [ "$(trace_rows "$PB_ZERO/audit-log.jsonl" context-serve-cli)" = 1 ] \
    && pass "persona-context.sh, SB_INJECT_PRECISION=0: the rollback too (SB_INJECT_GATE's vocabulary), with its TRACE row" \
    || fail "SB_INJECT_PRECISION=0 did not roll the per-prompt gate back (or wrote no TRACE row) — the vocabulary differs from SB_INJECT_GATE's"
  if has "$(hook_prompt bogus "$PB_BOGUS")" "$STUB_SLUG"; then
    fail "persona-context.sh, SB_INJECT_PRECISION=bogus: the stub was injected — an unrecognised value rolled the gate back"
  else
    pass "persona-context.sh, SB_INJECT_PRECISION=bogus: the R1 gate holds"
  fi
  [ "$(bogus_rows "$PB_BOGUS/error-log.jsonl" context-serve-cli)" = 1 ] \
    && pass "bogus: exactly one error row from context-serve-cli in error-log.jsonl (the hook discards stderr)" \
    || fail "bogus: expected one context-serve-cli error row for SB_INJECT_PRECISION=\"bogus\" in error-log.jsonl, got $(bogus_rows "$PB_BOGUS/error-log.jsonl" context-serve-cli)"
  [ "$(trace_rows "$PB_BOGUS/audit-log.jsonl" context-serve-cli)" = 0 ] \
    && pass "bogus: no TRACE row (the R1 gate is in force)" || fail "bogus: a gate=inject-precision TRACE row was written although the R1 gate is in force"
  if has "$(hook_prompt "" "$PB_UNSET")" "$STUB_SLUG"; then
    fail "persona-context.sh, SB_INJECT_PRECISION unset: the stub was injected"
  elif [ "$(prec_rows "$PB_UNSET/audit-log.jsonl" context-serve-cli)" != 0 ] || [ "$(prec_rows "$PB_UNSET/error-log.jsonl" context-serve-cli)" != 0 ]; then
    fail "SB_INJECT_PRECISION unset: the switch wrote a row on the default path (per-prompt cost)"
  else
    pass "persona-context.sh, SB_INJECT_PRECISION unset: the R1 gate holds and the switch writes nothing"
  fi
else
  fail "persona-context.sh, SB_INJECT_PRECISION=off: the stub was not injected — the rollback does not reach the per-prompt hook (or the hook served nothing; stderr: $(head -c 300 "$PB_OFF/hook-stderr.log" 2>/dev/null | tr '\n' ' '))"
fi

# SessionStart enrichment: the same switch through session-load.sh -> knowledge-search-cli.
SL_OFF="$EB/prec-sl-off"; SL_BOG="$EB/prec-sl-bogus"; mkdir -p "$SL_OFF" "$SL_BOG"
if has "$(hook_session off "$SL_OFF")" "$STUB_SLUG"; then
  pass "session-load.sh, SB_INJECT_PRECISION=off: SessionStart enrichment injects the stub the R1 gate refuses"
  [ "$(trace_rows "$SL_OFF/audit-log.jsonl" knowledge-search-cli)" -ge 1 ] \
    && pass "off: session-load's knowledge-search-cli run leaves a gate=inject-precision TRACE row" \
    || fail "off: no gate=inject-precision TRACE row from knowledge-search-cli in audit-log.jsonl"
  if has "$(hook_session bogus "$SL_BOG")" "$STUB_SLUG"; then
    fail "session-load.sh, SB_INJECT_PRECISION=bogus: SessionStart enrichment injected the stub"
  else
    pass "session-load.sh, SB_INJECT_PRECISION=bogus: the R1 gate holds at SessionStart"
  fi
  [ "$(bogus_rows "$SL_BOG/error-log.jsonl" knowledge-search-cli)" -ge 1 ] \
    && pass "bogus: session-load's knowledge-search-cli run leaves an error row in error-log.jsonl" \
    || fail "bogus: no knowledge-search-cli error row for SB_INJECT_PRECISION=\"bogus\" in error-log.jsonl"
else
  fail "session-load.sh, SB_INJECT_PRECISION=off: the stub was not enriched — the rollback does not reach SessionStart (or the enrichment never ran; stderr: $(head -c 300 "$SL_OFF/hook-stderr.log" 2>/dev/null | tr '\n' ' '))"
fi

# Nothing may slip between the last verdict and the summary.
cli_crashed && { FAIL=$((FAIL+1)); echo "  FAIL: a CLI exited non-zero after the last verdict"; }
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
