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
