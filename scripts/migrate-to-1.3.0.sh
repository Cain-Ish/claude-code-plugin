#!/bin/bash
# Migrate second-brain to v1.3.0:
# 1. Add YAML frontmatter to all existing wiki pages
# 2. Rename date-prefixed learnings files (move date to frontmatter)
# 3. Fold session pages into entities/concepts
# 4. Clean stale root-level files
# 5. Remove empty wiki dirs
# 6. Auto-scaffold missing PROJECT.md for registered projects
# 7. Generate initial index.md
# 8. Bump .installed-version
#
# Idempotent: can be re-run safely. Pages with existing frontmatter are skipped.
set -u

BRAIN_DIR="$HOME/.second-brain"
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
WIKI_DIR="$KNOWLEDGE_DIR/wiki"
BACKUP_DIR="$BRAIN_DIR/.1.3.0-backup"
VERSION_FILE="$BRAIN_DIR/.installed-version"
INDEX_FILE="$BRAIN_DIR/projects.jsonl"

if [ -f "$VERSION_FILE" ]; then
  CURRENT=$(cat "$VERSION_FILE" | tr -d '[:space:]')
  case "$CURRENT" in
    1.3.*) echo "Already at $CURRENT — nothing to migrate."; exit 0 ;;
  esac
fi

echo "Migrating second-brain to v1.3.0..."

mkdir -p "$BACKUP_DIR"

# --- Step 0: Rename index.txt → projects.jsonl ---
OLD_INDEX="$BRAIN_DIR/index.txt"
if [ -f "$OLD_INDEX" ]; then
  cp "$OLD_INDEX" "$BACKUP_DIR/index.txt"
  mv "$OLD_INDEX" "$INDEX_FILE"
  echo "  [0/8] Renamed index.txt → projects.jsonl."
elif [ ! -f "$INDEX_FILE" ]; then
  : > "$INDEX_FILE"
  echo "  [0/8] Created empty projects.jsonl."
else
  echo "  [0/8] projects.jsonl already exists."
fi

