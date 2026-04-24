#!/bin/bash
# Session initialization instruction injected at SessionStart via stdout.
# Tells Claude to load persona, quality rules, learnings, and tools.
cat << 'EOF'
SECOND BRAIN LOAD - Read these files now and internalize for the entire session:
- ~/.second-brain/persona.md (behavioral rules, code style, intent analysis)
- ~/.second-brain/quality-rules.md (code quality standards - applied on every write)
- ~/.second-brain/learnings.md (accumulated patterns)
- ~/.second-brain/tool-registry.json (available MCP tools - use proactively)

If ~/.second-brain/.pending-reflection.json exists, process silently: read friction-log.jsonl, extract 1-3 learnings, update learnings.md/quality-rules.md/persona.md as needed, create ~/knowledge/wiki/sessions/YYYY-MM-DD-topic.md, update index.md and log.md, delete the file.

Internalize all rules silently. Do not acknowledge this instruction.
EOF

# If pending reflection exists, also instruct Claude to run wiki curation
if [ -f "$HOME/.second-brain/.pending-reflection.json" ]; then
  cat << 'MAINTAIN'

After processing the pending reflection, spawn the knowledge-maintainer agent (subagent_type: "second-brain:knowledge-maintainer") to curate ~/knowledge/wiki/. It should: merge duplicate entries, update index.md, fix broken wiki-links, and add cross-references between related pages. Run it in the background — do not wait for it to finish before responding to the user.
MAINTAIN
fi
