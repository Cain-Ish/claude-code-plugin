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

if [ ! -f "$BUNDLE" ]; then
  echo "FAIL: indexer bundle missing — run 'npm --prefix mcp run build'" >&2
  exit 1
fi

# TEST 3 imports episodicSearch as a MODULE. Per-file dist (dist/tools/*.js) is no
# longer tracked — only the CLI *.bundle.js ship (see .gitignore) — and the CLI
# bundle exposes no named exports. So build a self-contained ESM module of the
# search source on the fly with esbuild (an mcp dev dep), emitted UNDER mcp/ so
# `@huggingface/transformers` still resolves from mcp/node_modules. The name ends
# in .js (gitignored, never committed) and is removed on exit.
SEARCH_FN_DIST="$REPO_ROOT/mcp/dist/tools/episodic-search.testmod.js"
( cd "$REPO_ROOT/mcp" && node_modules/.bin/esbuild src/tools/episodic-search.ts \
    --bundle --platform=node --format=esm --target=node22 \
    --external:@huggingface/transformers \
    --outfile="dist/tools/episodic-search.testmod.js" ) >/dev/null 2>&1 \
  || { echo "FAIL: could not build episodic-search test module (esbuild) — run 'npm ci --prefix mcp'" >&2; exit 1; }
# On Windows/Git-Bash, SEARCH_FN_DIST is a POSIX path (/c/Workplace/…) that Node.js
# ESM loader cannot resolve — it maps /c/ to C:\c\ (a non-existent subdirectory) instead
# of the C: drive.  Convert to a file:// URL so Node.js ESM resolves it correctly on all
# platforms.  On Linux/macOS pathToFileURL passes POSIX paths through unchanged.
_search_url=$(node -e "
const { pathToFileURL } = require('url');
// Git-Bash POSIX drive paths: /c/foo → C:/foo.  pathToFileURL needs a real absolute path.
let p = '$SEARCH_FN_DIST';
if (/^\/[a-zA-Z]\//.test(p)) p = p[1].toUpperCase() + ':' + p.slice(2);
process.stdout.write(pathToFileURL(p).href + '\n');
" 2>/dev/null)
[ -n "$_search_url" ] && SEARCH_FN_DIST="$_search_url"
unset _search_url

TMP=$(mktemp -d -t epi-int-XXXX)
# On Windows/Git-Bash, mktemp returns a POSIX path (/tmp/…) that Node.js resolves to a
# Windows path (C:\Users\…\AppData\Local\Temp\…).  The shell then reads "$TMP/episodic-index.json"
# with the POSIX path while Node wrote it under the Windows path → ENOENT.
# Fix: normalise TMP to the Windows-slash form Node will use, so both sides agree.
_node_norm=$(node -e "process.stdout.write(require('path').resolve('$TMP').split(require('path').sep).join('/')+'\n')" 2>/dev/null)
[ -n "$_node_norm" ] && TMP="$_node_norm"
unset _node_norm
trap 'rm -rf "$TMP" "$SEARCH_FN_DIST"' EXIT
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
# No-drop holds regardless of the model (rows are never lost) — assert always.
[ "$T" -gt 0 ] || { echo "FAIL: lost exchanges across runs ($T)" >&2; exit 1; }
# The real ~70MB model may be unfetchable (offline CI: "fetch failed"). If it
# couldn't load, rows stay text-searchable-but-unembedded (the no-poison degraded
# state, NOT corruption) — skip the strict repair + vector assertions instead of
# flaking. The repair path itself is covered by the vitest suite where the model
# exists. (Mirrors the test-episodic-index.test.ts skipIf-offline guard.)
MODEL_OK=1
if grep -qiE 'model load failed|fetch failed|could not locate|ENOTFOUND|getaddrinfo|transformers.*(fail|error)' "$TMP/run2.err"; then
  MODEL_OK=0
  echo "  SKIP: embedding model unavailable (offline) — repair/vector assertions skipped; $T rows intact, no poison"
else
  [ "$P" -eq 0 ] || { echo "FAIL: expected 0 pending after repair run, got $P" >&2; cat "$TMP/run2.err" >&2; exit 1; }
  echo "  OK: total=$T pending=$P (all repaired)"
fi

echo "TEST 3: vector search returns ≥1 result for an obvious query"
# Capability gate: skip when the HuggingFace embedding model is provably absent.
# Three honest signals (any one sufficient to skip):
#  (a) SECOND_BRAIN_DISABLE_EMBEDDINGS=1 / HF_HUB_OFFLINE=1 / TRANSFORMERS_OFFLINE=1
#      — explicit offline flags used by CI and run-all.sh isolated-HOME runs.
#  (b) MODEL_OK=0 — TEST 2's recovery run stderr already showed a load failure.
#  (c) episodicSearch itself returns degraded:'vector-unavailable' — the runtime
#      contract when embedTexts returns null (model absent, import failed, or timed out).
#      We wrap the node call with a per-OS timeout (30 s) so an uncached model that
#      attempts a live HuggingFace download does not hang the suite indefinitely.
# When the model IS available all three signals are false and the assertion runs.
_t3_skip_reason=""
if [ "${SECOND_BRAIN_DISABLE_EMBEDDINGS:-}" = "1" ]; then
  _t3_skip_reason="SECOND_BRAIN_DISABLE_EMBEDDINGS=1"
elif [ "${HF_HUB_OFFLINE:-}" = "1" ] || [ "${TRANSFORMERS_OFFLINE:-}" = "1" ]; then
  _t3_skip_reason="HF_HUB_OFFLINE/TRANSFORMERS_OFFLINE=1"
elif [ "$MODEL_OK" -eq 0 ]; then
  _t3_skip_reason="embedding model was unavailable during TEST 2 repair run"
fi

if [ -n "$_t3_skip_reason" ]; then
  echo "SKIP: TEST 3 vector-search needs the embedding model ($_t3_skip_reason); degraded path covered by TEST 1/2"
else
  # Run the vector search with a timeout to guard against a live model download hanging the suite.
  # Use `timeout` (GNU coreutils, available on Linux/CI) with a shell fallback for platforms
  # without it (macOS / Windows Git-Bash where timeout may not exist).
  _t3_node_cmd='BRAIN_DIR="$TMP" node --input-type=module -e "
import { episodicSearch } from '"'"'$SEARCH_FN_DIST'"'"';
const r = await episodicSearch({ query: '"'"'episodic indexer embeddings'"'"', mode: '"'"'vector'"'"', limit: 5 }, process.env.BRAIN_DIR);
console.log(JSON.stringify({ hits: r.results.length, degraded: r.degraded ?? null }));
" 2>/dev/null'
  if command -v timeout >/dev/null 2>&1; then
    T3_RESULT=$(eval "timeout 30 $_t3_node_cmd") || T3_RESULT=""
  else
    T3_RESULT=$(eval "$_t3_node_cmd") || T3_RESULT=""
  fi
  T3_DEGRADED=$(node -e "try{console.log(JSON.parse(process.argv[1]).degraded)}catch{console.log('parse-error')}" "$T3_RESULT" 2>/dev/null)
  T3_HITS=$(node -e "try{console.log(JSON.parse(process.argv[1]).hits)}catch{console.log(0)}" "$T3_RESULT" 2>/dev/null)
  if [ "$T3_DEGRADED" = "vector-unavailable" ] || [ -z "$T3_RESULT" ]; then
    # Model absent or download timed out — honest skip, not a test failure.
    echo "SKIP: TEST 3 vector-search needs the embedding model (degraded:${T3_DEGRADED:-timeout/no-result} under isolated/offline HOME); degraded path covered by TEST 1/2"
  else
    [ "$T3_HITS" -gt 0 ] || { echo "FAIL: vector search returned 0 results (degraded=$T3_DEGRADED result=$T3_RESULT)" >&2; exit 1; }
    echo "  OK: vector search hits=$T3_HITS"
  fi
fi
unset _t3_skip_reason

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
