#!/bin/bash
# Enumerate the names of installed MCP servers at session start.
# Parses Claude Code settings.json files and per-plugin .mcp.json caches and
# writes a server-name index to ~/.second-brain/tool-registry.json. Skills
# read that index and prefer matching servers when present.
#
# Note: this is a server-name index, not a tool-level capability map — it
# does not enumerate the individual tools each server exposes.
# Runs synchronously at SessionStart so session-load.sh can rely on the file.

BRAIN_DIR="$HOME/.second-brain"
REGISTRY="$BRAIN_DIR/tool-registry.json"
TEMP_FILE="$BRAIN_DIR/.tool-registry-tmp.json"

mkdir -p "$BRAIN_DIR"

# Build the registry
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Collect server names from various config files
SERVER_NAMES="[]"

merge_names() {
  local file="$1"
  local names
  names=$(jq -c '[.mcpServers // {} | keys[]] // []' "$file" 2>/dev/null)
  if [ -z "$names" ] || [ "$names" = "null" ] || [ "$names" = "[]" ]; then
    return
  fi
  SERVER_NAMES=$(jq -nc --argjson a "$SERVER_NAMES" --argjson b "$names" '$a + $b | unique' 2>/dev/null || echo "$SERVER_NAMES")
}

for config in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" .claude/settings.json .claude/settings.local.json; do
  [ -f "$config" ] && merge_names "$config"
done

if [ -d "$HOME/.claude/plugins/cache" ]; then
  while IFS= read -r mcp_file; do
    merge_names "$mcp_file"
  done < <(find "$HOME/.claude/plugins/cache" \( -name ".mcp.json" -o -path "*/.claude-plugin/mcp.json" \) -type f 2>/dev/null)
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
