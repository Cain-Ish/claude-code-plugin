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

rm -rf "$B"; echo; echo "ALL PASS"
