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
[ -n "$REC" ] && echo "$REC" | jq -e '.parent=="mono" and (.root_path|test("packages/api$"))' >/dev/null \
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

# --- Phase D: bookkeeping rewrite keeps projects.jsonl LINE-BY-LINE parseable ---
# project-registry.ts loadRegistry() reads projects.jsonl one line at a time and
# JSON.parses each line (malformed lines silently skipped). The SessionStart
# bookkeeping rewrite used `jq` without -c, pretty-printing every record across
# ~8 lines, so the reader returned [] and project scoping / dream family filters
# / search tiering all ran registry-blind. This asserts the CONSUMER's contract:
# after a rewrite, every non-empty line is a complete JSON object. Regression
# lock — drop the -c in session-load.sh and this fails (a lone "{" line).
init_sandbox "compact-after-rewrite"
cat > "$BRAIN_DIR/projects.jsonl" <<'EOF'
{
  "slug": "test-project",
  "name": "test-project",
  "last_session_iso": "2026-05-01T00:00:00Z",
  "hot_byte_count": 0
}
{
  "slug": "other-project",
  "name": "other-project",
  "last_session_iso": "2026-04-01T00:00:00Z",
  "hot_byte_count": 0
}
EOF
run
LINE_BAD=0; LINE_N=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  LINE_N=$((LINE_N + 1))
  [ -n "$line" ] && printf '%s' "$line" | jq -e 'type == "object" and (.slug | type == "string")' >/dev/null 2>&1 \
    || LINE_BAD=1
done < "$BRAIN_DIR/projects.jsonl"
[ "$LINE_BAD" = "0" ] \
  || fail "projects.jsonl has a line that is not a complete JSON object (registry reader would return []) — rewrite pretty-printed it"
[ "$LINE_N" = "2" ] \
  || fail "expected 2 compact record lines after rewrite, got $LINE_N"
pass "bookkeeping rewrite keeps projects.jsonl one compact object per line (registry-readable)"

# Both records must survive the rewrite (self-heal, not lose the non-active one).
count_entries_for "test-project" | grep -q '^1$' || fail "active record lost/duplicated after rewrite"
count_entries_for "other-project" | grep -q '^1$' || fail "non-active record lost after rewrite"
pass "rewrite preserves all records (self-heals pretty-printed → compact)"

# --- Phase E: corrupt line MID-file → rewrite SKIPS, registry left INTACT ---
# jq dies at the corrupt line after emitting the records before it. If the
# rewrite gate blessed that partial output (the single-stage `jq | tr > f`
# pipeline masked jq's exit code behind tr's — panel-confirmed by live repro),
# every record AFTER the bad line would be silently truncated away — and never
# re-registered, since registration only runs when PROJECT.md is absent. Safe
# behavior: skip the rewrite, leave the file byte-intact. Regression lock:
# re-pipe jq straight through tr (single stage) and this fails.
init_sandbox "corrupt-line-no-truncate"
cat > "$BRAIN_DIR/projects.jsonl" <<'EOF'
{"slug":"test-project","name":"test-project","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0}
GARBAGE not json
{"slug":"other-project","name":"other-project","last_session_iso":"2026-04-01T00:00:00Z","hot_byte_count":0}
EOF
mkdir -p "$BRAIN_DIR/projects/test-project"
printf '# PROJECT: test-project\n' > "$BRAIN_DIR/projects/test-project/PROJECT.md"
run
grep -q '^GARBAGE not json$' "$BRAIN_DIR/projects.jsonl" \
  || fail "corrupt registry was rewritten — expected skip-and-leave-intact"
grep -q '"slug":"other-project"' "$BRAIN_DIR/projects.jsonl" \
  || fail "record AFTER the corrupt line was truncated away (the panel-confirmed data-loss regression)"
LINES=$(grep -c . "$BRAIN_DIR/projects.jsonl")
[ "$LINES" = "3" ] || fail "registry line count changed (expected 3 intact lines, got $LINES)"
pass "corrupt mid-file line → rewrite skipped, registry left byte-intact (no truncation)"

# --- Phase F (D120/D139): a torn line in projects.jsonl must not fool the
# membership check into re-registering an ALREADY-registered slug. `jq -se`
# aborts on the torn line with a parse error (not "not found"); the old code
# treated any non-zero exit the same way, so a torn line anywhere in the
# registry made an already-registered project look absent and appended a
# duplicate row (PROJECT.md is created fresh here, so the registration block
# actually runs).
init_sandbox "torn-line-membership"
printf '%s\n' '{"slug":"test-project","name":"test-project","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0}' \
  > "$BRAIN_DIR/projects.jsonl"
printf '{"slug":"partial' >> "$BRAIN_DIR/projects.jsonl"   # no trailing newline: genuine crash-mid-write tear
run
# A duplicate append lands on the SAME physical line as the (newline-less) torn
# line, so both count_entries_for's `jq -se` AND a per-line-tolerant `fromjson?`
# read would see that merged line as unparseable and silently miss the second
# registration. Count raw occurrences of the slug key instead — robust to where
# the duplicate landed.
COUNT=$(grep -o '"slug":"test-project"' "$BRAIN_DIR/projects.jsonl" | wc -l | tr -d ' ')
[ "$COUNT" = "1" ] || fail "torn-line registry: expected 1 occurrence of the slug (no duplicate), got $COUNT"
pass "torn line in projects.jsonl does not cause a duplicate registration"
grep -q 'torn line' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  || fail "torn line must be logged via sb_log_error"
pass "torn line in projects.jsonl is logged once via sb_log_error"

echo
echo "ALL PASS"
