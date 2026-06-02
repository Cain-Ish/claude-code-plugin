#!/bin/bash
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
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
REINDEX_JS="$PLUGIN_ROOT/mcp/dist/tools/knowledge-reindex.bundle.js"
VALIDATE_JS="$PLUGIN_ROOT/mcp/dist/tools/knowledge-validate.bundle.js"

if command -v node >/dev/null 2>&1; then
  if [ ! -f "$WIKI_INDEX" ] && [ -f "$REINDEX_JS" ]; then
    SB_BUNDLE="$REINDEX_JS" SB_KDIR="$KNOWLEDGE_DIR" node -e "
      import { knowledgeReindex } from process.env.SB_BUNDLE;
      knowledgeReindex(process.env.SB_KDIR).catch(() => {});
    " 2>/dev/null || true
  elif [ -f "$VALIDATE_JS" ]; then
    SB_BUNDLE="$VALIDATE_JS" SB_KDIR="$KNOWLEDGE_DIR" node -e "
      import { knowledgeValidate } from process.env.SB_BUNDLE;
      knowledgeValidate(process.env.SB_KDIR, { autofix: true }).catch(() => {});
    " 2>/dev/null || true
  fi
fi

exit 0
