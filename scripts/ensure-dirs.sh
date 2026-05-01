#!/bin/bash
source "$(dirname "$0")/lib.sh"
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"

mkdir -p "$BRAIN_DIR/projects"
mkdir -p "$BRAIN_DIR/regressions"
mkdir -p "$KNOWLEDGE_DIR/wiki"/{concepts,decisions,issues,entities,learnings}
exit 0
