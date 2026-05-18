#!/bin/bash
# Tests for v2.8.0 maintainer auto-dispatch — counter helpers + session-load.sh
# state machine. We never invoke `claude` here; session-load.sh writes
# additionalContext to stdout and we assert on its content + marker files.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
LIB="$REPO_ROOT/scripts/lib.sh"
# shellcheck disable=SC2034  # SCRIPT is used by tests added in later tasks
SCRIPT="$REPO_ROOT/scripts/session-load.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

init_sandbox() {
  local name="$1"
  SANDBOX="$TMP/$name"
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/.second-brain/projects/test-slug" \
           "$SANDBOX/repo/test-slug"
  export HOME="$SANDBOX"
  export BRAIN_DIR="$SANDBOX/.second-brain"
  cd "$SANDBOX/repo/test-slug" || fail "cd failed in $name"
  # Minimal PROJECT.md so session-load.sh resolves the slug.
  cat > "$SANDBOX/.second-brain/projects/test-slug/PROJECT.md" <<'EOF'
# PROJECT: test-slug
## Goal
seeded.
EOF
}

# --- Test 1: counter helpers increment, get, reset round-trip ----------
init_sandbox "helpers"
source "$LIB"
sb_inc_wiki_writes "test-slug"
sb_inc_wiki_writes "test-slug"
sb_inc_wiki_writes "test-slug"
[ "$(sb_get_wiki_writes "test-slug")" = "3" ] || fail "helpers: expected 3, got $(sb_get_wiki_writes "test-slug")"
sb_reset_wiki_writes "test-slug"
[ "$(sb_get_wiki_writes "test-slug")" = "0" ] || fail "helpers: expected 0 after reset"
# Corrupt-file recovery: write garbage, get should return 0
echo "not-a-number" > "$BRAIN_DIR/projects/test-slug/.wiki-writes"
[ "$(sb_get_wiki_writes "test-slug")" = "0" ] || fail "helpers: garbage should parse as 0"
pass "counter helpers increment/get/reset + corruption-safe"

echo "ALL PASS"
