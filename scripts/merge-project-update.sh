#!/bin/bash
# Idempotent merge of a JSON delta into PROJECT.md + wiki pages. Used by
# the v1.2.0+ Stop-hook auto-archival flow (scripts/stop-extract.sh).
#
# Usage:
#   bash merge-project-update.sh --project-md <path> --knowledge-dir <dir> [--json-file <path>]
#   # or pipe JSON on stdin
#
# JSON schema (all keys optional, default to []):
#   {
#     "recent_decisions": ["<text>", ...],   # cap 3 bullets in PROJECT.md
#     "open_blockers":    ["<text>", ...],   # cap 15
#     "cross_refs":       ["<slug>", ...],   # cap 3, scaffolds ~/knowledge/wiki/entities/<slug>.md if missing
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
#   - Missing cross-ref pages get a proper frontmatter stub in wiki/entities/.
#   - Atomic write: stage to a tempfile, mv into place.
#   - Invalid JSON on stdin → exit non-zero with PROJECT.md untouched.
set -u
source "$(dirname "$0")/lib.sh"

PROJECT_MD=""
JSON_FILE=""
KNOWLEDGE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project-md)    PROJECT_MD="$2";    shift 2 ;;
    --knowledge-dir) KNOWLEDGE_DIR="$2"; shift 2 ;;
    --json-file)     JSON_FILE="$2";     shift 2 ;;
    *) echo "merge-project-update: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT_MD" ] || { echo "merge-project-update: --project-md is required" >&2; exit 2; }
[ -z "$KNOWLEDGE_DIR" ] && KNOWLEDGE_DIR="$(sb_knowledge_dir)"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"   # re-expand: a --knowledge-dir arg may carry a literal ~
KNOWLEDGE_WIKI="$KNOWLEDGE_DIR/wiki"
# Phase 1b: the render CLI turns a structured ai_block into the marked region deterministically
# (reuses the TS schema → no bash/TS drift). Resolved relative to this script (plugin root).
RENDER_CLI="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")"/.. && pwd)}/mcp/dist/tools/ai-block-render-cli.bundle.js"
[ -f "$PROJECT_MD" ] || { echo "merge-project-update: project file not found: $PROJECT_MD" >&2; exit 2; }

if [ -n "$JSON_FILE" ]; then
  RAW=$(cat "$JSON_FILE")
else
  RAW=$(cat)
fi

if ! echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "merge-project-update: input is not a JSON object" >&2
  exit 1
fi

WIKI_WRITES=0

# Strip CR from every line — Windows / Git-Bash jq pipelines can leak \r
# into values, which silently breaks all our string comparisons below.
strip_cr() { tr -d '\r'; }
DECISIONS=$(echo "$RAW" | jq -r '.recent_decisions // [] | .[]?' 2>/dev/null | strip_cr)
BLOCKERS=$(echo  "$RAW" | jq -r '.open_blockers   // [] | .[]?' 2>/dev/null | strip_cr)
REFS=$(echo      "$RAW" | jq -r '.cross_refs      // [] | .[]?' 2>/dev/null | strip_cr)
PLAN=$(echo      "$RAW" | jq -r '.plan            // [] | .[]?' 2>/dev/null | strip_cr)

CHANGED=0

TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT
# tr -d '\r' (not cp): normalize CRLF at ingest so every downstream awk/grep reader sees LF.
# A CRLF PROJECT.md (Windows/imported) otherwise silently no-ops the ENTIRE merge — section
# headers like `## Recent decisions` never match `/^## .../`, so decisions/blockers/plan are
# never written and dedup never fires. The merge writes TMP_OUT back, so this also LF-normalizes.
tr -d '\r' < "$PROJECT_MD" > "$TMP_OUT"

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
        flag && /^- / && !/\[pinned\]/ { print; exit }
      ' "$TMP_OUT")
      [ -n "$oldest" ] && archive_dropped_decision "$oldest"
    fi
    BULLET="- $bullet_text" awk -v s="$section" '
      BEGIN { flag=0; dropped=0; appended=0; new=ENVIRON["BULLET"] }
      $0 == s { print; flag=1; next }
      flag && /^## / {
        if (!appended) { print new; appended=1 }
        flag=0; print; next
      }
      flag && !appended && !/^- / && !/^$/ {
        print new; appended=1; flag=0; print; next
      }
      flag && /^- / && !/\[pinned\]/ && !dropped { dropped=1; next }
      { print }
      END {
        if (flag && !appended) { print new }
      }
    ' "$TMP_OUT" > "$new_tmp"
  else
    BULLET="- $bullet_text" awk -v s="$section" '
      BEGIN { flag=0; appended=0; new=ENVIRON["BULLET"] }
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

