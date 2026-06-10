#!/bin/bash
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0
source "$(dirname "$0")/lib.sh"
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"

mkdir -p "$BRAIN_DIR/projects"
mkdir -p "$BRAIN_DIR/regressions"
mkdir -p "$BRAIN_DIR/transcripts"
mkdir -p "$BRAIN_DIR/dreams"
mkdir -p "$BRAIN_DIR/wiki-archive"
# Wiki content-category dirs from the KB source of truth (kb-schema.json, via lib.sh -> kb-schema.sh).
# Creates ALL content categories (was only concepts/entities/learnings — the 3-vs-8 divergence).
for _c in ${SB_CONTENT_CATEGORIES:-learnings decisions entities issues concepts security state sources}; do
  mkdir -p "$KNOWLEDGE_DIR/wiki/$_c"
done
test -f "$BRAIN_DIR/projects.jsonl" || : > "$BRAIN_DIR/projects.jsonl"
# Seed a self-documenting config.json (SP-B opt-in + SP-D retention). auto_improve:false
# means behaviour is unchanged until the user opts in; the retention values equal the caps
# already shipped, so they are informational (absent keys fall back to the same defaults via
# sb_config_get). wiki_archive_ttl_days:0 = NEVER (the irreversible store stays off). Idempotent
# — never clobbers an existing config; existing installs keep working via the hardcoded defaults.
test -f "$BRAIN_DIR/config.json" || cat > "$BRAIN_DIR/config.json" <<'JSON'
{
  "auto_improve": false,
  "auto_maintain": false,
  "retention": {
    "dream_keep_count": 5,
    "bak_ttl_days": 14,
    "embeddings_cache_gc": true,
    "wiki_archive_ttl_days": 0
  }
}
JSON

# GC stale per-session injection memos. persona-context.sh writes one file per
# session-id under .injected/ and never deletes them — observed 189 files
# accumulated (one per Claude Code session in the last 30 days). 7-day TTL is
# generous: any session older than a week has no useful dedup signal anyway.
if [ -d "$BRAIN_DIR/.injected" ]; then
  find "$BRAIN_DIR/.injected" -maxdepth 1 -name '*.json' -type f -mtime +7 -delete 2>/dev/null || true
fi

# GC stale ghost projects. session-load.sh used to accept any $PWD basename as
# a project slug, so mktemp dirs like tmp.xK3p9q became permanent project
# directories with empty PROJECT.md. The session-load.sh slug guard prevents
# new ones; this prunes the existing 33+ ghosts. Only deletes dirs matching
# tmp.* whose PROJECT.md is empty or unmodified beyond scaffold (<200 bytes).
if [ -d "$BRAIN_DIR/projects" ]; then
  for d in "$BRAIN_DIR/projects"/tmp.*; do
    [ -d "$d" ] || continue
    pf="$d/PROJECT.md"
    if [ ! -f "$pf" ]; then
      rm -rf "$d" 2>/dev/null
      continue
    fi
    sz=$(wc -c < "$pf" 2>/dev/null | tr -d ' ')
    [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
    if [ "$sz" -lt 250 ]; then
      rm -rf "$d" 2>/dev/null
    fi
  done
fi

WIKI_INDEX="$KNOWLEDGE_DIR/wiki/index.md"
# Build the index on a fresh wiki, else validate+autofix an existing one. Delegated to the
# canonical lib.sh helpers (dynamic-import + error-logging) — NOT an inline `node -e`, which had
# carried a duplicate of the static-import-from-env SyntaxError bug that silently never ran.
if [ ! -f "$WIKI_INDEX" ]; then
  sb_reindex_wiki "$KNOWLEDGE_DIR"
else
  sb_validate_wiki "$KNOWLEDGE_DIR"
fi

exit 0
