#!/bin/bash
# Tests that session-load.sh registration-check uses jq (not grep) so a
# pretty-printed `projects.jsonl` doesn't trigger a duplicate registration.
# The old `grep -q "\"slug\":\"X\""` pattern false-negatived on pretty-
# printed entries with whitespace after the colon.
set -u
PLUGIN_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/session-load.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

init_sandbox() {
  SANDBOX="$TMP/$1"
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/.second-brain/projects" "$SANDBOX/repo/test-project"
  export HOME="$SANDBOX"
  export BRAIN_DIR="$SANDBOX/.second-brain"
  cd "$SANDBOX/repo/test-project"
}

run() {
  jq -nc --arg cwd "$SANDBOX/repo/test-project" \
    '{session_id:"x", cwd:$cwd, hook_event_name:"SessionStart"}' \
    | bash "$SCRIPT" >/dev/null 2>&1
}

count_entries_for() {  # $1 = slug
  jq -se --arg s "$1" 'map(select(.slug == $s)) | length' "$BRAIN_DIR/projects.jsonl" 2>/dev/null
}

# --- Test 1: pre-existing pretty-printed entry → registration check
# membership-matches it; no duplicate appended.
init_sandbox "pretty-printed"
cat > "$BRAIN_DIR/projects.jsonl" <<'EOF'
{
  "slug": "test-project",
  "name": "test-project",
  "last_session_iso": "2026-05-01T00:00:00Z",
  "hot_byte_count": 0
}
EOF
run
COUNT=$(count_entries_for "test-project")
[ "$COUNT" = "1" ] || fail "pretty-printed entry: expected 1, got $COUNT (duplicate registration)"
pass "pretty-printed entry: no duplicate registration"

# --- Test 2: pre-existing single-line JSONL entry → same result.
init_sandbox "jsonl-singleline"
echo '{"slug":"test-project","name":"test-project","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0}' \
  > "$BRAIN_DIR/projects.jsonl"
run
COUNT=$(count_entries_for "test-project")
[ "$COUNT" = "1" ] || fail "single-line JSONL: expected 1, got $COUNT"
pass "single-line JSONL: no duplicate registration"

# --- Test 3: empty projects.jsonl → new entry appended exactly once.
init_sandbox "empty"
: > "$BRAIN_DIR/projects.jsonl"
run
COUNT=$(count_entries_for "test-project")
[ "$COUNT" = "1" ] || fail "empty file: expected 1, got $COUNT"
pass "empty projects.jsonl: appends new entry once"

# --- Test 4: missing projects.jsonl → no error; PROJECT.md still created.
init_sandbox "missing"
run
[ -f "$BRAIN_DIR/projects/test-project/PROJECT.md" ] \
  || fail "missing-file: PROJECT.md should still be created"
pass "missing projects.jsonl: PROJECT.md still created, no error"

echo
echo "ALL PASS"