# Reconcile the ## Plan checklist with the freshly-extracted items. The Plan is
# FORWARD state (what's next) — distinct from the backward-looking Recent decisions.
# Strategy: the extractor emits the full current checklist each session; we replace
# the non-[pinned] lines with it (capped), preserving [pinned] lines verbatim on top
# (human-authored north stars the LLM must never rewrite or rotate). A degraded/empty
# emission is a NO-OP — we never wipe the plan on a session that produced nothing.
# NOTE: [pinned] is the shared human-protection marker — insert_bullet() honours it the
# same way for ## Recent decisions / ## Open blockers (oldest NON-pinned bullet drops).
merge_plan() {
  local items="$1" cap="${2:-7}"
  [ -z "$items" ] && return 0
  # Only act when a ## Plan section exists (new projects scaffold it; the upgrade
  # migration backfills older PROJECT.md files). No section → nothing to reconcile.
  grep -q '^## Plan$' "$TMP_OUT" || return 0

  local pinned_lines
  pinned_lines=$(awk '/^## Plan$/{f=1;next} /^## /{f=0} f && /^- / && /\[pinned\]/' "$TMP_OUT")

  local new_body="" n=0 t bare
  while IFS= read -r it; do
    [ -z "$it" ] && continue
    t=$(printf '%s' "$it" | sed -E 's/^[[:space:]]*[-*+]?[[:space:]]*//')   # strip a leading -, * or + bullet
    case "$t" in
      '[ ]'*|'[x]'*|'[X]'*) ;;                                         # already has a checkbox
      *) t="[ ] $t" ;;                                                 # default to an open box
    esac
    # never duplicate a [pinned] line — compare BARE text (drop checkbox + pinned prefix), exact match
    if [ -n "$pinned_lines" ]; then
      bare=$(printf '%s' "$t" | sed -E 's/^\[[ xX]\][[:space:]]*//')
      if printf '%s\n' "$pinned_lines" | sed -E 's/^- \[pinned\][[:space:]]*//' | grep -qiFx -- "$bare"; then continue; fi
    fi
    new_body="${new_body}${new_body:+$'\n'}- $t"
    n=$((n+1)); [ "$n" -ge "$cap" ] && break
  done <<< "$items"

  local body="$pinned_lines"
  [ -n "$new_body" ] && body="${body}${body:+$'\n'}$new_body"

  local new_tmp; new_tmp=$(mktemp)
  BODY="$body" awk '
    BEGIN { body=ENVIRON["BODY"] }
    $0 == "## Plan" { print; print ""; if (length(body)) print body; print ""; f=1; next }
    f && (/^## / || /^<!--/) { f=0; print; next }   # next heading OR the footer terminates — never swallow the <!-- last_updated --> footer
    f { next }
    { print }
  ' "$TMP_OUT" > "$new_tmp"
  # Preserve the module's no-op contract: only rewrite + mark dirty when the plan
  # actually changed. The extractor re-emits the full list every session, so an
  # unchanged plan must NOT churn last_updated.
  if cmp -s "$new_tmp" "$TMP_OUT"; then
    rm -f "$new_tmp"
  else
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
  fi
}

