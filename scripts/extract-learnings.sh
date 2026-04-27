#!/bin/bash
# Extract session data and create a pending reflection request.
# Runs at session Stop — doesn't block the user.
# The actual reflection (LLM analysis) happens at next SessionStart.

source "$(dirname "$0")/lib.sh"

# Resolve knowledge dir: $1 → CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR → ~/knowledge
KNOWLEDGE_DIR="$1"
case "$KNOWLEDGE_DIR" in
  ""|*'${user_config.'*) KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-}" ;;
esac
case "$KNOWLEDGE_DIR" in
  ""|*'${user_config.'*) KNOWLEDGE_DIR="$HOME/knowledge" ;;
esac
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"

sb_collect_session_data 3 || exit 0

sb_write_session_meta
sb_write_reflection "stop"

exit 0
