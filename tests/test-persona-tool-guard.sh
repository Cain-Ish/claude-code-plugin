#!/bin/bash
# Tests for scripts/persona-tool-guard.sh — Layer 3 PreToolUse hook.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/persona-tool-guard.sh"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Test 1: 2>/dev/null gets stripped
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls foo 2>/dev/null"}}' | "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null \
  || fail "strip-silent-fallback: permission should be allow (got: $out)"
echo "$out" | jq -e '.hookSpecificOutput.updatedInput.command | contains("2>/dev/null") | not' >/dev/null \
  || fail "strip-silent-fallback: updatedInput.command should not contain 2>/dev/null"
pass "strip-silent-fallback"

# Test 2: force-push to main → ask
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' | "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "force-push-main should ask (got: $out)"
pass "force-push-main asks"

# Test 3: direct write to USER.md → ask
out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/x/.second-brain/USER.md","content":"foo"}}' | "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "write-USER.md should ask (got: $out)"
pass "write-USER.md asks"

# Test 4: harmless ls → silent
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | "$SCRIPT")
[ -z "$out" ] || fail "harmless Bash should be silent (got: $out)"
pass "harmless Bash silent"

# Test 5: kill switch
out=$(SB_PERSONA_GATE=off bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls 2>/dev/null\"}}' | '$SCRIPT'")
[ -z "$out" ] || fail "SB_PERSONA_GATE=off should suppress output"
pass "kill switch honored"

# Test 6: rm -rf → ask
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/foo"}}' | "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "rm -rf should ask (got: $out)"
pass "rm -rf asks"

echo
echo "ALL PASS"
