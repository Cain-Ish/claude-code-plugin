#!/bin/bash
# SP-D: sb-prune-archives.sh — regenerable/dead-only GC. (a) embeddings-cache: drop episodic
# entries with no live exchange, keep live + concept-*. (b) *.bak/*.tgz past TTL pruned, recent
# kept. NEVER touches transcripts / wiki-archive / episodic-index. Gated by config.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; PRUNE="$ROOT/scripts/sb-prune-archives.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }

B=$(mktemp -d); export BRAIN_DIR="$B"; mkdir -p "$B/transcripts"

# --- (a) embeddings-cache GC: live index has live1/live2; cache has those + dead1/dead2 + concept-0
printf '{"model":"m","exchanges":[{"id":"live1"},{"id":"live2"}]}\n' > "$B/episodic-index.json"
CACHE="$B/transcripts/.embeddings-cache.json"
printf '{"model":"m","entries":{"episodic:live1":{"hash":"h","vector":[1]},"episodic:live2":{"hash":"h","vector":[1]},"episodic:dead1":{"hash":"h","vector":[1]},"episodic:dead2":{"hash":"h","vector":[1]},"concept-0":{"hash":"h","vector":[1]}}}\n' > "$CACHE"
bash "$PRUNE" >/dev/null 2>&1 || true
jq -e '.entries["episodic:live1"] and .entries["episodic:live2"]' "$CACHE" >/dev/null 2>&1 && pass "GC keeps live episodic entries" || fail "GC dropped a live entry"
{ jq -e '.entries["episodic:dead1"] // .entries["episodic:dead2"]' "$CACHE" >/dev/null 2>&1; } && fail "GC kept a dead entry (the leak)" || pass "GC dropped dead episodic entries (the leak)"
jq -e '.entries["concept-0"]' "$CACHE" >/dev/null 2>&1 && pass "GC keeps non-episodic (concept-*) entries" || fail "GC dropped a concept entry"

# GC off → cache untouched
printf '{"model":"m","entries":{"episodic:dead9":{"hash":"h","vector":[1]}}}\n' > "$CACHE"
printf '{"retention":{"embeddings_cache_gc":false}}\n' > "$B/config.json"
bash "$PRUNE" >/dev/null 2>&1 || true
jq -e '.entries["episodic:dead9"]' "$CACHE" >/dev/null 2>&1 && pass "embeddings_cache_gc:false → cache untouched" || fail "GC ran despite the off switch"
rm -f "$B/config.json"

# EMPTY/rebuilding index (exchanges: []) → must NOT mass-drop the cache (deep-review HIGH).
# The plugin's own degraded-embeddings banner tells users to remove+reindex; during that
# window the index is empty but the cache must survive (else a needless full re-embed).
printf '{"model":"m","exchanges":[]}\n' > "$B/episodic-index.json"
printf '{"model":"m","entries":{"episodic:keepme":{"hash":"h","vector":[1]}}}\n' > "$CACHE"
bash "$PRUNE" >/dev/null 2>&1 || true
jq -e '.entries["episodic:keepme"]' "$CACHE" >/dev/null 2>&1 && pass "empty index → cache left intact (no mass-drop)" || fail "empty/rebuilding index wiped the cache (mass-drop)"
# restore a populated index for the rest of the run
printf '{"model":"m","exchanges":[{"id":"live1"},{"id":"live2"}]}\n' > "$B/episodic-index.json"

# D159: a torn/truncated episodic-index.json (present but unparseable — a crash mid-write,
# not the ordinary "no index yet" case) must NOT cause deletion — the GC must skip and fail
# LOUD (sb_log_error), not silently look identical to "nothing to prune this run".
printf '{"model":"m","entries":{"episodic:keepme2":{"hash":"h","vector":[1]}}}\n' > "$CACHE"
printf '{"model":"m","exchanges":[{"id":"live1"' > "$B/episodic-index.json"   # truncated, no trailing newline
rm -f "$B/error-log.jsonl"
bash "$PRUNE" >/dev/null 2>&1 || true
jq -e '.entries["episodic:keepme2"]' "$CACHE" >/dev/null 2>&1 && pass "torn episodic-index → cache left untouched (no deletion)" || fail "torn episodic-index caused a deletion"
grep -q 'unparseable' "$B/error-log.jsonl" 2>/dev/null && pass "torn episodic-index logged loudly via sb_log_error" || fail "torn episodic-index was skipped silently (not logged)"
# restore a populated index for the rest of the run
printf '{"model":"m","exchanges":[{"id":"live1"},{"id":"live2"}]}\n' > "$B/episodic-index.json"

