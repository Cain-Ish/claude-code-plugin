#!/bin/bash
# Smoke test for scripts/validate-proposal.sh.
# Builds an isolated BRAIN_DIR under a temp folder, drops in fixture proposals,
# and asserts that valid ones pass and invalid ones are rejected.
# Usage: bash tests/test-validate-proposal.sh

set -u

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/validate-proposal.sh"
TMPDIR_BASE="${TMPDIR:-/tmp}"
SANDBOX=$(mktemp -d "$TMPDIR_BASE/second-brain-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0

run_case() {
  local name="$1" expected_exit="$2"
  local actual_exit
  HOME="$SANDBOX" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPT" >"$SANDBOX/out" 2>&1
  actual_exit=$?
  if [ "$actual_exit" = "$expected_exit" ]; then
    PASS=$((PASS + 1))
    echo "  PASS  $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL  $name (exit=$actual_exit expected=$expected_exit)"
    sed 's/^/        /' "$SANDBOX/out"
  fi
}

setup_brain() {
  rm -rf "$SANDBOX/.second-brain"
  mkdir -p "$SANDBOX/.second-brain"
}

write_friction() {
  local ts="$1" sid="$2"
  jq -nc --arg t "$ts" --arg s "$sid" \
    '{timestamp:$t, session_id:$s, type:"rejection", prompt:"sample friction signal"}' \
    >> "$SANDBOX/.second-brain/friction-log.jsonl"
}

write_proposal() {
  cat > "$SANDBOX/.second-brain/.improve-proposal.json"
}

echo "test-validate-proposal.sh"
echo "-------------------------"

# Case 1: well-formed proposal with two distinct sessions → should pass
setup_brain
write_friction "2026-04-26T09:00:00Z" "sess-a"
write_friction "2026-04-26T10:00:00Z" "sess-b"
write_proposal <<JSON
{
  "title": "Reduce retries on transient errors",
  "description": "Add retry-aware logging.",
  "evidence": [
    {"type": "friction", "timestamp": "2026-04-26T09:00:00Z", "session_id": "sess-a", "signal": "again"},
    {"type": "friction", "timestamp": "2026-04-26T10:00:00Z", "session_id": "sess-b", "signal": "wrong"}
  ],
  "changes": [
    {"file": "$PLUGIN_ROOT/scripts/log-friction.sh", "action": "modify", "description": "tighten regex"}
  ],
  "measurable_impact": "fewer redundant log entries",
  "risk_assessment": "none"
}
JSON
run_case "valid: 2 distinct sessions, in-tree change" 0

# Case 2: same session cited twice (recurrence not proven) → should fail
setup_brain
write_friction "2026-04-26T09:00:00Z" "sess-a"
write_proposal <<JSON
{
  "title": "X", "description": "Y",
  "evidence": [
    {"type": "friction", "timestamp": "2026-04-26T09:00:00Z", "session_id": "sess-a", "signal": "again"},
    {"type": "friction", "timestamp": "2026-04-26T09:00:00Z", "session_id": "sess-a", "signal": "again"}
  ],
  "changes": [{"file": "$PLUGIN_ROOT/scripts/log-friction.sh", "action": "modify", "description": "x"}],
  "measurable_impact": "x", "risk_assessment": "none"
}
JSON
run_case "reject: same session and timestamp twice" 1

# Case 3: change targets a file outside plugin root → should fail
setup_brain
write_friction "2026-04-26T09:00:00Z" "sess-a"
write_friction "2026-04-26T10:00:00Z" "sess-b"
write_proposal <<JSON
{
  "title": "X", "description": "Y",
  "evidence": [
    {"type": "friction", "timestamp": "2026-04-26T09:00:00Z", "session_id": "sess-a", "signal": "x"},
    {"type": "friction", "timestamp": "2026-04-26T10:00:00Z", "session_id": "sess-b", "signal": "y"}
  ],
  "changes": [{"file": "/etc/passwd", "action": "modify", "description": "noop"}],
  "measurable_impact": "x", "risk_assessment": "none"
}
JSON
run_case "reject: target outside plugin root" 1

# Case 4: change targets in-tree file using Windows-style backslashes → should pass
setup_brain
write_friction "2026-04-26T09:00:00Z" "sess-a"
write_friction "2026-04-26T10:00:00Z" "sess-b"
WIN_PATH=$(printf '%s' "$PLUGIN_ROOT/scripts/log-friction.sh" | sed 's|/|\\\\|g')
write_proposal <<JSON
{
  "title": "X", "description": "Y",
  "evidence": [
    {"type": "friction", "timestamp": "2026-04-26T09:00:00Z", "session_id": "sess-a", "signal": "x"},
    {"type": "friction", "timestamp": "2026-04-26T10:00:00Z", "session_id": "sess-b", "signal": "y"}
  ],
  "changes": [{"file": "$WIN_PATH", "action": "modify", "description": "x"}],
  "measurable_impact": "x", "risk_assessment": "none"
}
JSON
run_case "accept: in-tree path with backslashes (Windows-style)" 0

# Case 5: missing required field → should fail
setup_brain
write_proposal <<JSON
{"title": "X", "description": "Y", "evidence": []}
JSON
run_case "reject: missing 'changes' field" 1

# Case 6: attempts to modify plugin.json version → should fail
setup_brain
write_friction "2026-04-26T09:00:00Z" "sess-a"
write_friction "2026-04-26T10:00:00Z" "sess-b"
write_proposal <<JSON
{
  "title": "Bump", "description": "Y",
  "evidence": [
    {"type": "friction", "timestamp": "2026-04-26T09:00:00Z", "session_id": "sess-a", "signal": "x"},
    {"type": "friction", "timestamp": "2026-04-26T10:00:00Z", "session_id": "sess-b", "signal": "y"}
  ],
  "changes": [{"file": "$PLUGIN_ROOT/.claude-plugin/plugin.json", "action": "modify", "description": "bump version field"}],
  "measurable_impact": "x", "risk_assessment": "none"
}
JSON
run_case "reject: targets plugin.json version" 1

echo "-------------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
