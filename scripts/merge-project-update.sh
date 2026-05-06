#!/bin/bash
# Idempotent merge of a JSON delta into PROJECT.md + wiki pages. Used by
# the v1.2.0+ Stop-hook auto-archival flow (scripts/stop-extract.sh).
#
# Usage:
#   bash merge-project-update.sh --project-md <path> --wiki-dir <dir> [--knowledge-dir <dir>] [--json-file <path>]
#   # or pipe JSON on stdin
#
# JSON schema (all keys optional, default to []):
#   {
#     "recent_decisions": ["<text>", ...],   # cap 3 bullets in PROJECT.md
#     "open_blockers":    ["<text>", ...],   # cap 15
#     "cross_refs":       ["<slug>", ...],   # cap 3 bullets, scaffolds wiki/<slug>.md if missing
#     "files_touched":    ["<path>", ...],   # informational
#     "wiki_updates":     [{"category","slug","action","title","description","content"}, ...]
#   }
#
# Behavior:
#   - Empty deltas → no-op (PROJECT.md unchanged, no timestamp bump).
#   - Decisions/blockers de-duped by case-insensitive substring match
#     against existing bullets in the same section.
#   - Cross-refs de-duped case-insensitively against existing [[refs]].
#   - When ANY section actually changed, last_updated footer is bumped.
#   - Missing wiki stubs get a 4-line stub with `<!-- auto-extracted -->`
#     marker so /second-brain:lint can prune low-value pages later.
#   - Atomic write: stage to a tempfile, mv into place.
#   - Invalid JSON on stdin → exit non-zero with PROJECT.md untouched.
set -u

PROJECT_MD=""
WIKI_DIR=""
JSON_FILE=""
KNOWLEDGE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project-md)    PROJECT_MD="$2";    shift 2 ;;
    --wiki-dir)      WIKI_DIR="$2";      shift 2 ;;
    --knowledge-dir) KNOWLEDGE_DIR="$2"; shift 2 ;;
    --json-file)     JSON_FILE="$2";     shift 2 ;;
    *) echo "merge-project-update: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT_MD" ] || { echo "merge-project-update: --project-md is required" >&2; exit 2; }
[ -n "$WIKI_DIR" ]   || { echo "merge-project-update: --wiki-dir is required" >&2; exit 2; }
[ -z "$KNOWLEDGE_DIR" ] && KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
KNOWLEDGE_WIKI="$KNOWLEDGE_DIR/wiki"
[ -f "$PROJECT_MD" ] || { echo "merge-project-update: project file not found: $PROJECT_MD" >&2; exit 2; }
mkdir -p "$WIKI_DIR"

if [ -n "$JSON_FILE" ]; then
  RAW=$(cat "$JSON_FILE")
else
  RAW=$(cat)
fi

if ! echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "merge-project-update: input is not a JSON object" >&2
  exit 1
fi

# Strip CR from every line — Windows / Git-Bash jq pipelines can leak \r
# into values, which silently breaks all our string comparisons below.
strip_cr() { tr -d '\r'; }
DECISIONS=$(echo "$RAW" | jq -r '.recent_decisions // [] | .[]?' 2>/dev/null | strip_cr)
BLOCKERS=$(echo  "$RAW" | jq -r '.open_blockers   // [] | .[]?' 2>/dev/null | strip_cr)
REFS=$(echo      "$RAW" | jq -r '.cross_refs      // [] | .[]?' 2>/dev/null | strip_cr)

CHANGED=0

TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT
cp "$PROJECT_MD" "$TMP_OUT"

# Archive a dropped decision bullet to the wiki decisions log.
archive_dropped_decision() {
  local text="$1"
  text=$(echo "$text" | sed 's/^- //')
  [ -z "$text" ] && return 0
  local archive_file="$KNOWLEDGE_WIKI/decisions/project-decisions-log.md"
  mkdir -p "$(dirname "$archive_file")"
  if [ ! -f "$archive_file" ]; then
    local ts_now
    ts_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$archive_file" <<STUB
---
title: "Archived Project Decisions"
type: decisions
description: "Auto-archived decisions rotated out of PROJECT.md hot tier"
created: $ts_now
updated: $ts_now
---

# Archived Project Decisions

STUB
  fi
  printf '%s\n' "- $text" >> "$archive_file"
  WIKI_WRITES=1
}

