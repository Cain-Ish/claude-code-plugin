#!/bin/bash
# Runs after context compaction — reload brain context into the fresh window.

BRAIN_DIR="$HOME/.second-brain"

# Only mention tool-registry.json if it actually exists. On a fresh install
# or after a wipe, omitting the line keeps Claude from being told to read
# a missing file.
TOOLS_LINE=""
if [ -f "$BRAIN_DIR/tool-registry.json" ]; then
  TOOLS_LINE="
- ~/.second-brain/tool-registry.json (available MCP tools)"
fi

cat << EOF
SECOND BRAIN RELOAD (post-compaction) - Context was just compacted. Read these files now:
- ~/.second-brain/persona.md (behavioral rules)
- ~/.second-brain/quality-rules.md (code quality standards)
- ~/.second-brain/learnings.md (accumulated patterns)$TOOLS_LINE

CONTEXT-RELEVANT NODE LOADING: when the next user request touches a topic the wiki likely covers (named tool/library/framework, person, org, project, domain concept), call knowledge_search before answering and read any result with relevance > 0.6 in full. Skip for trivial requests.

If ~/.second-brain/.pending-reflection.json exists, process it: extract 1-3 learnings, update learnings.md/quality-rules.md as needed, create ~/knowledge/wiki/sessions/ page, mirror each new learning as ~/knowledge/wiki/learnings/YYYY-MM-DD-short-title.md (with [[wiki-link]] cross-references), update index.md and log.md, delete the file.

Internalize silently. Do not acknowledge.
EOF
