#!/bin/bash
# Runs after context compaction — reload brain context into the fresh window.
cat << 'EOF'
SECOND BRAIN RELOAD (post-compaction) - Context was just compacted. Read these files now:
- ~/.second-brain/persona.md (behavioral rules)
- ~/.second-brain/quality-rules.md (code quality standards)
- ~/.second-brain/learnings.md (accumulated patterns)
- ~/.second-brain/tool-registry.json (available MCP tools)

If ~/.second-brain/.pending-reflection.json exists, process it: extract 1-3 learnings, update learnings.md/quality-rules.md as needed, create ~/knowledge/wiki/sessions/ page, delete the file.

Internalize silently. Do not acknowledge.
EOF
