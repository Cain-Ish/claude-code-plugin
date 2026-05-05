#!/bin/bash
source "$(dirname "$0")/lib.sh"
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"

mkdir -p "$BRAIN_DIR/projects"
mkdir -p "$BRAIN_DIR/regressions"
mkdir -p "$KNOWLEDGE_DIR/wiki"/{concepts,entities,learnings}
test -f "$BRAIN_DIR/projects.jsonl" || : > "$BRAIN_DIR/projects.jsonl"

WIKI_INDEX="$KNOWLEDGE_DIR/wiki/index.md"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
REINDEX_JS="$PLUGIN_ROOT/mcp/dist/tools/knowledge-reindex.js"
VALIDATE_JS="$PLUGIN_ROOT/mcp/dist/tools/knowledge-validate.js"

if command -v node >/dev/null 2>&1; then
  # Reindex generates index.md AND runs validation with autofix
  if [ ! -f "$WIKI_INDEX" ] && [ -f "$REINDEX_JS" ]; then
    node -e "
      import { knowledgeReindex } from '$REINDEX_JS';
      knowledgeReindex('$KNOWLEDGE_DIR').catch(() => {});
    " 2>/dev/null || true
  elif [ -f "$VALIDATE_JS" ]; then
    # Even if index exists, run validation to autofix issues
    node -e "
      import { knowledgeValidate } from '$VALIDATE_JS';
      knowledgeValidate('$KNOWLEDGE_DIR', { autofix: true }).catch(() => {});
    " 2>/dev/null || true
  fi
fi

exit 0
