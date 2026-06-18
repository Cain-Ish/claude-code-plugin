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

# --- Phase B: registration records root_path (+ parent for a sub-project) ---
# Build a monorepo in a temp dir so session-load writes the record end-to-end.
MONO=$(mktemp -d)
mkdir -p "$MONO/mono/packages/api"
( cd "$MONO/mono" && git init -q )
printf 'packages:\n  - "packages/*"\n' > "$MONO/mono/pnpm-workspace.yaml"

# Verify sb_detect_project produces the right slug/parent (sources lib.sh in a subshell).
read -r SLUG PARENT ROOTP < <(
  ( . "$PLUGIN_ROOT/scripts/lib.sh"
    cd "$MONO/mono/packages/api" && sb_detect_project "$PWD" ) \
  | awk -F'\t' '{print $1, $2, $3}'
)
[ "$SLUG" = "mono__api" ]  && pass "detect child slug"  || fail "detect child slug ($SLUG)"
[ "$PARENT" = "mono" ]     && pass "detect child parent" || fail "detect child parent ($PARENT)"

# Drive session-load with a fresh sandbox + CLAUDE_PROJECT_DIR pointing at the child.
init_sandbox "monorepo-child"
: > "$BRAIN_DIR/projects.jsonl"
export CLAUDE_PROJECT_DIR="$MONO/mono/packages/api"
jq -nc --arg cwd "$MONO/mono/packages/api" \
  '{session_id:"x", cwd:$cwd, hook_event_name:"SessionStart"}' \
  | bash "$SCRIPT" >/dev/null 2>&1
unset CLAUDE_PROJECT_DIR

REC=$(jq -c --arg s "mono__api" 'select(.slug==$s)' "$BRAIN_DIR/projects.jsonl" 2>/dev/null | head -1)
echo "$REC" | jq -e '.parent=="mono" and (.root_path|test("packages/api$"))' >/dev/null \
  && pass "record has parent+root_path" || fail "record missing parent/root_path: $REC"

rm -rf "$MONO"

# --- Phase C: session-load records git_remote, and clears a stale parent on de-parenting ---
. "$PLUGIN_ROOT/scripts/lib.sh"   # for sb_git_remote in this test
GR=$(sb_git_remote "$PLUGIN_ROOT")   # this repo HAS an origin remote
[ -n "$GR" ] && pass "sb_git_remote reads origin" || fail "sb_git_remote returned empty for a repo with a remote"
[ -z "$(sb_git_remote "$TMP")" ] && pass "sb_git_remote empty for non-repo" || fail "sb_git_remote should be empty for a non-repo dir"

# de-parenting: a record that WAS a sub-project, re-registered from a dir with no parent → parent removed
init_sandbox "deparent"
printf '%s\n' '{"slug":"test-project","name":"test-project","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0,"parent":"oldroot","root_path":"/old/path"}' > "$BRAIN_DIR/projects.jsonl"
run   # run() drives session-load with cwd = test-project (a plain dir, no workspace manifest → no parent)
PARENT_AFTER=$(jq -r --arg s test-project 'select(.slug==$s)|.parent // "ABSENT"' "$BRAIN_DIR/projects.jsonl" | head -1)
[ "$PARENT_AFTER" = "ABSENT" ] && pass "stale parent cleared on de-parenting" || fail "stale parent not cleared (got: $PARENT_AFTER)"

echo
echo "ALL PASS"