# Detect if a new decision contradicts an existing one. Marks old as [superseded].
# Requires: negation words in new + >50% word overlap with existing.
detect_supersede() {
  [ "${SB_SKIP_SUPERSEDE:-0}" = "1" ] && return 1
  local new_text="$1"
  local new_lower
  new_lower=$(printf '%s' "$new_text" | tr '[:upper:]' '[:lower:]')

  # Must contain negation or explicit override language
  if ! echo "$new_lower" | grep -qE "(don't|dont|do not|not |never |removed |dropped |disabled |stopped |supersedes |replaces |instead of |no longer )"; then
    return 1
  fi

  local new_words new_count
  new_words=$(printf '%s' "$new_lower" | sed 's/\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\] //' | tr -cs '[:alpha:]' '\n' | grep -vxE '(the|a|an|is|are|was|were|to|of|in|for|on|at|by|with|not|no|dont|never|don|do|instead|supersedes|replaces)' | sort -u)
  new_count=$(echo "$new_words" | grep -c . 2>/dev/null || true)
  [ "$new_count" -lt 3 ] && return 1

  local existing
  existing=$(awk '
    /^## Recent decisions$/ { flag=1; next }
    /^## / { flag=0 }
    flag && /^- / && !/\[superseded\]/ && !/\[stale\]/ { print }
  ' "$TMP_OUT")

  [ -z "$existing" ] && return 1

  while IFS= read -r old_line; do
    [ -z "$old_line" ] && continue
    local old_lower old_words old_count overlap pct
    old_lower=$(printf '%s' "$old_line" | tr '[:upper:]' '[:lower:]')
    old_words=$(printf '%s' "$old_lower" | sed 's/^- //' | sed 's/\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\] //' | tr -cs '[:alpha:]' '\n' | grep -vxE '(the|a|an|is|are|was|were|to|of|in|for|on|at|by|with|not|no|dont|never|don|do)' | sort -u)
    old_count=$(echo "$old_words" | grep -c . 2>/dev/null || true)
    [ "$old_count" -eq 0 ] && continue
    overlap=$(comm -12 <(echo "$new_words") <(echo "$old_words") | grep -c . 2>/dev/null || true)
    pct=$((overlap * 100 / old_count))
    if [ "$pct" -ge 50 ]; then
      local new_tmp
      new_tmp=$(mktemp)
      OLD_LINE="$old_line" awk '
        BEGIN { target = ENVIRON["OLD_LINE"]; done = 0 }
        !done && $0 == target { sub(/^- /, "- [superseded] "); done = 1 }
        { print }
      ' "$TMP_OUT" > "$new_tmp"
      mv "$new_tmp" "$TMP_OUT"
      CHANGED=1
      return 0
    fi
  done <<< "$existing"
  return 1
}

TODAY=$(date +%Y-%m-%d)
if [ -n "$DECISIONS" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Skip "files this session" fallback lines — they're not decisions
    echo "$line" | grep -q '^files this session:' && continue
    # Prefix with date if not already dated
    dated_line="$line"
    if ! echo "$line" | grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}\]'; then
      dated_line="[$TODAY] $line"
    fi
    detect_supersede "$dated_line" || true
    insert_bullet "## Recent decisions" "$dated_line" 5
  done <<< "$DECISIONS"
fi

if [ -n "$BLOCKERS" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    insert_bullet "## Open blockers" "$line" 15
  done <<< "$BLOCKERS"
fi

# Forward-looking plan (replace-reconcile; preserves [pinned], never wipes on empty).
merge_plan "$PLAN" 7

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
    safe_ref=$(sb_sanitize_slug "$ref") || continue
    # Skip if page already exists anywhere in the wiki
    if ! find "$KNOWLEDGE_WIKI" -name "$safe_ref.md" -type f ! -name 'index.md' 2>/dev/null | grep -q .; then
      # Auto-restore: if this slug was forgotten, revive the original instead of
      # stubbing. Log only after a successful mv (no phantom "restored" events); if
      # the mv fails (archive file vanished), fall through to creating the stub.
      arch=$(BRAIN_DIR="$BRAIN_DIR" "$(dirname "$0")/wiki-archived-slugs.sh" --path "$safe_ref" 2>/dev/null) || arch=""
      restored=0
      if [ -n "$arch" ]; then
        acat=$(basename "$(dirname "$arch")"); mkdir -p "$KNOWLEDGE_WIKI/$acat"
        if mv "$arch" "$KNOWLEDGE_WIKI/$acat/$safe_ref.md" 2>/dev/null; then
          printf '{"event":"restored","slug":"%s","category":"%s","date":"%s"}\n' \
            "$safe_ref" "$acat" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BRAIN_DIR/wiki-archive-log.jsonl" 2>/dev/null || true
          WIKI_WRITES=1; CHANGED=1; restored=1
        fi
      fi
      if [ "$restored" -eq 0 ]; then
        mkdir -p "$KNOWLEDGE_WIKI/entities"
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        {
          printf '%s\n' "---"
          printf 'title: "%s"\n' "$ref"
          printf 'type: entities\n'
          printf 'description: "Auto-created stub — needs expansion."\n'
          printf 'created: %s\n' "$ts"
          printf 'updated: %s\n' "$ts"
          printf 'related: []\n'
          printf 'tags: []\n'
          printf '%s\n\n' "---"
          printf '# %s\n\n' "$ref"
          printf 'TODO: expand.\n'
        } > "$KNOWLEDGE_WIKI/entities/$safe_ref.md"
        WIKI_WRITES=1
        CHANGED=1
      fi
    fi
  done <<< "$REFS"
fi

# --- Auto-staleness: mark decisions/blockers older than N days as [stale] ---
# N defaults to 30 (the review skill's staleness horizon); override per policy.
# Validate-or-default (same idiom as SB_DREAM_STALE_DAYS / SB_FORGET_MIN_AGE_DAYS).
STALE_DAYS="${SB_PROJECT_STALE_DAYS:-30}"
case "$STALE_DAYS" in ''|*[!0-9]*) STALE_DAYS=30 ;; esac
STALE_CUTOFF=$(date -v-"${STALE_DAYS}"d +%Y-%m-%d 2>/dev/null \
  || date -d "${STALE_DAYS} days ago" +%Y-%m-%d 2>/dev/null \
  || echo "1970-01-01")

