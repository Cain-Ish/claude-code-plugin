#!/bin/bash
# pins: SB_SESSION_LOAD_SOFT_S — lifts session-load's soft time budget: on a loaded box the hook passes 9s before the enrichment and skips the very spawn this test observes
# 0.29.4: session-load.sh harvests PROJ_KW keywords from the active PROJECT.md and, when
# non-empty, calls the knowledge-search CLI to enrich the SessionStart context with the
# project's wiki notes. The harvest used awk RANGE expressions (/^## X$/,/^## /) whose
# START line also matches the END pattern, collapsing every range to its header → PROJ_KW
# was ALWAYS empty → the enrichment NEVER ran (every session silently missing wiki recall),
# and NO test covered it. ORACLE: stub `node` so the search CLI emits a sentinel ONLY when
# invoked with a non-empty query; the sentinel in the real session-load output proves the
# harvest produced keywords. With the range-collapse bug the gate is never taken, node is
# never called, and the sentinel is absent — so this test is discriminating.
set -u
# A headless parent (claude -p) would make session-load's headless-child gate exit silently and
# turn every absence/presence check below into a vacuous pass or a false fail.
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
. "$ROOT/scripts/lib.sh" >/dev/null 2>&1

# The real search-CLI bundle must exist for session-load's `[ -f "$SEARCH_CLI" ]` gate;
# we don't run it — `node` is stubbed to stand in for it.
SEARCH_CLI="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
[ -f "$SEARCH_CLI" ] || { echo "SKIP: search CLI bundle not built"; echo; echo "ALL PASS"; exit 0; }

STUB=$(mktemp -d)
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"
# node stub: emit the sentinel ONLY for the knowledge-search CLI call AND only when the
# query (last arg) is non-empty — i.e. only when PROJ_KW actually harvested something.
cat > "$STUB/node" <<'NODE'
#!/bin/bash
case "$*" in
  *knowledge-search-cli*)
    q="${!#}"
    [ -n "${WIKI_Q_CAPTURE:-}" ] && printf '%s' "$q" > "$WIKI_Q_CAPTURE"
    [ -n "${q// /}" ] && printf 'demo-note :: WIKIENRICH_SENTINEL gate=%s' "${SB_INJECT_GATE:-unset}"
    ;;
esac
exit 0
NODE
chmod +x "$STUB/node"

B=$(mktemp -d); PROJDIR=$(mktemp -d)
SLUG=$(sb_slug_from_dir "$PROJDIR")
mkdir -p "$B/projects/$SLUG" "$B/transcripts" "$B/knowledge/wiki"

# A realistically-populated PROJECT.md: every harvested section filled with words that
# survive the stopword filter (backbone, failover, BM25, escalation slugs).
cat > "$B/projects/$SLUG/PROJECT.md" <<'EOF'
# PROJECT: demo
## Goal
Build the Pi automation backbone with local-LLM failover.
## State
Router shipping; knowledge base self-healing.
## Recent decisions
- chose BM25 over pure vector for recall accuracy
## Open blockers
- vector dependencies offline on a fresh install
## Cross-references
See [[routing-patterns]] and [[crlf-frontmatter]].
EOF
printf '{"slug":"%s","path":"%s","plan_done":0,"plan_total":0}\n' "$SLUG" "$PROJDIR" > "$B/projects.jsonl"

run_sl() {
  printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJDIR" \
    | env PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$PROJDIR" BRAIN_DIR="$B" SB_SESSION_LOAD_SOFT_S=600 \
          WIKI_Q_CAPTURE="$B/query.txt" KNOWLEDGE_DIR="$B/knowledge" ANTHROPIC_API_KEY="" bash "$SL" 2>/dev/null
}
OUT=$(run_sl)

printf '%s' "$OUT" | grep -q 'WIKIENRICH_SENTINEL' \
  || fail "wiki-enrichment did not fire — PROJ_KW harvest is empty (awk range-collapse?); session starts without project wiki recall"
pass "PROJECT.md harvest is non-empty → wiki-enrichment invokes the search CLI (sentinel present)"

# 0.55.0 (R1#4): SessionStart enrichment injects into the session, so it must ask the CLI for the
# per-prompt injection gate (no stubs, discriminative grounding, +1 term cross-project).
printf '%s' "$OUT" | grep -q 'WIKIENRICH_SENTINEL gate=1' \
  || fail "wiki-enrichment called the search CLI without SB_INJECT_GATE=1 — stubs/cross-project noise reach the session card"
pass "wiki-enrichment asks the search CLI for the injection gate (SB_INJECT_GATE=1)"