# Insert a bullet under "## <section>", dedupe case-insensitively, cap N.
# Drops the oldest (top-most) bullet when cap is reached. For decisions,
# dropped bullets are archived to wiki instead of discarded.
insert_bullet() {
  local section="$1" bullet_text="$2" cap="$3"
  [ -z "$bullet_text" ] && return 0

  local lower_new
  # Strip date prefix and common markers for dedup comparison
  lower_new=$(printf '%s' "$bullet_text" | sed 's/^\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\] //' | sed 's/^\[active\] //;s/^\[resolved\] //;s/^\[stale\] //;s/^\[decision\] //;s/^\[pinned\] //' | tr '[:upper:]' '[:lower:]')
  local existing_lower
  existing_lower=$(awk -v s="$section" '
    $0 == s { flag=1; next }
    /^## / { flag=0 }
    flag && /^- / { gsub(/^- (\[[0-9]{4}-[0-9]{2}-[0-9]{2}\] )?(\[(active|resolved|stale|decision|pinned)\] )?/, "- "); print tolower($0) }
  ' "$TMP_OUT")
  if echo "$existing_lower" | grep -qF -- "$lower_new"; then
    return 0
  fi

  local count
  count=$(awk -v s="$section" '
    $0 == s { flag=1; next }
    /^## / { flag=0 }
    flag && /^- / { c++ }
    END { print c+0 }
  ' "$TMP_OUT")

  local new_tmp
  new_tmp=$(mktemp)
  if [ "$count" -ge "$cap" ]; then
    # Capture the oldest bullet before dropping it
    if [ "$section" = "## Recent decisions" ]; then
      local oldest
      oldest=$(awk -v s="$section" '
        $0 == s { flag=1; next }
        /^## / { flag=0 }
        flag && /^- / { print; exit }
      ' "$TMP_OUT")
      [ -n "$oldest" ] && archive_dropped_decision "$oldest"
    fi
    awk -v s="$section" -v new="- $bullet_text" '
      BEGIN { flag=0; dropped=0; appended=0 }
      $0 == s { print; flag=1; next }
      flag && /^## / {
        if (!appended) { print new; appended=1 }
        flag=0; print; next
      }
      flag && !appended && !/^- / && !/^$/ {
        print new; appended=1; flag=0; print; next
      }
      flag && /^- / && !dropped { dropped=1; next }
      { print }
      END {
        if (flag && !appended) { print new }
      }
    ' "$TMP_OUT" > "$new_tmp"
  else
    awk -v s="$section" -v new="- $bullet_text" '
      BEGIN { flag=0; appended=0 }
      $0 == s { print; flag=1; next }
      flag && /^## / {
        if (!appended) { print new; appended=1 }
        flag=0; print; next
      }
      flag && !appended && !/^- / && !/^$/ {
        print new; appended=1; flag=0; print; next
      }
      { print }
      END {
        if (flag && !appended) { print new }
      }
    ' "$TMP_OUT" > "$new_tmp"
  fi
  mv "$new_tmp" "$TMP_OUT"
  CHANGED=1
}

TODAY=$(date +%Y-%m-%d)
if [ -n "$DECISIONS" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Skip "files this session" fallback lines — they're not decisions
    echo "$line" | grep -q '^files this session:' && continue
    # Prefix with date if not already dated
    if echo "$line" | grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}\]'; then
      insert_bullet "## Recent decisions" "$line" 5
    else
      insert_bullet "## Recent decisions" "[$TODAY] $line" 5
    fi
  done <<< "$DECISIONS"
fi

