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
3. Apply the IMPROVEMENT FILTER below to each candidate change. Only proceed if at least one passes.
4. If improvements pass the filter:
   a. Make the changes to files under $PLUGIN_ROOT
   b. Validate: bash $PLUGIN_ROOT/scripts/validate-plugin.sh
   c. If validation passes, create a PR:
      - cd $PLUGIN_ROOT
      - git checkout -b improve/\$(date +%Y-%m-%d)-auto
      - git add -A
      - git commit -m "improve: <short description>"
      - git push -u origin HEAD
      - gh pr create with summary, validation status, which filter criteria were met, and source learnings
   d. Write today's date to ~/.second-brain/.last-plugin-improve
5. If nothing passes the filter, just write today's date to ~/.second-brain/.last-plugin-improve and skip

IMPROVEMENT FILTER — every proposed change MUST pass ALL of these:
- FRICTION-DRIVEN: tied to a real friction signal (user correction, retry, tool failure) — not a stylistic preference
- RECURRING: the problem appeared in 2+ sessions or 2+ times in one session — single occurrences are noise
- MEASURABLE: you can state what gets better (fewer friction signals, fewer retries, faster task completion)
- SCOPED: changes one specific behavior — no "while I'm here" cleanup or speculative improvements
- SAFE: cannot break existing working behavior — if unsure, skip it

REJECT changes that are:
- Cosmetic rewording of skill instructions with no behavioral impact
- Adding error handling for scenarios that haven't actually failed
- Restructuring that doesn't fix a concrete problem
- "Best practice" changes not backed by observed friction

Rules: never modify plugin.json version. Never push to main. Keep changes focused. One PR per improvement area.
IMPROVE
  fi
fi
