#!/bin/bash
# Tests for scripts/persona-tool-guard.sh — Layer 3 PreToolUse hook.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/persona-tool-guard.sh"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Test 1: 2>/dev/null gets stripped
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls foo 2>/dev/null"}}' | bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null \
  || fail "strip-silent-fallback: permission should be allow (got: $out)"
echo "$out" | jq -e '.hookSpecificOutput.updatedInput.command | contains("2>/dev/null") | not' >/dev/null \
  || fail "strip-silent-fallback: updatedInput.command should not contain 2>/dev/null"
pass "strip-silent-fallback"

# Test 2: force-push to main → ask
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' | bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "force-push-main should ask (got: $out)"
pass "force-push-main asks"

# Test 3: direct write to USER.md → ask
out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/x/.second-brain/USER.md","content":"foo"}}' | bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "write-USER.md should ask (got: $out)"
pass "write-USER.md asks"

# Test 4: harmless ls → silent
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | bash "$SCRIPT")
[ -z "$out" ] || fail "harmless Bash should be silent (got: $out)"
pass "harmless Bash silent"

# Test 5: kill switch
out=$(SB_PERSONA_GATE=off bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls 2>/dev/null\"}}' | '$SCRIPT'")
[ -z "$out" ] || fail "SB_PERSONA_GATE=off should suppress output"
pass "kill switch honored"

# Test 6: rm -rf → ask
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/foo"}}' | bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "rm -rf should ask (got: $out)"
pass "rm -rf asks"

# --- v2.9.0 Phase 2: hook self-protection ---
# Test 7: Edit to plugin script → ask (defends safety layer from
# injection-driven self-disable).
out=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/x/claude-code-plugin/scripts/lib.sh"}}' | bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "Edit to plugin script should ask (got: $out)"
pass "self-protection: plugin script edit asks"

out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/x/persona-rules.json","content":"{}"}}' | bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "Write to persona-rules.json should ask (got: $out)"
pass "self-protection: persona-rules edit asks"

# --- v2.9.0 Phase 3: resource-scope guard ---
# Set up an isolated brain dir so audit-log lands somewhere we can check.
SCOPE_BRAIN=$(mktemp -d)
trap 'rm -rf "$SCOPE_BRAIN"' EXIT

# Test 8: out-of-scope Edit (path not in CWD/~/.second-brain/~/knowledge/tmp)
out=$(BRAIN_DIR="$SCOPE_BRAIN" \
  echo '{"tool_name":"Edit","tool_input":{"file_path":"/etc/hosts"},"cwd":"/home/u/proj"}' \
  | BRAIN_DIR="$SCOPE_BRAIN" bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "out-of-scope Edit (/etc/hosts) should ask (got: $out)"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("resource scope|outside the project")' >/dev/null \
  || fail "out-of-scope ask reason should mention resource scope (got: $out)"
pass "resource-scope: out-of-scope Edit asks"

# Test 9: in-scope path (under CWD) → falls through to rule iteration → silent
out=$(BRAIN_DIR="$SCOPE_BRAIN" \
  echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/u/proj/src/foo.ts"},"cwd":"/home/u/proj"}' \
  | BRAIN_DIR="$SCOPE_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "in-scope CWD path should be silent (got: $out)"
pass "resource-scope: in-scope CWD path silent"

# Test 10: in-scope ~/knowledge/ → silent
out=$(BRAIN_DIR="$SCOPE_BRAIN" \
  echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$HOME/knowledge/wiki/x.md\"},\"cwd\":\"/home/u/proj\"}" \
  | BRAIN_DIR="$SCOPE_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "in-scope ~/knowledge path should be silent (got: $out)"
pass "resource-scope: ~/knowledge in scope"

# Test 11: SB_RESOURCE_SCOPE=off kill switch
out=$(SB_RESOURCE_SCOPE=off BRAIN_DIR="$SCOPE_BRAIN" \
  echo '{"tool_name":"Edit","tool_input":{"file_path":"/etc/hosts"},"cwd":"/home/u/proj"}' \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$SCOPE_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "SB_RESOURCE_SCOPE=off should suppress scope guard (got: $out)"
pass "resource-scope: SB_RESOURCE_SCOPE=off honored"

# Test 12: SB_RESOURCE_SCOPE_EXTRA extends allowlist
out=$(SB_RESOURCE_SCOPE_EXTRA="/etc" BRAIN_DIR="$SCOPE_BRAIN" \
  echo '{"tool_name":"Edit","tool_input":{"file_path":"/etc/hosts"},"cwd":"/home/u/proj"}' \
  | SB_RESOURCE_SCOPE_EXTRA="/etc" BRAIN_DIR="$SCOPE_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "SB_RESOURCE_SCOPE_EXTRA should extend scope (got: $out)"
pass "resource-scope: SB_RESOURCE_SCOPE_EXTRA extends allowlist"

# Test 13: audit log gets entries from guard verdicts
[ -f "$SCOPE_BRAIN/audit-log.jsonl" ] || fail "audit-log.jsonl should be written after a verdict"
grep -q '"hook":"persona-tool-guard.sh"' "$SCOPE_BRAIN/audit-log.jsonl" \
  || fail "audit-log should contain persona-tool-guard.sh entries"
grep -q '"rule":"resource-scope-out-of-scope"' "$SCOPE_BRAIN/audit-log.jsonl" \
  || fail "audit-log should contain resource-scope rule entries"
pass "resource-scope: audit-log captures verdicts"

echo
echo "ALL PASS"
