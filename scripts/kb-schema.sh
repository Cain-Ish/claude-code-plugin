# Bash side of the KB single source of truth. Reads the repo-root kb-schema.json (the SAME file
# the TS MCP server inlines via mcp/src/constants/kb-schema.ts) and exports SB_* category lists as
# space-separated strings. Sourced by lib.sh; any script needing a category list uses these vars
# instead of hardcoding one. Requires jq (a plugin hard-dep). Fail-soft: if jq or the manifest is
# absent the vars stay unset and the (rare) consumer loop no-ops — NO hardcoded fallback that could
# drift from the manifest. Guarded by tests/test-kb-schema.sh (TS ↔ bash ↔ json must agree).
_SB_KB_SCHEMA="${SB_KB_SCHEMA:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/kb-schema.json}"
if command -v jq >/dev/null 2>&1 && [ -f "$_SB_KB_SCHEMA" ]; then
  SB_STRUCTURED_TYPES=$(jq -r '.structured_types | join(" ")' "$_SB_KB_SCHEMA" 2>/dev/null)
  SB_UNSTRUCTURED_TYPES=$(jq -r '.unstructured_types | join(" ")' "$_SB_KB_SCHEMA" 2>/dev/null)
  SB_GENERATED_DIRS=$(jq -r '.generated_dirs | join(" ")' "$_SB_KB_SCHEMA" 2>/dev/null)
  SB_CONTENT_CATEGORIES=$(jq -r '(.structured_types + .unstructured_types) | join(" ")' "$_SB_KB_SCHEMA" 2>/dev/null)
  SB_ALL_CATEGORIES=$(jq -r '(.structured_types + .unstructured_types + .generated_dirs) | join(" ")' "$_SB_KB_SCHEMA" 2>/dev/null)
  SB_EDGE_TYPES=$(jq -r '.edge_types | join(" ")' "$_SB_KB_SCHEMA" 2>/dev/null)
  SB_FORGET_PROTECTED=$(jq -r '.forget_protection.protected | join(" ")' "$_SB_KB_SCHEMA" 2>/dev/null)
  SB_FORGET_DISCOUNTED=$(jq -r '.forget_protection.discounted | join(" ")' "$_SB_KB_SCHEMA" 2>/dev/null)
  SB_RAW_DIR=$(jq -r '.raw.dir' "$_SB_KB_SCHEMA" 2>/dev/null)
  SB_RAW_STATUSES=$(jq -r '.raw.statuses | join(" ")' "$_SB_KB_SCHEMA" 2>/dev/null)
  export SB_STRUCTURED_TYPES SB_UNSTRUCTURED_TYPES SB_GENERATED_DIRS SB_CONTENT_CATEGORIES \
         SB_ALL_CATEGORIES SB_EDGE_TYPES SB_FORGET_PROTECTED SB_FORGET_DISCOUNTED \
         SB_RAW_DIR SB_RAW_STATUSES
fi
