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
for _d in skills scripts agents hooks docs .claude-plugin mcp; do
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
