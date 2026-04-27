#!/bin/bash
# Fires after the knowledge-maintainer subagent finishes (SubagentStop hook,
# matcher: knowledge-maintainer). Writes a marker file so subsequent sessions
# can detect that the wiki was bulk-modified and decide whether to reindex.
#
# Stays out of the hot path: no jq, no transcript scan, just a single touch.

# Resolve knowledge dir: $1 → CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR → ~/knowledge.
# Each step rejects an unsubstituted "${user_config.…}" literal (matches the
# pattern used in extract-learnings.sh and ensure-dirs.sh).
KNOWLEDGE_DIR="$1"
case "$KNOWLEDGE_DIR" in
  ""|*'${user_config.'*) KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-}" ;;
esac
case "$KNOWLEDGE_DIR" in
  ""|*'${user_config.'*) KNOWLEDGE_DIR="$HOME/knowledge" ;;
esac
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"

# Be defensive: if the dir doesn't exist (user never ran setup), exit silently.
[ -d "$KNOWLEDGE_DIR" ] || exit 0

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$KNOWLEDGE_DIR/.last-maintainer-run" 2>/dev/null

exit 0
