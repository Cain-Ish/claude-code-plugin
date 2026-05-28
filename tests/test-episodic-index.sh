#!/usr/bin/env bash
# tests/test-episodic-index.sh — integration test for the episodic indexer
# Reproduces the production bug from 2026-05-22 (976/981 exchanges had
# empty embeddings) and confirms the v2.10.3 fix (repair-on-each-run).
#
# Strategy: build a tiny fake brain dir with one transcript, run the CLI
# bundle, assert state. Tests run against the dev repo's dist/, so they
# also catch regressions in the bundle layer (esbuild) not just the source.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE="$REPO_ROOT/mcp/dist/tools/episodic-index-cli.bundle.js"
SEARCH_FN_DIST="$REPO_ROOT/mcp/dist/tools/episodic-search.js"

if [ ! -f "$BUNDLE" ]; then
  echo "FAIL: indexer bundle missing — run 'npm --prefix mcp run build'" >&2
  exit 1
fi

TMP=$(mktemp -d -t epi-int-XXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/transcripts"

cat >"$TMP/transcripts/sess1_test_2026-05-22.txt" <<'EOF'
--- session-meta ---
session_id: sess1
project_slug: test
date: 2026-05-22
---

USER: explain how the episodic indexer caches embeddings for later semantic search
ASSISTANT: The indexer hashes each exchange, calls embedTexts, then writes a 384-dimensional vector into episodic-index.json keyed by exchange id.

USER: what happens when the model is unavailable
ASSISTANT: When @huggingface/transformers cannot be imported, embedTexts returns null and the rows are kept text-searchable while the next run repairs the embeddings.
EOF

count_pending() {
  node -e "const i=JSON.parse(require('fs').readFileSync('$TMP/episodic-index.json','utf-8'));console.log(i.exchanges.filter(e=>!e.embedding||e.embedding.length===0).length)"
}
count_total() {
  node -e "const i=JSON.parse(require('fs').readFileSync('$TMP/episodic-index.json','utf-8'));console.log(i.exchanges.length)"
}
count_indexed_files() {
  node -e "const i=JSON.parse(require('fs').readFileSync('$TMP/episodic-index.json','utf-8'));console.log(Object.keys(i.indexed_files).length)"
}

echo "TEST 1: degraded run (embeddings disabled) persists rows but marks them pending"
SECOND_BRAIN_DISABLE_EMBEDDINGS=1 BRAIN_DIR="$TMP" node "$BUNDLE" 2>"$TMP/run1.err" || { echo "FAIL: indexer exited non-zero" >&2; cat "$TMP/run1.err" >&2; exit 1; }
T=$(count_total); P=$(count_pending); F=$(count_indexed_files)
[ "$T" -gt 0 ] || { echo "FAIL: expected >0 exchanges, got $T" >&2; exit 1; }
[ "$P" -eq "$T" ] || { echo "FAIL: expected all $T pending under disabled, got $P pending" >&2; exit 1; }
[ "$F" -eq 1 ] || { echo "FAIL: expected indexed_files to track the file (text-searchable), got $F" >&2; exit 1; }
# Contract update (post-v0.21.1 embeddings-noise fix): SECOND_BRAIN_DISABLE_EMBEDDINGS=1
# is an opt-in, not an error. The disable acknowledgement goes to stderr only;
# error-log.jsonl must NOT receive an entry (previously this flooded the audit
# channel — every Node process startup re-logged because the in-memory dedup
# couldn't span processes).
grep -qE "embeddings.*disabled|disabled.*SECOND_BRAIN" "$TMP/run1.err" \
  || { echo "FAIL: expected disable acknowledgement on stderr (run1.err)" >&2; cat "$TMP/run1.err" >&2; exit 1; }
if [ -f "$TMP/error-log.jsonl" ] && grep -q "embeddings disabled" "$TMP/error-log.jsonl"; then
  echo "FAIL: disable acknowledgement was written to error-log.jsonl (should be stderr only)" >&2
  exit 1
fi
echo "  OK: total=$T pending=$P indexed_files=$F"

echo "TEST 2: recovery run (embeddings enabled) repairs all pending rows"
unset SECOND_BRAIN_DISABLE_EMBEDDINGS
BRAIN_DIR="$TMP" node "$BUNDLE" 2>"$TMP/run2.err"
T=$(count_total); P=$(count_pending)
[ "$P" -eq 0 ] || { echo "FAIL: expected 0 pending after repair run, got $P" >&2; cat "$TMP/run2.err" >&2; exit 1; }
[ "$T" -gt 0 ] || { echo "FAIL: lost exchanges across runs ($T)" >&2; exit 1; }
echo "  OK: total=$T pending=$P (all repaired)"

echo "TEST 3: vector search returns ≥1 result for an obvious query"
HITS=$(BRAIN_DIR="$TMP" node --input-type=module -e "
import { episodicSearch } from '$SEARCH_FN_DIST';
const r = await episodicSearch({ query: 'episodic indexer embeddings', mode: 'vector', limit: 5 }, process.env.BRAIN_DIR);
console.log(r.results.length);
" 2>/dev/null)
[ "$HITS" -gt 0 ] || { echo "FAIL: vector search returned 0 results" >&2; exit 1; }
echo "  OK: vector search hits=$HITS"

echo "TEST 4: multi-word text search tokenizes (matches non-contiguous tokens)"
HITS=$(BRAIN_DIR="$TMP" node --input-type=module -e "
import { episodicSearch } from '$SEARCH_FN_DIST';
const r = await episodicSearch({ query: 'episodic embeddings', mode: 'text', limit: 5 }, process.env.BRAIN_DIR);
console.log(r.results.length);
" 2>/dev/null)
[ "$HITS" -gt 0 ] || { echo "FAIL: tokenized text search returned 0 results" >&2; exit 1; }
echo "  OK: text search hits=$HITS"

echo "TEST 5: mode=both falls back to text when embeddings disabled"
HITS=$(SECOND_BRAIN_DISABLE_EMBEDDINGS=1 BRAIN_DIR="$TMP" node --input-type=module -e "
import { episodicSearch } from '$SEARCH_FN_DIST';
const r = await episodicSearch({ query: 'episodic embeddings', mode: 'both', limit: 5 }, process.env.BRAIN_DIR);
console.log(r.results.length);
" 2>/dev/null)
[ "$HITS" -gt 0 ] || { echo "FAIL: mode=both with disabled embeddings returned 0 (text fallback broken)" >&2; exit 1; }
echo "  OK: mode=both fallback hits=$HITS"

echo "ALL PASS"
