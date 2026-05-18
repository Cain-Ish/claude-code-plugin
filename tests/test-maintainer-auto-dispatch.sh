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

# --- Helper: invoke session-load.sh with a fake SessionStart payload -----
run_session_load() {
  local slug="${1:-test-slug}"
  jq -nc --arg cwd "$SANDBOX/repo/$slug" \
    '{session_id:"x", cwd:$cwd, hook_event_name:"SessionStart"}' \
    | bash "$SCRIPT" 2>/dev/null
}

# --- Test 2: counter below threshold → no banner ------------------------
init_sandbox "below-threshold"
source "$LIB"
sb_set_wiki_writes "test-slug" 2
unset SB_MAINTAINER_AUTO SB_MAINTAINER_THRESHOLD SB_MAINTAINER_MAX_FAILS
OUT=$(run_session_load)
echo "$OUT" | grep -q "BLOCKING REQUIREMENT" && fail "below-threshold: should NOT emit banner"
[ ! -f "$SANDBOX/.second-brain/projects/test-slug/.maintainer-dispatched" ] || \
  fail "below-threshold: dispatched marker should not exist"
pass "below threshold (2 < 3): no banner emitted"

# --- Test 3: counter at threshold → banner + dispatched marker -----------
init_sandbox "at-threshold"
source "$LIB"
sb_set_wiki_writes "test-slug" 3
unset SB_MAINTAINER_AUTO SB_MAINTAINER_THRESHOLD SB_MAINTAINER_MAX_FAILS
OUT=$(run_session_load)
echo "$OUT" | grep -q "BLOCKING REQUIREMENT" || fail "at-threshold: banner missing"
echo "$OUT" | grep -q "knowledge-maintainer" || fail "at-threshold: agent name missing"
[ -f "$SANDBOX/.second-brain/projects/test-slug/.maintainer-dispatched" ] || \
  fail "at-threshold: dispatched marker should be created"
pass "at threshold (3 >= 3): banner emitted + .maintainer-dispatched created"

# --- Test 4: SB_MAINTAINER_AUTO=off suppresses banner -------------------
init_sandbox "kill-switch"
source "$LIB"
sb_set_wiki_writes "test-slug" 10
export SB_MAINTAINER_AUTO=off
OUT=$(run_session_load)
unset SB_MAINTAINER_AUTO
echo "$OUT" | grep -q "BLOCKING REQUIREMENT" && fail "kill-switch: should not emit banner"
[ ! -f "$SANDBOX/.second-brain/projects/test-slug/.maintainer-dispatched" ] || \
  fail "kill-switch: dispatched marker should not exist"
pass "SB_MAINTAINER_AUTO=off suppresses dispatch even at counter=10"

# --- Test 5: SB_MAINTAINER_THRESHOLD override --------------------------
init_sandbox "threshold-override"
source "$LIB"
sb_set_wiki_writes "test-slug" 2
export SB_MAINTAINER_THRESHOLD=2
OUT=$(run_session_load)
unset SB_MAINTAINER_THRESHOLD
echo "$OUT" | grep -q "BLOCKING REQUIREMENT" || fail "threshold-override: banner missing at count=2 threshold=2"
pass "SB_MAINTAINER_THRESHOLD=2 triggers at counter=2"

echo "ALL PASS"
