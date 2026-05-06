#!/bin/bash
# Tests for scripts/stop-extract.sh — Stop-hook orchestrator that extracts
# session deltas from the conversation transcript and merges them into
# PROJECT.md + wiki via merge-project-update.sh.
#
# We stub the `claude` binary on PATH so tests run without a live LLM.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$REPO_ROOT/scripts/stop-extract.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

init_sandbox() {
  local name="$1"
  SANDBOX="$TMP/$name"
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/.second-brain/projects/test-slug" \
           "$SANDBOX/.second-brain/wiki" \
           "$SANDBOX/repo/test-slug" \
           "$SANDBOX/path-stub" \
           "$SANDBOX/transcript"
  export HOME="$SANDBOX"
  cd "$SANDBOX/repo/test-slug" || fail "cd failed in $name"
  cat > "$SANDBOX/.second-brain/projects/test-slug/PROJECT.md" <<'EOF'
# PROJECT: test-slug

## Goal
seeded.

## State
seeded.

## Conventions
- conv 1

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
<!-- last_queried_wiki: -->
EOF
  cp "$SANDBOX/.second-brain/projects/test-slug/PROJECT.md" \
     "$SANDBOX/.second-brain/.session-baseline-test-slug.md"
}

seed_transcript_with_edit() {
  cat > "$SANDBOX/transcript/session.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/foo.ts","old_string":"a","new_string":"b"}}]}}
{"type":"user","message":{"role":"user","content":"thanks"}}
EOF
}

seed_transcript_qna_only() {
  cat > "$SANDBOX/transcript/session.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}
EOF
}

stub_claude_json() {
  local payload="$1"
  cat > "$SANDBOX/path-stub/claude" <<EOF
#!/bin/bash
# Stub: ignores args and stdin, emits fixed JSON.
cat <<JSON
$payload
JSON
EOF
  chmod +x "$SANDBOX/path-stub/claude"
  export PATH="$SANDBOX/path-stub:$PATH"
}

stub_claude_garbage() {
  cat > "$SANDBOX/path-stub/claude" <<'EOF'
#!/bin/bash
echo "not valid json at all"
EOF
  chmod +x "$SANDBOX/path-stub/claude"
  export PATH="$SANDBOX/path-stub:$PATH"
}

stop_payload() {
  jq -nc --arg sid "test-session" \
        --arg tp "$SANDBOX/transcript/session.jsonl" \
        --arg cwd "$SANDBOX/repo/test-slug" \
        '{session_id:$sid, transcript_path:$tp, cwd:$cwd, hook_event_name:"Stop"}'
}

ORIG_PATH="$PATH"
restore_path() { export PATH="$ORIG_PATH"; }

# --- Test 1: substantive transcript + claude returns valid JSON → merge fires.
init_sandbox "happy"
seed_transcript_with_edit
stub_claude_json '{"recent_decisions":["use Haiku for extraction"],"open_blockers":[],"cross_refs":["new-page"],"files_touched":["src/foo.ts"]}'
stop_payload | "$SCRIPT" >/dev/null 2>&1
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
grep -q "use Haiku for extraction" "$PROJ" || fail "happy: decision not merged into PROJECT.md"
grep -q "\[\[new-page\]\]" "$PROJ" || fail "happy: cross-ref not merged"
[ -f "$SANDBOX/.second-brain/wiki/new-page.md" ] || fail "happy: wiki stub not created"
pass "happy path: claude returns JSON → merge fires"
restore_path

# --- Test 2: Q&A-only transcript → predicate skips, PROJECT.md untouched.
init_sandbox "qna"
seed_transcript_qna_only
stub_claude_json '{"recent_decisions":["should-not-merge"],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
ORIG_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
stop_payload | "$SCRIPT" >/dev/null 2>&1
NEW_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
[ "$ORIG_HASH" = "$NEW_HASH" ] || fail "qna: expected no merge but PROJECT.md changed"
pass "Q&A-only transcript: predicate skips extraction"
restore_path

# --- Test 3: claude unavailable → fallback is silent (no "files this session" noise).
init_sandbox "no-claude"
seed_transcript_with_edit
# Remove claude from PATH so command -v claude fails
SAVED_PATH="$PATH"
export PATH=$(echo "$PATH" | tr ':' '\n' | while read -r d; do
  [ -x "$d/claude" ] || printf '%s:' "$d"
done | sed 's/:$//')
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
ORIG_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
stop_payload | "$SCRIPT" >/dev/null 2>&1
export PATH="$SAVED_PATH"
NEW_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
[ "$ORIG_HASH" = "$NEW_HASH" ] || fail "no-claude: PROJECT.md should be unchanged (no file-list noise)"
pass "claude unavailable: fallback is silent, no noise in decisions"

# --- Test 4: claude returns garbage → fail-soft, PROJECT.md untouched, exit 0.
init_sandbox "garbage"
seed_transcript_with_edit
stub_claude_garbage
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
ORIG_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
stop_payload | "$SCRIPT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "garbage: expected exit 0 (fail-soft), got $rc"
pass "claude returns garbage: fail-soft, exit 0"
restore_path

# --- Test 5: missing transcript file → exit 0, no crash.
init_sandbox "missing-transcript"
stub_claude_json '{}'
PAYLOAD=$(jq -nc --arg tp "/nonexistent/transcript.jsonl" --arg cwd "$SANDBOX/repo/test-slug" \
  '{session_id:"x", transcript_path:$tp, cwd:$cwd, hook_event_name:"Stop"}')
echo "$PAYLOAD" | "$SCRIPT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "missing-transcript: expected exit 0, got $rc"
pass "missing transcript: fail-soft, exit 0"
restore_path

# --- Test 6: malformed Stop payload on stdin → exit 0, no crash.
init_sandbox "bad-stdin"
echo "not json" | "$SCRIPT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "bad-stdin: expected exit 0, got $rc"
pass "malformed Stop payload: fail-soft, exit 0"

echo "ALL PASS"
