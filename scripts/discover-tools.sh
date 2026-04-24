#!/bin/bash
# Discover available MCP tools and other plugins at session start.
# Parses Claude Code configuration to build a tool registry.
# Runs async at SessionStart — doesn't block the session.

COMPANION_DIR="$HOME/.claude-companion"
REGISTRY="$COMPANION_DIR/tool-registry.json"
TEMP_FILE="$COMPANION_DIR/.tool-registry-tmp.json"

mkdir -p "$COMPANION_DIR"

# Build the registry
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Collect server names from various config files
SERVER_NAMES="[]"

for config in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" .claude/settings.json .claude/settings.local.json; do
  if [ -f "$config" ]; then
    names=$(jq -r '[.mcpServers // {} | keys[]] // []' "$config" 2>/dev/null)
    if [ "$names" != "null" ] && [ "$names" != "[]" ]; then
      SERVER_NAMES=$(echo "$SERVER_NAMES $names" | jq -s '.[0] + .[1] | unique' 2>/dev/null || echo "$SERVER_NAMES")
    fi
  fi
done

# Also check plugin MCP files
if [ -d "$HOME/.claude/plugins/cache" ]; then
  while IFS= read -r mcp_file; do
    names=$(jq -r '[.mcpServers // {} | keys[]] // []' "$mcp_file" 2>/dev/null)
    if [ "$names" != "null" ] && [ "$names" != "[]" ]; then
      SERVER_NAMES=$(echo "$SERVER_NAMES $names" | jq -s '.[0] + .[1] | unique' 2>/dev/null || echo "$SERVER_NAMES")
    fi
  done < <(find "$HOME/.claude/plugins/cache" -name ".mcp.json" -type f 2>/dev/null)
fi

# Build final registry
cat > "$TEMP_FILE" << JSONEOF
{
  "discovered_at": "$TIMESTAMP",
  "mcp_servers": $SERVER_NAMES,
  "note": "This file is auto-generated at session start. Skills should read this to discover available tools and adapt behavior accordingly."
}
JSONEOF

# Atomic write
mv "$TEMP_FILE" "$REGISTRY" 2>/dev/null || cp "$TEMP_FILE" "$REGISTRY"
rm -f "$TEMP_FILE"

exit 0
