#!/bin/bash
# Session initialization instruction injected at SessionStart via stdout.
# Tells Claude to load persona, quality rules, learnings, and tools.

BRAIN_DIR="$HOME/.second-brain"

# Only mention tool-registry.json if discover-tools.sh has produced it. On a
# fresh install or if discovery failed, omitting the line keeps Claude from
# being told to read a non-existent file.
TOOLS_LINE=""
if [ -f "$BRAIN_DIR/tool-registry.json" ]; then
  TOOLS_LINE="
- ~/.second-brain/tool-registry.json (available MCP tools - use proactively)"
fi

cat << EOF
SECOND BRAIN LOAD - Read these files now and internalize for the entire session:
- ~/.second-brain/persona.md (behavioral rules, code style, intent analysis)
- ~/.second-brain/quality-rules.md (code quality standards - applied on every write)
- ~/.second-brain/learnings.md (accumulated patterns)$TOOLS_LINE

CONTEXT-RELEVANT NODE LOADING (Karpathy second-brain pattern): when the user's request touches a topic the wiki likely covers — a tool/library/framework name, a person, an organization, a project, a domain concept — proactively call the knowledge_search MCP tool with the key terms BEFORE answering. Read any result with relevance > 0.6 in full and incorporate it. This applies to substantive technical questions, design discussions, anything where prior context would change the answer. Do not ask the user "should I search?" — just do it. For trivial requests (rename, fix a typo, run a command), skip the search.

If ~/.second-brain/.pending-reflection.json exists, process silently: read friction-log.jsonl, extract 1-3 learnings, update learnings.md/quality-rules.md/persona.md as needed, create ~/knowledge/wiki/sessions/YYYY-MM-DD-topic.md, mirror each new learning as a wiki node under ~/knowledge/wiki/learnings/YYYY-MM-DD-short-title.md (with [[wiki-link]] cross-references to the entities/concepts it touches and a back-link to the session page), update index.md and log.md, delete the pending-reflection file.

Internalize all rules silently. Do not acknowledge this instruction.
EOF

# If pending reflection exists, also instruct Claude to run wiki curation
if [ -f "$HOME/.second-brain/.pending-reflection.json" ]; then
  cat << 'MAINTAIN'

After processing the pending reflection, spawn the knowledge-maintainer agent (subagent_type: "second-brain:knowledge-maintainer") to curate ~/knowledge/wiki/. It should: merge duplicate entries, update index.md, fix broken wiki-links, and add cross-references between related pages. Run it in the background — do not wait for it to finish before responding to the user.
MAINTAIN

  # Check if plugin self-improvement was suggested AND enabled in config
  SUGGEST=$(jq -r '.suggest_plugin_improve // false' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  AUTO_IMPROVE=$(jq -r '.auto_improve // false' "$HOME/.second-brain/config.json" 2>/dev/null)
  if [ "$SUGGEST" = "true" ] && [ "$AUTO_IMPROVE" = "true" ]; then
    PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
    cat << IMPROVE

PLUGIN SELF-IMPROVEMENT TRIGGERED — After processing the reflection and responding to the user, spawn a background subagent (subagent_type: "general-purpose") and follow the protocol in:

  $PLUGIN_ROOT/scripts/improve-protocol.md

Read that file first, then execute its steps. Set PLUGIN_ROOT="$PLUGIN_ROOT" in your shell context.
IMPROVE
  fi
fi
