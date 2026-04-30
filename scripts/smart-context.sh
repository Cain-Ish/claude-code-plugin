#!/bin/bash
# Per-prompt lightweight context injection.
# Reads UserPromptSubmit hook input, extracts keywords, greps index.md.
# Opt-in via ~/.second-brain/config.json {"smart_context": true}

BRAIN_DIR="$HOME/.second-brain"

# Suppress under context pressure
COMPACT_COUNT=$(cat "$BRAIN_DIR/.compact-count" 2>/dev/null || echo 0)
[ "$COMPACT_COUNT" -ge 3 ] && exit 0

ENABLED=$(jq -r '.smart_context // false' "$BRAIN_DIR/config.json" 2>/dev/null)
[ "$ENABLED" = "true" ] || exit 0

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // .prompt // ""' 2>/dev/null)
[ -z "$PROMPT" ] && exit 0

KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
INDEX="$KNOWLEDGE_DIR/index.md"
[ -f "$INDEX" ] || exit 0

KEYWORDS=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z]{5,}' | awk '{print length, $0}' | sort -rn | head -3 | awk '{print $2}')
[ -z "$KEYWORDS" ] && exit 0

MATCHES=""
for kw in $KEYWORDS; do
  MATCH=$(grep -i "$kw" "$INDEX" 2>/dev/null | grep -oE '\[[^]]+\]\([^)]+\.md\)' | head -2)
  if [ -n "$MATCH" ]; then
    [ -n "$MATCHES" ] && MATCHES="$MATCHES
$MATCH" || MATCHES="$MATCH"
  fi
done

# File-aware: extract file paths/names from prompt, grep patterns/issues/decisions dirs
FILE_NAMES=$(echo "$PROMPT" | grep -oE '[a-zA-Z0-9_-]+\.(ts|tsx|js|jsx|py|sh|md)' | sort -u | head -3)
if [ -n "$FILE_NAMES" ]; then
  WIKI_DIR="$KNOWLEDGE_DIR/wiki"
  for fname in $FILE_NAMES; do
    base="${fname%.*}"
    for subdir in patterns issues decisions; do
      [ -d "$WIKI_DIR/$subdir" ] || continue
      FM=$(grep -rFl -e "$base" -e "$fname" "$WIKI_DIR/$subdir/" 2>/dev/null | head -1)
      if [ -n "$FM" ]; then
        REL="${FM#"$KNOWLEDGE_DIR"/}"
        TITLE=$(grep -m1 '^# ' "$FM" 2>/dev/null | sed 's/^# //')
        [ -n "$MATCHES" ] && MATCHES="$MATCHES
[$TITLE]($REL)" || MATCHES="[$TITLE]($REL)"
      fi
    done
  done
fi

UNIQUE=$(echo "$MATCHES" | sort -u | head -5 | tr '\n' ', ' | sed 's/,$//')
[ -z "$UNIQUE" ] && exit 0

echo "Relevant wiki: $UNIQUE"