if [ -n "$BLOCKERS" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    insert_bullet "## Open blockers" "$line" 15
  done <<< "$BLOCKERS"
fi

if [ -n "$REFS" ]; then
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    lower_ref=$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')
    existing=$(awk '
      /^## Cross-references$/ { flag=1; next }
      /^## / { flag=0 }
      flag && /^- \[\[/ { print tolower($0) }
    ' "$TMP_OUT")
    if ! echo "$existing" | grep -qF -- "[[$lower_ref]]"; then
      insert_bullet "## Cross-references" "[[$ref]]" 3
    fi
    stub="$WIKI_DIR/$ref.md"
    if [ ! -f "$stub" ]; then
      ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      {
        printf '# %s\n\n' "$ref"
        printf '<!-- auto-extracted: %s -->\n\n' "$ts"
        printf '## Notes\n\nTODO: expand.\n'
      } > "$stub"
      CHANGED=1
    fi
  done <<< "$REFS"
fi

WIKI_WRITES=0
WIKI_UPDATES_COUNT=$(echo "$RAW" | jq '.wiki_updates // [] | length' 2>/dev/null || echo 0)
if [ "$WIKI_UPDATES_COUNT" -gt 0 ]; then
  mkdir -p "$KNOWLEDGE_WIKI"
  echo "$RAW" | jq -c '.wiki_updates // [] | .[]' 2>/dev/null | while IFS= read -r update; do
    category=$(echo "$update" | jq -r '.category // "concepts"')
    slug=$(echo "$update" | jq -r '.slug // empty')
    action=$(echo "$update" | jq -r '.action // "create"')
    title=$(echo "$update" | jq -r '.title // ""')
    description=$(echo "$update" | jq -r '.description // ""')
    content=$(echo "$update" | jq -r '.content // ""')

    [ -z "$slug" ] && continue
    [ -z "$content" ] && continue

    # Gate: reject MR/session-style slugs
    if echo "$slug" | grep -qE '^mr[0-9]+-|^mr-[0-9]+|-mr[0-9]+$|-session$'; then
      continue
    fi
    # Gate: reject session-narrative content
    if echo "$content" | grep -qiE '(files (changed|touched)|review approach|in this session|friction signals:)'; then
      continue
    fi

    target_dir="$KNOWLEDGE_WIKI/$category"
    mkdir -p "$target_dir"
    target_file="$target_dir/$slug.md"
    ts_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Check for existing page with same slug in any category (avoid duplicates)
    existing=$(find "$KNOWLEDGE_WIKI" -name "$slug.md" -type f ! -name 'index.md' 2>/dev/null | head -1)
    if [ -n "$existing" ] && [ "$existing" != "$target_file" ]; then
      target_file="$existing"
      action="update"
    fi

    if [ "$action" = "update" ] && [ -f "$target_file" ]; then
      # Content-aware dedup: skip if the first 60 chars of new content already appear in the page
      content_check=$(echo "$content" | head -c 60)
      if grep -qF "$content_check" "$target_file" 2>/dev/null; then
        continue
      fi
      # Append under History section with timestamp
      if grep -q '^## History' "$target_file" 2>/dev/null; then
        sed -i.bak "/^## History/a\\
- [$(date +%Y-%m-%d)] $content" "$target_file" && rm -f "$target_file.bak"
      else
        printf '\n## Updates\n\n%s\n' "$content" >> "$target_file"
      fi
      if grep -q '^updated:' "$target_file" 2>/dev/null; then
        sed -i.bak "s/^updated:.*/updated: ${ts_now}/" "$target_file" && rm -f "$target_file.bak"
      fi
    else
      {
        printf '%s\n' "---"
        printf 'title: "%s"\n' "${title:-$slug}"
        printf 'type: %s\n' "$category"
        [ -n "$description" ] && printf 'description: "%s"\n' "$description"
        printf 'created: %s\n' "$ts_now"
        printf 'updated: %s\n' "$ts_now"
        printf '%s\n\n' "---"
        printf '# %s\n\n' "${title:-$slug}"
        printf '%s\n' "$content"
      } > "$target_file"
    fi
  done
  WIKI_WRITES=1
fi

if [ "$CHANGED" -eq 1 ]; then
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  new_tmp=$(mktemp)
  awk -v ts="$ts" '
    /^<!-- last_updated:/ { print "<!-- last_updated: " ts " -->"; next }
    { print }
  ' "$TMP_OUT" > "$new_tmp"
  mv "$new_tmp" "$TMP_OUT"
  mv "$TMP_OUT" "$PROJECT_MD"
  trap - EXIT
fi

if [ "$WIKI_WRITES" -eq 1 ]; then
  PLUGIN_DIST="$(dirname "$0")/../mcp/dist/tools"
  if command -v node >/dev/null 2>&1 && [ -f "$PLUGIN_DIST/knowledge-reindex.bundle.js" ]; then
    node -e "
      import { knowledgeReindex } from '$PLUGIN_DIST/knowledge-reindex.bundle.js';
      knowledgeReindex('$KNOWLEDGE_DIR').catch(() => {});
    " 2>/dev/null || true
  fi
fi

exit 0