# --- (b) .bak/.tgz TTL prune: recent kept, ancient pruned
touch "$B/recent.bak"
touch -t 202001010000 "$B/old.bak" "$B/old.tgz" "$B/episodic-index.json.pre-rebuild-x"
bash "$PRUNE" >/dev/null 2>&1 || true
[ -f "$B/recent.bak" ] && pass "recent .bak kept (under TTL)" || fail "pruned a recent .bak"
{ [ ! -f "$B/old.bak" ] && [ ! -f "$B/old.tgz" ] && [ ! -f "$B/episodic-index.json.pre-rebuild-x" ]; } && pass "old .bak/.tgz/pre-rebuild pruned" || fail "old dead-weight survived"

# --- safety: transcripts + episodic-index are NEVER touched
: > "$B/transcripts/sess_proj_2026-01-01.txt"; touch -t 202001010000 "$B/transcripts/sess_proj_2026-01-01.txt"
bash "$PRUNE" >/dev/null 2>&1 || true
[ -f "$B/transcripts/sess_proj_2026-01-01.txt" ] && pass "transcripts never pruned (re-extraction + episodic source)" || fail "pruned a transcript!"
[ -f "$B/episodic-index.json" ] && pass "episodic-index never deleted" || fail "deleted the episodic-index!"

# --- structural: no CODE line operates on the wiki-archive (the irreversible store, deferred).
# Ignore comments (they reference it to explain the deliberate avoidance).
grep -vE '^[[:space:]]*#' "$PRUNE" | grep -q 'wiki-archive' && fail "a code line in sb-prune-archives touches the wiki-archive (irreversible — must be deferred)" || pass "wiki-archive untouched by code (irreversible store deferred)"

# --- (c) wiki embeddings-cache eviction: an entry keyed by a .md path that no longer
# exists is dropped; the live entry survives lossless (hash+vector intact). The wiki
# cache lives under <knowledge_dir>/wiki, resolved by sb_knowledge_dir → set KNOWLEDGE_DIR.
export KNOWLEDGE_DIR="$B/knowledge"
mkdir -p "$B/knowledge/wiki/learnings"
LIVEP="$B/knowledge/wiki/learnings/live.md"; : > "$LIVEP"
DEADP="$B/knowledge/wiki/learnings/dead.md"   # deliberately never created
WCACHE="$B/knowledge/wiki/.embeddings-cache.json"
jq -n --arg lp "$LIVEP" --arg dp "$DEADP" \
  '{model:"m", entries: {($lp): {hash:"h", vector:[1,2,3]}, ($dp): {hash:"h", vector:[9]}}}' > "$WCACHE"
bash "$PRUNE" >/dev/null 2>&1 || true
jq -e --arg dp "$DEADP" '.entries | has($dp) | not' "$WCACHE" >/dev/null 2>&1 && pass "wiki cache: dead .md path evicted" || fail "wiki cache: dead path survived"
jq -e --arg lp "$LIVEP" '.entries[$lp].hash=="h" and (.entries[$lp].vector==[1,2,3])' "$WCACHE" >/dev/null 2>&1 && pass "wiki cache: live entry kept byte-identical (lossless)" || fail "wiki cache: live entry dropped or mutated"
jq -e '(.entries | length)==1' "$WCACHE" >/dev/null 2>&1 && pass "wiki cache: exactly the survivor remains" || fail "wiki cache: wrong entry count after eviction"
unset KNOWLEDGE_DIR

rm -rf "$B"; echo; echo "ALL PASS"