mark_stale() {
  local section="$1"
  local new_tmp
  new_tmp=$(mktemp)
  awk -v s="$section" -v cutoff="$STALE_CUTOFF" '
    $0 == s { flag=1; print; next }
    /^## / { flag=0; print; next }
    flag && /^- \[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ && !/\[stale\]/ && !/\[superseded\]/ {
      d = $0; sub(/^- \[/, "", d); sub(/\].*/, "", d)
      if (d < cutoff) { sub(/^- /, "- [stale] "); changed=1 }
    }
    { print }
    END { exit (changed ? 0 : 1) }
  ' "$TMP_OUT" > "$new_tmp"
  if [ $? -eq 0 ]; then
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
  else
    rm -f "$new_tmp"
  fi
}

mark_stale "## Recent decisions"
mark_stale "## Open blockers"

WIKI_UPDATES_COUNT=$(echo "$RAW" | jq '.wiki_updates // [] | length' 2>/dev/null || echo 0)
if [ "$WIKI_UPDATES_COUNT" -gt 0 ]; then
  mkdir -p "$KNOWLEDGE_WIKI"
  while IFS= read -r update; do
    raw_category=$(echo "$update" | jq -r '.category // "concepts"' | tr -d '\r')
    raw_slug=$(echo "$update" | jq -r '.slug // empty' | tr -d '\r')
    action=$(echo "$update" | jq -r '.action // "create"' | tr -d '\r')
    title=$(echo "$update" | jq -r '.title // ""' | tr -d '\r')
    description=$(echo "$update" | jq -r '.description // ""' | tr -d '\r')
    content=$(echo "$update" | jq -r '.content // ""' | tr -d '\r')

    category=$(sb_sanitize_slug "$raw_category") || continue
    slug=$(sb_sanitize_slug "$raw_slug") || continue
    [ -z "$content" ] && continue

    # Render the extractor's structured ai_block into the marked region (closed-vocab,
    # schema-ordered). Fail-safe: no block / no node / no CLI ⇒ "" (inject nothing).
    ai_region=""
    aiblk=$(echo "$update" | jq -c '.ai_block // empty' 2>/dev/null)
    if [ -n "$aiblk" ] && [ "$aiblk" != "null" ] && command -v node >/dev/null 2>&1 && [ -f "$RENDER_CLI" ]; then
      ai_region=$(jq -nc --arg t "$category" --argjson b "$aiblk" '{type:$t,block:$b}' 2>/dev/null | node "$RENDER_CLI" 2>/dev/null)
    fi

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
    if [ -z "$existing" ]; then
      # Auto-restore: re-creating a forgotten slug revives the original (then the
      # new content lands as an update below) rather than spawning a duplicate.
      arch=$(BRAIN_DIR="$BRAIN_DIR" "$(dirname "$0")/wiki-archived-slugs.sh" --path "$slug" 2>/dev/null) || arch=""
      if [ -n "$arch" ]; then
        acat=$(basename "$(dirname "$arch")"); mkdir -p "$KNOWLEDGE_WIKI/$acat"
        if mv "$arch" "$KNOWLEDGE_WIKI/$acat/$slug.md" 2>/dev/null; then
          printf '{"event":"restored","slug":"%s","category":"%s","date":"%s"}\n' \
            "$slug" "$acat" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BRAIN_DIR/wiki-archive-log.jsonl" 2>/dev/null || true
          existing="$KNOWLEDGE_WIKI/$acat/$slug.md"; target_file="$existing"; action="update"
        fi
      fi
    fi
    if [ -n "$existing" ] && [ "$existing" != "$target_file" ]; then
      target_file="$existing"
      action="update"
    fi

    if [ "$action" = "update" ] && [ -f "$target_file" ]; then
      # Phase 3: refresh the authored ai-block FIRST -- before the prose-dedup early-continue --
      # so a sharpened block is applied even when the prose is a duplicate ("a stale block is
      # worse than none"). Replace a COMPLETE region in place (FIRST ai:begin only, via a
      # `replaced` latch + a `drop` that never re-arms -- so a stray ai:begin in prose can't
      # duplicate the region or run away to EOF); inject after a real frontmatter fence if absent;
      # leave a malformed begin-without-end page untouched (never eat the body). mawk-safe: ENVIRON.
      if [ -n "$ai_region" ]; then
        if grep -qE '<!--[[:space:]]*ai:begin' "$target_file" 2>/dev/null; then
          if grep -qE '<!--[[:space:]]*ai:end[[:space:]]*-->' "$target_file" 2>/dev/null; then
            AI_REGION="$ai_region" awk '
              BEGIN { reg = ENVIRON["AI_REGION"] }
              /<!--[[:space:]]*ai:begin/ && !replaced { print reg; drop=1; replaced=1; next }
              drop && /<!--[[:space:]]*ai:end[[:space:]]*-->/ { drop=0; next }
              drop { next }
              { print }
            ' "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
          fi
          # else: malformed (begin without end) -> no-op (safe)
        else
          AI_REGION="$ai_region" awk '
            BEGIN { reg = ENVIRON["AI_REGION"]; fm=0; done=0 }
            NR==1 && !/^---[[:space:]]*$/ { print; noinject=1; next }
            noinject { print; next }
            /^---[[:space:]]*$/ && fm<2 { print; fm++; if (fm==2 && !done) { print ""; print reg; print ""; done=1 } next }
            { print }
          ' "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
        fi
      fi
      # Content-aware dedup: skip if the first 60 chars of new content already appear in the page
      content_check=$(echo "$content" | head -c 60)
      if grep -qF "$content_check" "$target_file" 2>/dev/null; then
        continue
      fi
      # Append under History/Updates section with timestamp
      if grep -q '^## History' "$target_file" 2>/dev/null; then
        CONTENT="$content" awk -v ts="$(date +%Y-%m-%d)" '
          /^## History/ { print; printed=1; next }
          printed && !inserted { print "- [" ts "] " ENVIRON["CONTENT"]; inserted=1 }
          { print }
        ' "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
      else
        printf '\n## Updates\n\n%s\n' "$content" >> "$target_file"
      fi
      if grep -q '^updated:' "$target_file" 2>/dev/null; then
        awk -v ts="$ts_now" '{ if (/^updated:/) print "updated: " ts; else print }' \
          "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
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
        [ -n "$ai_region" ] && printf '%s\n\n' "$ai_region"   # authored ai-block (shared intermediate)
        printf '# %s\n\n' "${title:-$slug}"
        printf '%s\n' "$content"
      } > "$target_file"
    fi
    WIKI_WRITES=1
  done < <(echo "$RAW" | jq -c '.wiki_updates // [] | .[]' 2>/dev/null)
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
  # Centralized reindex helper (lib.sh) — handles ESM dynamic-import correctly
  # and derives plugin root when CLAUDE_PLUGIN_ROOT is unset.
  sb_reindex_wiki "$KNOWLEDGE_DIR"
  # Increment the wiki-writes counter. session-load.sh consumes this at the
  # SB_MAINTAINER_THRESHOLD and auto-dispatches the maintainer subagent.
  PROJECT_SLUG=$(basename "$(dirname "$PROJECT_MD")")
  [ -n "$PROJECT_SLUG" ] && sb_inc_wiki_writes "$PROJECT_SLUG"
fi

# Reset session counter after a dream cycle. We detect "dream just accepted"
# by the presence of a freshly-archived dream dir touched within last 5 min.
# Cheap heuristic, no MCP roundtrip needed.
RECENT_DREAM=$(find "$BRAIN_DIR/dreams/" -maxdepth 2 -name 'status.json' -mmin -5 2>/dev/null \
  | xargs -I{} jq -r 'select(.status == "completed" or .status == "archived") | .id' {} 2>/dev/null | head -1)
if [ -n "$RECENT_DREAM" ]; then
  PROJECT_SLUG=$(basename "$(dirname "$PROJECT_MD")")
  [ -n "$PROJECT_SLUG" ] && sb_reset_session_count "$PROJECT_SLUG"
fi

exit 0
