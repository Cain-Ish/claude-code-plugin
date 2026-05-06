#!/bin/bash
# v1.0 hot-tier loader. Outputs USER.md + active PROJECT.md + active index line.
# Captures SessionStart baseline for Stop-hook predicate.
source "$(dirname "$0")/lib.sh"

USER_FILE="$BRAIN_DIR/USER.md"
INDEX_FILE="$BRAIN_DIR/projects.jsonl"
PROJECTS_DIR="$BRAIN_DIR/projects"
LINE_CAP=66   # ~800 tokens / 12 tokens-per-line

slug=$(basename "$PWD")
project_file="$PROJECTS_DIR/$slug/PROJECT.md"

if [ ! -f "$project_file" ]; then
  mkdir -p "$(dirname "$project_file")"
  cat > "$project_file" <<TMPL
# PROJECT: $slug

## Goal
(auto-scaffolded — describe this project's goal)

## State

## Conventions

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ) -->
<!-- last_queried_wiki: -->
TMPL
  if [ -f "$INDEX_FILE" ] && ! grep -q "\"slug\":\"$slug\"" "$INDEX_FILE" 2>/dev/null; then
    jq -nc --arg s "$slug" --arg n "$slug" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}' >> "$INDEX_FILE"
  fi
fi

cp "$project_file" "$BRAIN_DIR/.session-baseline-$slug.md"

[ -f "$USER_FILE" ] && cat "$USER_FILE"
if [ -f "$project_file" ]; then echo; cat "$project_file"; fi
if [ -f "$INDEX_FILE" ]; then
  echo
  jq --arg s "$slug" -r 'select(.slug == $s)' "$INDEX_FILE" 2>/dev/null | head -1
fi

# Approximate hot-tier size: USER.md + PROJECT.md.
TOTAL_LINES=$(( $(wc -l < "$USER_FILE" 2>/dev/null || echo 0) + $(wc -l < "$project_file" 2>/dev/null || echo 0) ))
if [ "$TOTAL_LINES" -gt "$LINE_CAP" ]; then
  sb_log_error "session-load.sh" "hot-tier exceeded line cap: $TOTAL_LINES > $LINE_CAP" 0
fi

# Update last_session_iso for this project
if [ -f "$INDEX_FILE" ] && command -v jq >/dev/null 2>&1; then
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  TMP_IDX=$(mktemp)
  jq --arg s "$slug" --arg t "$TS" '
    if .slug == $s then .last_session_iso = $t else . end
  ' "$INDEX_FILE" > "$TMP_IDX" 2>/dev/null && mv "$TMP_IDX" "$INDEX_FILE" || rm -f "$TMP_IDX"
fi

exit 0
