#!/bin/bash
# Guard: discover-tools.sh must enumerate MCP servers from BOTH plugin layouts —
# a legacy root .mcp.json AND a relocated .claude-plugin/mcp.json (the structure
# adopted in 0.24.35 so the manifest isn't double-read as a project config).
#
# Regression this guards: if the cache scan only matches `-name ".mcp.json"`, the
# second-brain knowledge-base server (now at .claude-plugin/mcp.json) silently
# drops out of ~/.second-brain/tool-registry.json and skills stop preferring it.
#
# Fully isolated: HOME is redirected to a temp dir, so the real ~/.second-brain
# and the real plugin cache are never touched.
# Usage: bash tests/test-discover-tools-mcp-scan.sh

set -u

for cmd in jq mktemp bash find; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "test prerequisite missing: $cmd"; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/discover-tools.sh"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/sb-discover-tools.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0

assert_registry_has() {
  local name="$1" registry="$2"
  if jq -e --arg n "$name" '.mcp_servers | index($n)' "$registry" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  PASS  registry includes: $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  registry missing: $name"
    sed 's/^/        /' "$registry"
  fi
}

echo "test-discover-tools-mcp-scan.sh"
echo "-------------------------------"

# Synthetic isolated cache: a legacy-layout plugin and a relocated-layout plugin.
CACHE="$SANDBOX/.claude/plugins/cache"
mkdir -p "$CACHE/legacy-plugin" "$CACHE/relocated-plugin/.claude-plugin"
printf '%s' '{"mcpServers":{"legacy-server":{"type":"stdio","command":"node"}}}' \
  > "$CACHE/legacy-plugin/.mcp.json"
printf '%s' '{"mcpServers":{"relocated-server":{"type":"stdio","command":"node"}}}' \
  > "$CACHE/relocated-plugin/.claude-plugin/mcp.json"

# Run with HOME isolated so discover-tools writes to $SANDBOX/.second-brain.
HOME="$SANDBOX" bash "$SCRIPT" >/dev/null 2>&1

REGISTRY="$SANDBOX/.second-brain/tool-registry.json"
if [ ! -f "$REGISTRY" ]; then
  echo "  FAIL  registry not produced at $REGISTRY"
  echo "-------------------------------"; echo "PASS: $PASS, FAIL: $((FAIL + 1))"; exit 1
fi

assert_registry_has "legacy-server" "$REGISTRY"
assert_registry_has "relocated-server" "$REGISTRY"

echo "-------------------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
