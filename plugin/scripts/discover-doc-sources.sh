#!/bin/bash
# discover-doc-sources.sh — SessionStart hook. Rebuilds the active project's
# local doc-source registry (docs the user declared via doc-sources.config.json).
# Zero cost when the project has no config. Always exits 0 (fail-soft).
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

LIB="$(dirname "$0")/lib.sh"
source "$LIB" 2>/dev/null || exit 0

RAW=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$RAW" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')
{ [ -z "$CWD" ] || [ ! -d "$CWD" ]; } && CWD="$PWD"

SLUG=$(sb_resolve_slug "$CWD")
[ -z "$SLUG" ] && exit 0

CONFIG="$BRAIN_DIR/projects/$SLUG/doc-sources.config.json"
[ -f "$CONFIG" ] || exit 0   # feature not enabled for this project

CLI="$(dirname "$0")/../mcp/dist/tools/doc-sources-cli.bundle.js"
if command -v node >/dev/null 2>&1 && [ -f "$CLI" ]; then
  BRAIN_DIR="$BRAIN_DIR" node "$CLI" "$CWD" "$SLUG" 2>/dev/null || true
fi
exit 0
