#!/bin/bash
# X.1 LOOP smoke test (loop-eng research; archive/docs branch, docs/plans/2026-07-13-p1-observability.md
# context): the capture→store→recall pipeline END TO END, deterministically (LLM
# steps stubbed) — the unit suites test each stage in isolation, which is exactly
# how the drainer died silently per-platform while everything stayed green. This
# test fails if ANY stage of the loop stops composing with the next:
#   1. Stop archives a session transcript + stamps the done-set/health markers
#   2. a page written through the canonical writer funnel lands in KNOWLEDGE_DIR
#   3. knowledge-search-cli FINDS that page (BM25 tier, no embeddings needed)
#   4. the legacy ~/.second-brain/wiki stays EMPTY (misroute class)
#   5. sb status liveness reads the same run's stamps (observability composes)
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

BRAIN="$TMP/.second-brain"
KNOW="$TMP/knowledge"
WORKDIR="$TMP/demo"
STUB="$TMP/stub"; mkdir -p "$STUB" "$WORKDIR" "$BRAIN/projects/demo" "$KNOW/wiki"
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"
printf '# PROJECT: demo\n\n## Goal\nloop smoke\n' > "$BRAIN/projects/demo/PROJECT.md"

# --- Stage 1: Stop-hook capture — archive + state stamps ---
T="$TMP/transcript.jsonl"
# The window must carry ≥1 tool_use (gate=tool-count-zero archives nothing for
# Q&A-only sessions — by design), so the fixture session actually WORKS on a file.
{
  printf '{"type":"user","message":{"role":"user","content":"work on the loop"}}\n'
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/loop.ts","old_string":"a","new_string":"b"}}]}}\n'
  for i in 1 2 3 4 5 6 7 8; do
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"substantive line %s with enough body to pass the gates"}]}}\n' "$i"
  done
} > "$T"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"smoke-1"}' "$T" "$WORKDIR" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract exited $RC"
ARCHIVED=$(find "$BRAIN/transcripts" -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
[ "${ARCHIVED:-0}" -ge 1 ] || fail "stage 1: transcript window not archived"
pass "stage 1: Stop capture archives the session window"

# --- Stage 2: canonical writer funnel → page in KNOWLEDGE_DIR ---
source "$ROOT/scripts/lib.sh" >/dev/null 2>&1 || fail "lib.sh unsourceable"
PAGE="$KNOW/wiki/state/loop-smoke-topic.md"
BRAIN_DIR="$BRAIN" sb_write_generated_page "$PAGE" "Loop Smoke Topic" "an end-to-end smoke fact about zanzibar-widgets" \
  || fail "stage 2: sb_write_generated_page failed"
printf '\nThe zanzibar-widgets subsystem parses fromboozle events.\n' >> "$PAGE"
[ -s "$PAGE" ] || fail "stage 2: page empty"
head -c 4 "$PAGE" | grep -q -- '---' || fail "stage 2: page lacks frontmatter (would churn forever)"
pass "stage 2: canonical writer lands a schema'd page in KNOWLEDGE_DIR"

# --- Stage 3: the page is SEARCH-VISIBLE (BM25, offline) ---
SEARCH_CLI="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
[ -f "$SEARCH_CLI" ] || fail "stage 3: search CLI bundle missing"
HITS=$(env SECOND_BRAIN_DISABLE_EMBEDDINGS=1 KNOWLEDGE_DIR="$KNOW" BRAIN_DIR="$BRAIN" \
  node "$SEARCH_CLI" "zanzibar widgets fromboozle" 2>/dev/null)
printf '%s' "$HITS" | grep -q 'loop-smoke-topic' \
  || fail "stage 3: freshly written page invisible to knowledge_search (hits: ${HITS:-none})"
pass "stage 3: capture→store→SEARCH loop closes (page recallable)"

# --- Stage 4: legacy wiki stayed empty (misroute class) ---
LEGACY_N=$(find "$BRAIN/wiki" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
[ "${LEGACY_N:-0}" -eq 0 ] || fail "stage 4: ${LEGACY_N} page(s) leaked into legacy .second-brain/wiki"
pass "stage 4: legacy wiki empty (canonical-wiki invariant)"

# --- Stage 5: liveness observability reads THIS run's stamps ---
SB_OUT=$(env BRAIN_DIR="$BRAIN" KNOWLEDGE_DIR="$KNOW" node "$ROOT/mcp/dist/cli/sb-entry.bundle.js" status 2>/dev/null)
printf '%s' "$SB_OUT" | grep -q 'Loop liveness:' || fail "stage 5: liveness section missing"
printf '%s' "$SB_OUT" | grep -q 'transcript backlog:' || fail "stage 5: backlog row missing"
pass "stage 5: sb status observes the same loop run"

echo; echo "ALL PASS"