# 0.30.0 cross-OS: a CRLF PROJECT.md (Windows / imported) must NOT defeat the harvest. Every
# `/^## Section$/` awk reader fails on `## Section\r`, so without the CR-normalization the harvest
# is empty and the enrichment never fires — even though the same content works in LF above.
sed 's/$/\r/' "$B/projects/$SLUG/PROJECT.md" > "$B/projects/$SLUG/PROJECT.md.crlf" && mv "$B/projects/$SLUG/PROJECT.md.crlf" "$B/projects/$SLUG/PROJECT.md"
# Use od for CR detection: Git-Bash grep reads in text mode and strips \r from CRLF pairs,
# so `grep -q $'\r'` always exits 1 even when CR bytes are present. od is binary-safe.
od -An -tx1 "$B/projects/$SLUG/PROJECT.md" 2>/dev/null | grep -q ' 0d' || fail "test setup: PROJECT.md is not actually CRLF"
OUT_CRLF=$(run_sl)
printf '%s' "$OUT_CRLF" | grep -q 'WIKIENRICH_SENTINEL' \
  || fail "CRLF PROJECT.md defeated the harvest — session-load did not CR-normalize before the awk readers"
pass "CRLF PROJECT.md still harvests (session-load normalizes \\r before the awk readers)"

# D6 (2026-10-07): the query was the ALPHABETICALLY first 10 distinct words (`sort -u | head -10`;
# live: "aaf ab abf about above absent ...", 0 hits on the live wiki — "aaf"/"abf" are what a
# commit hash leaves once its digits are split off). Contract now: weighted frequency, a Goal/State
# occurrence counting 3, no token under 3 chars, no token holding a digit, top 10, ties in
# first-seen order. Scores for this fixture: tracking 6 (Goal+State), rig 4 (State+decision),
# zebrafish/larvae/online 3, wireguard 3 (three decisions), then the once-only words in order.
# Ten alphabetically-early once-only words sit in a decision, AFTER a hash, so the old query was
# "Zebrafish aaf abacus abf able absent acorn adder aft agile" and lost every other salient word.
cat > "$B/projects/$SLUG/PROJECT.md" <<'EOF'
# PROJECT: demo
## Goal
Zebrafish larvae tracking.
## State
Tracking rig online on the Pi.
## Recent decisions
- [2026-10-01] commit 1aaf3e2 abf09c1: abacus able absent acorn adder aft agile amber ample apex
- [2026-10-02] wireguard tunnel for the rig
- [2026-10-03] wireguard keys rotated, wireguard config moved
## Open blockers
- none
EOF
rm -f "$B/query.txt"; run_sl >/dev/null
Q=$(cat "$B/query.txt" 2>/dev/null)
[ "$Q" = "tracking rig zebrafish larvae online wireguard commit abacus able absent" ] \
  || fail "salience query wrong: got [$Q], want [tracking rig zebrafish larvae online wireguard commit abacus able absent]"
pass "enrichment query ranks by weighted frequency (Goal/State x3), drops hash fragments and short tokens"

# Weighting, isolated: a word ONCE in the Goal (3) outranks a word TWICE in Open blockers (2).
cat > "$B/projects/$SLUG/PROJECT.md" <<'EOF'
# PROJECT: demo
## Goal
Quokka habitat survey.
## Open blockers
- firmware flashing fails; firmware vendor silent
EOF
rm -f "$B/query.txt"; run_sl >/dev/null
Q=$(cat "$B/query.txt" 2>/dev/null)
[ "$Q" = "quokka habitat survey firmware flashing fails vendor silent" ] \
  || fail "Goal weighting wrong: got [$Q], want [quokka habitat survey firmware flashing fails vendor silent]"
pass "a Goal word outranks a more frequent blocker word"

# Q-L13 (R3 review): the weighting was only checked on an LF file. Same file as CRLF: the Goal/State
# x3 weight keys on `^## Goal$`, which a trailing \r would defeat (every word would count 1 and the
# query would reorder), so the CRLF query must be the LF one exactly.
sed 's/$/\r/' "$B/projects/$SLUG/PROJECT.md" > "$B/projects/$SLUG/PROJECT.md.crlf" && mv "$B/projects/$SLUG/PROJECT.md.crlf" "$B/projects/$SLUG/PROJECT.md"
od -An -tx1 "$B/projects/$SLUG/PROJECT.md" 2>/dev/null | grep -q ' 0d' || fail "Q-L13 setup: PROJECT.md is not CRLF"
rm -f "$B/query.txt"; run_sl >/dev/null
Q=$(cat "$B/query.txt" 2>/dev/null)
[ "$Q" = "quokka habitat survey firmware flashing fails vendor silent" ] \
  || fail "Goal weighting under CRLF wrong: got [$Q], want [quokka habitat survey firmware flashing fails vendor silent]"
pass "a CRLF PROJECT.md weights its Goal words the same as the LF file"

rm -rf "$B" "$PROJDIR" "$STUB"; echo; echo "ALL PASS"
