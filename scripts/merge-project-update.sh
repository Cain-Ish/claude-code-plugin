#!/bin/bash
# Idempotent merge of a JSON delta into PROJECT.md + wiki stubs. Used by
# the v1.2.0 Stop-hook auto-archival flow (scripts/stop-extract.sh).
#
# Usage:
#   bash merge-project-update.sh --project-md <path> --wiki-dir <dir> [--json-file <path>]
#   # or pipe JSON on stdin
#
# JSON schema (all keys optional, default to []):
#   {
#     "recent_decisions": ["<text>", ...],   # cap 3 bullets in PROJECT.md
#     "open_blockers":    ["<text>", ...],   # cap 15
#     "cross_refs":       ["<slug>", ...],   # cap 3 bullets, scaffolds wiki/<slug>.md if missing
#     "files_touched":    ["<path>", ...]    # informational; reserved for v1.3+ usage
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
while [ $# -gt 0 ]; do
  case "$1" in
    --project-md) PROJECT_MD="$2"; shift 2 ;;
    --wiki-dir)   WIKI_DIR="$2";   shift 2 ;;
    --json-file)  JSON_FILE="$2";  shift 2 ;;
    *) echo "merge-project-update: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT_MD" ] || { echo "merge-project-update: --project-md is required" >&2; exit 2; }
[ -n "$WIKI_DIR" ]   || { echo "merge-project-update: --wiki-dir is required" >&2; exit 2; }
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

# Insert a bullet under "## <section>", dedupe case-insensitively, cap N.
# Drops the oldest (top-most) bullet when cap is reached.
insert_bullet() {
  local section="$1" bullet_text="$2" cap="$3"
  [ -z "$bullet_text" ] && return 0

  local lower_new
  lower_new=$(printf '%s' "$bullet_text" | tr '[:upper:]' '[:lower:]')
  local existing_lower
  existing_lower=$(awk -v s="$section" '
    $0 == s { flag=1; next }
    /^## / { flag=0 }
    flag && /^- / { print tolower($0) }
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
  # Section-end detection: another `## ` heading, OR the first line that is
  # neither a bullet (`- `) nor blank — this catches the trailing
  # `<!-- last_updated -->` and `<!-- last_queried_wiki -->` comments.
  if [ "$count" -ge "$cap" ]; then
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

if [ -n "$DECISIONS" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    insert_bullet "## Recent decisions" "$line" 3
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

exit 0
