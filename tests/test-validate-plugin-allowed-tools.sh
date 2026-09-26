#!/bin/bash
# Tests that validate-plugin.sh fails when a SKILL.md is missing
# 'allowed-tools' in its YAML frontmatter.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$REPO_ROOT/scripts/validate-plugin.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Mirror the repo into TMP. Use cp -r; symlinks would let the script find the
# real skills/ tree and miss our mutation.
# Cross-OS note: cp -r of the whole repo copies mcp/node_modules (500MB+) and
# .git (~23MB) — on Windows/Git-Bash that takes 90s+ and times out.  Copy only
# the subtrees validate-plugin.sh actually inspects.
for _d in skills scripts agents hooks docs output-styles .claude-plugin mcp; do
  [ -e "$REPO_ROOT/$_d" ] || continue
  # For mcp: only package.json is needed; skip node_modules (500MB+).
  if [ "$_d" = "mcp" ]; then
    mkdir -p "$TMP/mcp"
    [ -f "$REPO_ROOT/mcp/package.json" ] && cp "$REPO_ROOT/mcp/package.json" "$TMP/mcp/package.json"
    continue
  fi
  cp -r "$REPO_ROOT/$_d" "$TMP/$_d" || fail "repo mirror failed for $_d"
done
unset _d
# Slice 1 (docs/plans/2026-09-24-repo-brain.md): the agent frontmatter check reads
# model-ladder.json's dispatch_aliases (never a literal alias list) — the mirror needs it too.
[ -f "$REPO_ROOT/model-ladder.json" ] && cp "$REPO_ROOT/model-ladder.json" "$TMP/model-ladder.json"
# marketplace.json's source is ./plugin (the shipped tree); the validator follows it to the
# manifest there. Mirror that manifest dir plus every ./path it references — never the 4.5 MB
# tree. `claude plugin validate --strict` (CLI 2.1.283+) fails on a referenced path that is
# absent (outputStyles: ./output-styles/); CI has no claude CLI, so only local runs caught it.
if [ -d "$REPO_ROOT/plugin/.claude-plugin" ]; then
  mkdir -p "$TMP/plugin" && cp -r "$REPO_ROOT/plugin/.claude-plugin" "$TMP/plugin/.claude-plugin" || fail "repo mirror failed for plugin/.claude-plugin"
  _refs=$(jq -r '.. | strings | select(startswith("./"))' "$REPO_ROOT/plugin/.claude-plugin/plugin.json") \
    || fail "jq could not read plugin/.claude-plugin/plugin.json"
  while IFS= read -r _p; do
    _p=${_p#./}; _p=${_p%/}
    case "$_p" in
      ''|.claude-plugin|.claude-plugin/*) continue ;;
      *..*) fail "plugin/.claude-plugin/plugin.json path escapes plugin/: $_p" ;;
    esac
    [ -e "$REPO_ROOT/plugin/$_p" ] || fail "plugin/.claude-plugin/plugin.json references missing path: plugin/$_p"
    mkdir -p "$TMP/plugin/$(dirname "$_p")" && cp -r "$REPO_ROOT/plugin/$_p" "$TMP/plugin/$_p" || fail "repo mirror failed for plugin/$_p"
  done < <(printf '%s\n' "$_refs" | tr -d '\r')
  unset _p _refs
fi
export CLAUDE_PLUGIN_ROOT="$TMP"

# Sanity: validator passes on an unmutated mirror
"$SCRIPT" >/dev/null || fail "validator failed on unmutated mirror"
pass "baseline mirror validates"

# Mutation: drop the allowed-tools line from one skill's frontmatter
TARGET="$TMP/skills/setup/SKILL.md"
[ -f "$TARGET" ] || fail "target skill missing in mirror: $TARGET"
grep -q '^allowed-tools:' "$TARGET" || fail "target skill has no allowed-tools to drop"
sed -i.bak '/^allowed-tools:/d' "$TARGET" && rm -f "$TARGET.bak"

# Validator must now fail
OUTPUT=$("$SCRIPT" 2>&1) && fail "validator should have failed but exited 0"
echo "$OUTPUT" | grep -q "setup/SKILL.md missing 'allowed-tools'" || {
  echo "--- validator output ---"
  echo "$OUTPUT"
  fail "expected error message not found"
}
pass "validator rejects skill missing allowed-tools"

echo "ALL PASS"
