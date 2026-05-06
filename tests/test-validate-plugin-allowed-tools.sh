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
cp -r "$REPO_ROOT"/. "$TMP/" || fail "repo mirror failed"
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