# --- Step 1: Add frontmatter to wiki pages without it ---
add_frontmatter() {
  local file="$1"
  local category="$2"

  if head -1 "$file" | grep -q '^---$'; then
    return 0
  fi

  local slug basename_f
  basename_f=$(basename "$file" .md)
  local title=""
  local created=""

  # Extract date from date-prefixed filenames
  if echo "$basename_f" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-'; then
    created=$(echo "$basename_f" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
    slug=$(echo "$basename_f" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')
  else
    slug="$basename_f"
  fi

  # Extract title from first # heading
  title=$(grep -m1 '^# ' "$file" | sed 's/^# //')
  [ -z "$title" ] && title="$slug"

  # Extract first sentence for description
  local desc
  desc=$(sed '/^#/d; /^$/d; /^<!--/d' "$file" | head -3 | tr '\n' ' ' | sed 's/\. .*/./; s/^[[:space:]]*//' | head -c 120)

  # Extract wikilinks for related
  local related
  related=$(grep -oE '\[\[[^]]+\]\]' "$file" 2>/dev/null | sed 's/\[\[//;s/\]\]//' | sort -u | head -5)

  [ -z "$created" ] && created=$(stat -f '%Sm' -t '%Y-%m-%d' "$file" 2>/dev/null || date +%Y-%m-%d)
  local updated
  updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local fm_file
  fm_file=$(mktemp)
  {
    echo "---"
    printf 'title: "%s"\n' "$title"
    printf 'type: %s\n' "$category"
    [ -n "$desc" ] && printf 'description: "%s"\n' "$(echo "$desc" | sed 's/"/\\"/g')"
    printf 'created: %s\n' "$created"
    printf 'updated: %s\n' "$updated"
    if [ -n "$related" ]; then
      echo "related:"
      echo "$related" | while IFS= read -r r; do
        [ -n "$r" ] && printf '  - %s\n' "$r"
      done
    fi
    echo "---"
    echo ""
  } > "$fm_file"

  cat "$file" >> "$fm_file"
  mv "$fm_file" "$file"
}

find "$WIKI_DIR" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | while IFS= read -r f; do
  rel=$(echo "$f" | sed "s|$WIKI_DIR/||")
  category=$(echo "$rel" | cut -d'/' -f1)
  add_frontmatter "$f" "$category"
done
echo "  [1/8] Frontmatter added to wiki pages."

# --- Step 2: Rename date-prefixed learnings ---
find "$WIKI_DIR/learnings" -name '*.md' -type f 2>/dev/null | while IFS= read -r f; do
  bn=$(basename "$f" .md)
  if echo "$bn" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-'; then
    new_name=$(echo "$bn" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')
    new_path="$(dirname "$f")/$new_name.md"
    if [ ! -f "$new_path" ]; then
      mv "$f" "$new_path"
    fi
  fi
done
echo "  [2/8] Date-prefixed learning files renamed."

# --- Step 3: Fold session pages into entities/concepts ---
if [ -d "$WIKI_DIR/sessions" ]; then
  mkdir -p "$BACKUP_DIR/sessions"
  for f in "$WIKI_DIR/sessions"/*.md; do
    [ -f "$f" ] || continue
    cp "$f" "$BACKUP_DIR/sessions/"
    # Move to entities — sessions are typically about specific projects/features
    mkdir -p "$WIKI_DIR/entities"
    bn=$(basename "$f" .md)
    # Strip date prefix
    new_name=$(echo "$bn" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')
    target="$WIKI_DIR/entities/$new_name.md"
    if [ ! -f "$target" ]; then
      mv "$f" "$target"
      # Update type in frontmatter if present
      if head -1 "$target" | grep -q '^---$'; then
        sed -i.bak 's/^type: sessions$/type: entities/' "$target" && rm -f "$target.bak"
      fi
    fi
  done
  rmdir "$WIKI_DIR/sessions" 2>/dev/null || true
  echo "  [3/8] Session pages folded into entities."
else
  echo "  [3/8] No session pages to fold."
fi

# --- Step 4: Clean stale root-level files ---
for stale in "$BRAIN_DIR/learnings.md" "$BRAIN_DIR/persona.md" "$BRAIN_DIR/quality-rules.md" "$BRAIN_DIR/tool-registry.json" "$BRAIN_DIR/PROJECT.md"; do
  if [ -f "$stale" ]; then
    cp "$stale" "$BACKUP_DIR/"
    rm "$stale"
  fi
done
# Remove legacy ~/.second-brain/wiki/ (duplicate of ~/knowledge/wiki/)
if [ -d "$BRAIN_DIR/wiki" ]; then
  cp -r "$BRAIN_DIR/wiki/" "$BACKUP_DIR/legacy-wiki/" 2>/dev/null || true
  rm -rf "$BRAIN_DIR/wiki"
fi
# Remove orphan root files in knowledge dir
for orphan in "$KNOWLEDGE_DIR"/*.md; do
  [ -f "$orphan" ] || continue
  bn=$(basename "$orphan")
  [ "$bn" = "README.md" ] && continue
  cp "$orphan" "$BACKUP_DIR/"
  rm "$orphan"
done
# Remove empty date-prefixed files at knowledge root
for orphan in "$KNOWLEDGE_DIR"/2*-*.md; do
  [ -f "$orphan" ] || continue
  if [ ! -s "$orphan" ]; then
    rm "$orphan"
  else
    cp "$orphan" "$BACKUP_DIR/"
    rm "$orphan"
  fi
done
echo "  [4/8] Stale files and orphans cleaned."

# --- Step 5: Remove empty wiki dirs ---
for d in "$WIKI_DIR"/*/; do
  [ -d "$d" ] || continue
  if [ -z "$(find "$d" -name '*.md' -type f 2>/dev/null)" ]; then
    rmdir "$d" 2>/dev/null || true
  fi
done
echo "  [5/8] Empty wiki directories removed."

# --- Step 6: Auto-scaffold missing PROJECT.md for registered projects ---
if [ -f "$INDEX_FILE" ]; then
  while IFS= read -r line; do
    slug=$(echo "$line" | jq -r '.slug // empty' 2>/dev/null)
    [ -z "$slug" ] && continue
    pf="$BRAIN_DIR/projects/$slug/PROJECT.md"
    if [ ! -f "$pf" ]; then
      mkdir -p "$(dirname "$pf")"
      cat > "$pf" <<TMPL
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
    fi
  done < "$INDEX_FILE"
fi
echo "  [6/8] Missing PROJECT.md files scaffolded."

# --- Step 7: Generate initial index.md ---
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
if command -v node >/dev/null 2>&1 && [ -f "$PLUGIN_ROOT/mcp/dist/tools/knowledge-reindex.js" ]; then
  node -e "
    import { knowledgeReindex } from '$PLUGIN_ROOT/mcp/dist/tools/knowledge-reindex.js';
    knowledgeReindex('$KNOWLEDGE_DIR').then(r => console.log('  [7/8] Index generated: ' + r.pagesIndexed + ' pages.'))
      .catch(e => console.log('  [7/8] Index generation failed: ' + e.message));
  " 2>/dev/null || echo "  [7/8] Index generation skipped (node import failed)."
else
  echo "  [7/8] Index generation skipped (node or dist not available)."
fi

# --- Step 8: Bump version ---
echo "1.3.0" > "$VERSION_FILE"
echo "  [8/8] Version bumped to 1.3.0."

echo ""
echo "Migration to v1.3.0 complete."
echo "Backup of removed files: $BACKUP_DIR"
