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
    # Iterate via while-read with --arg to safely handle event names that
    # contain whitespace or shell metacharacters (a malicious self-PR could
    # insert one). Several lifecycle events ignore matchers per the Claude
    # Code spec — for those, a matcher is not required, and declaring one
    # is misleading (silently ignored at runtime), so we WARN instead.
    NO_MATCHER_EVENTS="UserPromptSubmit Notification SessionEnd Stop PostToolBatch TeammateIdle TaskCreated TaskCompleted WorktreeCreate WorktreeRemove CwdChanged"
    SESSION_START_MATCHERS="startup|resume|clear|compact"

    while IFS= read -r event; do
      event="${event%$'\r'}"  # jq on Windows (Git Bash) emits CRLF — strip the CR
      [ -z "$event" ] && continue
      count=$(jq -r --arg e "$event" '.hooks[$e] | length' "$HOOKS" 2>/dev/null)
      if [ -z "$count" ] || [ "$count" = "null" ]; then
        continue
      fi
      for i in $(seq 0 $((count - 1))); do
        case " $NO_MATCHER_EVENTS " in
          *" $event "*)
            # Matcher optional — but warn if present, since it's a no-op
            if jq -e --arg e "$event" --argjson i "$i" '.hooks[$e][$i].matcher' "$HOOKS" >/dev/null 2>&1; then
              echo "WARN: hooks.json $event[$i] declares a 'matcher' but $event ignores matchers — remove it"
            fi
            ;;
          *)
            if ! jq -e --arg e "$event" --argjson i "$i" '.hooks[$e][$i].matcher' "$HOOKS" >/dev/null 2>&1; then
              echo "FAIL: hooks.json $event[$i] missing 'matcher'"
              ERRORS=$((ERRORS + 1))
            elif [ "$event" = "SessionStart" ]; then
              matcher=$(jq -r --arg e "$event" --argjson i "$i" '.hooks[$e][$i].matcher // ""' "$HOOKS" 2>/dev/null)
              if [ -n "$matcher" ] && ! echo "$matcher" | grep -Eq "^($SESSION_START_MATCHERS)(\|($SESSION_START_MATCHERS))*$"; then
                echo "WARN: hooks.json SessionStart[$i] matcher '$matcher' is not in the documented set ($SESSION_START_MATCHERS)"
              fi
            fi
            ;;
        esac

        if ! jq -e --arg e "$event" --argjson i "$i" '.hooks[$e][$i].hooks | length > 0' "$HOOKS" >/dev/null 2>&1; then
          echo "FAIL: hooks.json $event[$i] has empty 'hooks' array"
          ERRORS=$((ERRORS + 1))
          continue
        fi

        hcount=$(jq -r --arg e "$event" --argjson i "$i" '.hooks[$e][$i].hooks | length' "$HOOKS" 2>/dev/null)
        for j in $(seq 0 $((hcount - 1))); do
          if ! jq -e --arg e "$event" --argjson i "$i" --argjson j "$j" '.hooks[$e][$i].hooks[$j].command' "$HOOKS" >/dev/null 2>&1; then
            echo "FAIL: hooks.json $event[$i].hooks[$j] missing 'command'"
            ERRORS=$((ERRORS + 1))
          fi
        done
      done
    done < <(jq -r '.hooks | keys[]' "$HOOKS" 2>/dev/null)
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

# Verify runtime-referenced files exist. These are not skills or agents but are
# loaded by other scripts/skills at runtime; if they go missing, parts of the
# plugin break silently.
for ref in \
  "scripts/improve-protocol.md" \
  "skills/improve/signal-patterns.md" \
  "mcp/.mcp.json" \
  "mcp/package.json"; do
  if [ ! -f "$PLUGIN_ROOT/$ref" ]; then
    echo "FAIL: required file missing: $ref"
    ERRORS=$((ERRORS + 1))
  fi
done

# JSON-validate the MCP manifests so a corrupt one is caught here, not at runtime
for json_ref in "mcp/.mcp.json" "mcp/package.json"; do
  if [ -f "$PLUGIN_ROOT/$json_ref" ] && ! jq empty "$PLUGIN_ROOT/$json_ref" 2>/dev/null; then
    echo "FAIL: $json_ref is not valid JSON"
    ERRORS=$((ERRORS + 1))
  fi
done

if [ $ERRORS -eq 0 ]; then
  echo "OK: all plugin files valid"
  exit 0
else
  echo "TOTAL: $ERRORS error(s) found"
  exit 1
fi
