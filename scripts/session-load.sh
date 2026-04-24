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

  # Check if plugin self-improvement was suggested AND enabled in config
  SUGGEST=$(jq -r '.suggest_plugin_improve // false' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  AUTO_IMPROVE=$(jq -r '.auto_improve // false' "$HOME/.second-brain/config.json" 2>/dev/null)
  if [ "$SUGGEST" = "true" ] && [ "$AUTO_IMPROVE" = "true" ]; then
    PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
    cat << IMPROVE

PLUGIN SELF-IMPROVEMENT TRIGGERED — After processing the reflection and responding to the user, run this in the background (subagent_type: "general-purpose"):

1. Read ~/.second-brain/learnings.md, ~/.second-brain/quality-rules.md, ~/.second-brain/friction-log.jsonl
2. Read all skill files under $PLUGIN_ROOT/skills/*/SKILL.md and $PLUGIN_ROOT/skills/improve/signal-patterns.md
3. Identify if any friction signals or learnings point to improvements in the plugin source code
4. If a candidate improvement is found, write a structured proposal to ~/.second-brain/.improve-proposal.json:
   {"title": "...", "description": "...", "evidence": [{"type": "friction|learning", "timestamp": "exact timestamp from friction-log or date from learnings.md", "session_id": "...", "signal": "actual quoted text"}], "changes": [{"file": "$PLUGIN_ROOT/path", "action": "modify|add", "description": "..."}], "measurable_impact": "...", "risk_assessment": "..."}
   Evidence rules: MUST cite 2+ real entries with actual timestamps. "Could happen" is not evidence.
   If you cannot find 2+ real citations, STOP — write today's date to ~/.second-brain/.last-plugin-improve and skip.
5. Validate the proposal: bash $PLUGIN_ROOT/scripts/validate-proposal.sh
   This checks: evidence exists, 2+ entries prove recurrence, targets are inside plugin root, no version changes.
   If validation fails, do NOT proceed — write today's date and skip.
6. Only after proposal passes: make the changes, then validate the plugin: bash $PLUGIN_ROOT/scripts/validate-plugin.sh
7. If plugin validation passes, create PR:
   - cd $PLUGIN_ROOT && git checkout -b improve/\$(date +%Y-%m-%d)-auto
   - git add -A && git commit -m "improve: <short description>"
   - git push -u origin HEAD
   - gh pr create with: evidence entries (quoted from proposal), changes list, measurable impact, risk assessment, both validation results
8. Clean up: rm ~/.second-brain/.improve-proposal.json
9. Write today's date to ~/.second-brain/.last-plugin-improve

Rules: never modify plugin.json version. Never push to main. One PR per improvement. If either validation fails, abandon and skip.
IMPROVE
  fi
fi
