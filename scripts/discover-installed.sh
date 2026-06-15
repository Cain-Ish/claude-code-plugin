#!/bin/bash
# discover-installed.sh — enumerate installed plugins/agents/skills under a plugins root.
# Usage: discover-installed.sh [plugins-root]
# Defaults: plugins-root=${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins/cache}
# Writes JSON catalog to ${BRAIN_DIR:-~/.second-brain}/.installed-catalog.json and stdout.
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

PLUGINS_ROOT="${1:-${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins/cache}}"
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
OUT_FILE="$BRAIN_DIR/.installed-catalog.json"

mkdir -p "$BRAIN_DIR"

# Fast-path: reuse cached catalog if nothing under plugins dir has changed.
# We compare against ANY file in the tree, not just $PLUGINS_ROOT itself —
# directory mtime only bumps when entries at the immediate level change, so
# a plugin update inside a subdirectory leaves a root-only check stale
# indefinitely. `head -n1` closes the pipe on the first hit, short-circuiting find
# portably — `-quit` is a GNU-only primary that BSD/macOS find rejects (its swallowed
# error empties the capture and the script then re-discovers on every single run).
if [ -f "$OUT_FILE" ] && [ -d "$PLUGINS_ROOT" ]; then
  NEWER=$(find "$PLUGINS_ROOT" -newer "$OUT_FILE" -print 2>/dev/null | head -n1)
  if [ -z "$NEWER" ]; then
    cat "$OUT_FILE"
    exit 0
  fi
fi

TMP_PLUGINS=$(mktemp)
TMP_AGENTS=$(mktemp)
TMP_SKILLS=$(mktemp)
trap 'rm -f "$TMP_PLUGINS" "$TMP_AGENTS" "$TMP_SKILLS"' EXIT

# Extract a YAML frontmatter field value. Reads stdin.
fm_value() {
  awk -v key="$1" '
    /^---$/ { f = !f; next }
    f {
      pattern = "^" key ":"
      if ($0 ~ pattern) {
        sub(pattern "[[:space:]]*", "")
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "")
        print
        exit
      }
    }'
}

if [ -d "$PLUGINS_ROOT" ]; then
  while IFS= read -r pj; do
    [ -f "$pj" ] || continue
    name=$(jq -r '.name // empty' "$pj" 2>/dev/null) || continue
    [ -z "$name" ] && continue
    desc=$(jq -r '.description // ""' "$pj" 2>/dev/null)
    ver=$(jq -r '.version // ""' "$pj" 2>/dev/null)
    jq -nc --arg n "$name" --arg d "$desc" --arg v "$ver" \
      '{name:$n, description:$d, version:$v}' >> "$TMP_PLUGINS"

    # Resolve the plugin's root dir. plugin.json may live at <root>/plugin.json
    # or <root>/.claude-plugin/plugin.json.
    plugin_dir=$(dirname "$pj")
    if [ "$(basename "$plugin_dir")" = ".claude-plugin" ]; then
      plugin_dir=$(dirname "$plugin_dir")
    fi

    while IFS= read -r af; do
      [ -f "$af" ] || continue
      aname=$(fm_value name < "$af")
      adesc=$(fm_value description < "$af")
      [ -z "$aname" ] && continue
      jq -nc --arg n "$aname" --arg d "$adesc" --arg p "$name" \
        '{name:$n, description:$d, plugin:$p}' >> "$TMP_AGENTS"
    done < <(find "$plugin_dir/agents" -maxdepth 1 -name '*.md' -type f 2>/dev/null)

    while IFS= read -r sf; do
      [ -f "$sf" ] || continue
      sname=$(fm_value name < "$sf")
      sdesc=$(fm_value description < "$sf")
      [ -z "$sname" ] && continue
      jq -nc --arg n "$sname" --arg d "$sdesc" --arg p "$name" \
        '{name:$n, description:$d, plugin:$p}' >> "$TMP_SKILLS"
    done < <(find "$plugin_dir/skills" -mindepth 2 -maxdepth 2 -name 'SKILL.md' -type f 2>/dev/null)
  done < <(find "$PLUGINS_ROOT" -name 'plugin.json' -type f 2>/dev/null | head -200)
fi

# Slurp the JSONL streams into a single catalog object.
CATALOG=$(jq -ns \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile p "$TMP_PLUGINS" \
  --slurpfile a "$TMP_AGENTS" \
  --slurpfile s "$TMP_SKILLS" \
  '{generated_at:$ts, plugins:$p, agents:$a, skills:$s}')

echo "$CATALOG" > "$OUT_FILE"
echo "$CATALOG"
