# Bash side of the KB single source of truth. Reads the repo-root kb-schema.json (the SAME file
# the TS MCP server inlines via mcp/src/constants/kb-schema.ts) and exports SB_* category lists as
# space-separated strings. Sourced by lib.sh; any script needing a category list uses these vars
# instead of hardcoding one. Requires jq (a plugin hard-dep). Fail-soft: if jq or the manifest is
# absent (or the single parse fails) the vars stay unset/empty and the (rare) consumer loop no-ops —
# NO hardcoded fallback that could drift from the manifest. Guarded by tests/test-kb-schema.sh
# (TS ↔ bash ↔ json must agree).
#
# ONE jq spawn, not ten (0.33.38 hot-path audit): lib.sh sources this file unconditionally, so at
# ~33ms/spawn on Windows the old per-field form taxed EVERY hook ~330ms before it did anything.
# Line-per-field -r protocol (not @tsv — values are single-line by construction, and @tsv's
# backslash escaping would corrupt nothing here but the line protocol needs no unescaping at all).
_SB_KB_SCHEMA="${SB_KB_SCHEMA:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/kb-schema.json}"
if command -v jq >/dev/null 2>&1 && [ -f "$_SB_KB_SCHEMA" ]; then
  {
    IFS= read -r SB_STRUCTURED_TYPES
    IFS= read -r SB_UNSTRUCTURED_TYPES
    IFS= read -r SB_GENERATED_DIRS
    IFS= read -r SB_CONTENT_CATEGORIES
    IFS= read -r SB_ALL_CATEGORIES
    IFS= read -r SB_EDGE_TYPES
    IFS= read -r SB_FORGET_PROTECTED
    IFS= read -r SB_FORGET_DISCOUNTED
    IFS= read -r SB_RAW_DIR
    IFS= read -r SB_RAW_STATUSES
  } < <(jq -r '
      (.structured_types | join(" ")),
      (.unstructured_types | join(" ")),
      (.generated_dirs | join(" ")),
      ((.structured_types + .unstructured_types) | join(" ")),
      ((.structured_types + .unstructured_types + .generated_dirs) | join(" ")),
      (.edge_types | join(" ")),
      (.forget_protection.protected | join(" ")),
      (.forget_protection.discounted | join(" ")),
      .raw.dir,
      (.raw.statuses | join(" "))
    ' "$_SB_KB_SCHEMA" 2>/dev/null | tr -d '\r')
  export SB_STRUCTURED_TYPES SB_UNSTRUCTURED_TYPES SB_GENERATED_DIRS SB_CONTENT_CATEGORIES \
         SB_ALL_CATEGORIES SB_EDGE_TYPES SB_FORGET_PROTECTED SB_FORGET_DISCOUNTED \
         SB_RAW_DIR SB_RAW_STATUSES
fi
