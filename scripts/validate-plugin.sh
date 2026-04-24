#!/bin/bash
# Validate plugin files after modifications.
# Exit 0 = all valid, exit 1 = errors found.
# Outputs issues to stdout for the caller to read.

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ERRORS=0

# Validate hooks.json
HOOKS="$PLUGIN_ROOT/hooks/hooks.json"
if [ -f "$HOOKS" ]; then
  if ! jq empty "$HOOKS" 2>/dev/null; then
    echo "FAIL: hooks.json is not valid JSON"
    ERRORS=$((ERRORS + 1))
  else
    for event in $(jq -r '.hooks | keys[]' "$HOOKS" 2>/dev/null); do
      count=$(jq -r ".hooks.\"$event\" | length" "$HOOKS" 2>/dev/null)
      for i in $(seq 0 $((count - 1))); do
        if ! jq -e ".hooks.\"$event\"[$i].matcher" "$HOOKS" >/dev/null 2>&1; then
          echo "FAIL: hooks.json $event[$i] missing 'matcher'"
          ERRORS=$((ERRORS + 1))
        fi
        if ! jq -e ".hooks.\"$event\"[$i].hooks | length > 0" "$HOOKS" >/dev/null 2>&1; then
          echo "FAIL: hooks.json $event[$i] has empty 'hooks' array"
          ERRORS=$((ERRORS + 1))
        fi
        for j in $(seq 0 $(($(jq -r ".hooks.\"$event\"[$i].hooks | length" "$HOOKS" 2>/dev/null) - 1))); do
          if ! jq -e ".hooks.\"$event\"[$i].hooks[$j].command" "$HOOKS" >/dev/null 2>&1; then
            echo "FAIL: hooks.json $event[$i].hooks[$j] missing 'command'"
            ERRORS=$((ERRORS + 1))
          fi
        done
      done
    done
  fi
fi

# Validate plugin.json
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
if [ -f "$PLUGIN_JSON" ]; then
  if ! jq empty "$PLUGIN_JSON" 2>/dev/null; then
    echo "FAIL: plugin.json is not valid JSON"
    ERRORS=$((ERRORS + 1))
  fi
fi

# Validate all shell scripts
while IFS= read -r script; do
  if ! bash -n "$script" 2>/dev/null; then
    echo "FAIL: $script has syntax errors"
    ERRORS=$((ERRORS + 1))
  fi
done < <(find "$PLUGIN_ROOT/scripts" -name "*.sh" -type f 2>/dev/null)

# Validate all SKILL.md frontmatter
while IFS= read -r skill_file; do
  if head -1 "$skill_file" | grep -q "^---"; then
    frontmatter=$(sed -n '/^---$/,/^---$/p' "$skill_file" | sed '1d;$d')

    for field in name description; do
      if ! echo "$frontmatter" | grep -q "^$field:"; then
        echo "FAIL: $(basename "$(dirname "$skill_file")")/SKILL.md missing '$field' in frontmatter"
        ERRORS=$((ERRORS + 1))
      fi
    done
  else
    echo "FAIL: $(basename "$(dirname "$skill_file")")/SKILL.md missing YAML frontmatter"
    ERRORS=$((ERRORS + 1))
  fi
done < <(find "$PLUGIN_ROOT/skills" -name "SKILL.md" -type f 2>/dev/null)

# Validate agent definitions
while IFS= read -r agent_file; do
  if head -1 "$agent_file" | grep -q "^---"; then
    frontmatter=$(sed -n '/^---$/,/^---$/p' "$agent_file" | sed '1d;$d')
    if ! echo "$frontmatter" | grep -q "^name:"; then
      echo "FAIL: $(basename "$agent_file") missing 'name' in frontmatter"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done < <(find "$PLUGIN_ROOT/agents" -name "*.md" -type f 2>/dev/null)

if [ $ERRORS -eq 0 ]; then
  echo "OK: all plugin files valid"
  exit 0
else
  echo "TOTAL: $ERRORS error(s) found"
  exit 1
fi
