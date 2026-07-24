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
TS_BRAIN=$(mktemp -d)
trap 'rm -rf "$SCOPE_BRAIN" "$TS_BRAIN"' EXIT

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

# --- v2.10.0 tool-scope guard (HarnessAudit sar_tool) ---
# Tool-scope is opt-in: users must declare an allowlist in persona-rules.json.
# The default plugin rules ship with tool_scope.enabled=false (zero surprise).
# These tests use a custom rules file written into an isolated brain dir.

cat > "$TS_BRAIN/persona-rules.json" <<'EOF'
{
  "tool_scope": {
    "enabled": true,
    "allowlist": ["Read", "Bash", "Edit", "Write", "Glob", "Grep"]
  },
  "rules": []
}
EOF

# Test 14: out-of-scope tool (WebFetch not in allowlist) → ask
out=$(BRAIN_DIR="$TS_BRAIN" \
  echo '{"tool_name":"WebFetch","tool_input":{"url":"https://x"},"session_id":"ts1"}' \
  | BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "out-of-scope WebFetch should ask (got: $out)"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("tool scope|not in the declared|allowlist")' >/dev/null \
  || fail "out-of-scope tool ask reason should mention tool scope (got: $out)"
pass "tool-scope: out-of-scope WebFetch asks"

# Test 15: in-scope tool (Read on /tmp, which is in resource scope by default) → silent
out=$(BRAIN_DIR="$TS_BRAIN" \
  echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"},"session_id":"ts1"}' \
  | BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "in-scope Read should be silent (got: $out)"
pass "tool-scope: in-scope tool silent"

# Test 16: SB_TOOL_SCOPE=off kill switch
out=$(SB_TOOL_SCOPE=off BRAIN_DIR="$TS_BRAIN" \
  echo '{"tool_name":"WebFetch","tool_input":{"url":"https://x"},"session_id":"ts1"}' \
  | SB_TOOL_SCOPE=off BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "SB_TOOL_SCOPE=off should suppress tool-scope guard (got: $out)"
pass "tool-scope: SB_TOOL_SCOPE=off honored"

# Test 17: SB_TOOL_SCOPE_EXTRA extends the allowlist (colon-separated like PATH)
out=$(SB_TOOL_SCOPE_EXTRA="WebFetch:Task" BRAIN_DIR="$TS_BRAIN" \
  echo '{"tool_name":"WebFetch","tool_input":{"url":"https://x"},"session_id":"ts1"}' \
  | SB_TOOL_SCOPE_EXTRA="WebFetch:Task" BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "SB_TOOL_SCOPE_EXTRA should extend tool allowlist (got: $out)"
pass "tool-scope: SB_TOOL_SCOPE_EXTRA extends allowlist"

# Test 18: audit log captures tool-scope verdict
[ -f "$TS_BRAIN/audit-log.jsonl" ] || fail "audit-log.jsonl should be written after tool-scope verdict"
grep -q '"rule":"tool-scope-out-of-scope"' "$TS_BRAIN/audit-log.jsonl" \
  || fail "audit-log should contain tool-scope-out-of-scope entries"
pass "tool-scope: audit-log captures verdicts"

# Test 19: tool_scope disabled → no gating even for unknown tool
cat > "$TS_BRAIN/persona-rules.json" <<'EOF'
{
  "tool_scope": { "enabled": false, "allowlist": ["Read"] },
  "rules": []
}
EOF
out=$(BRAIN_DIR="$TS_BRAIN" \
  echo '{"tool_name":"WebFetch","tool_input":{"url":"https://x"},"session_id":"ts2"}' \
  | BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "tool_scope.enabled=false should not gate (got: $out)"
pass "tool-scope: disabled means no gating"

# Test 20 (MAJOR M3 regression): a rewrite rule whose match_command contains
# a pipe character must NOT silently zero-out the command. With the old
# `sed -E "s|$match_cmd|$replace|g"` the pipe terminates the s command and
# sed errors → NEW_CMD becomes "". The rewrite then passes empty string
# back to Claude as updatedInput.command, silently corrupting the call.
cat > "$TS_BRAIN/persona-rules.json" <<'EOF'
{
  "rules": [
    {
      "name": "alt-pipe-rewrite",
      "tool": "Bash",
      "match_command": "(foo|bar)",
      "action": "rewrite",
      "replace": "baz",
      "reason": "test"
    }
  ]
}
EOF
out=$(BRAIN_DIR="$TS_BRAIN" \
  echo '{"tool_name":"Bash","tool_input":{"command":"echo foo"},"session_id":"m3"}' \
  | BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT")
new_cmd=$(echo "$out" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null)
[ -n "$new_cmd" ] || fail "rewrite with pipe-in-pattern produced empty command (M3 regression): $out"
echo "$new_cmd" | grep -q 'baz' \
  || fail "rewrite with pipe-in-pattern did not substitute (got: $new_cmd)"
pass "rewrite: match_command with | is handled correctly (M3 regression)"

# Test 21 (Windows form): C:\ out-of-scope path ASKS (resource-scope) ------
# Before the fix a 'C:\…' path matched neither /* nor ~/* so persona-tool-guard
# treated it as CWD-relative and it trivially prefix-matched the "$CWD"
# allowlist entry → silent ALLOW (the dominant L1 boundary fail-open on
# Windows, the dev platform). cygpath is STUBBED so this runs on Linux/BSD CI.
# Regression lock: remove the CWD/PATH_INPUT normalization in
# persona-tool-guard.sh and this flips back to a silent allow (FAIL).
WINBIN=$(mktemp -d)
cat > "$WINBIN/cygpath" <<'EOF'
#!/bin/sh
p="$2"
case "$p" in
  [A-Za-z]:/*) d=$(printf '%s' "$p" | cut -c1 | tr 'A-Z' 'a-z'); r=$(printf '%s' "$p" | cut -c3-); printf '/%s%s\n' "$d" "$r" ;;
  *) printf '%s\n' "$p" ;;
esac
EOF
chmod +x "$WINBIN/cygpath"
cat > "$WINBIN/payload.json" <<'JSON'
{"tool_name":"Edit","tool_input":{"file_path":"C:\\Users\\attacker\\.aws\\credentials"},"cwd":"C:\\proj","session_id":"win1"}
JSON
out=$(BRAIN_DIR="$SCOPE_BRAIN" HOME="/c/Users/victim" PATH="$WINBIN:$PATH" bash "$SCRIPT" < "$WINBIN/payload.json")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "Windows C:\\ out-of-scope Edit should ASK (resource-scope fail-open on Windows): $out"
pass "resource-scope: Windows C:\\ out-of-scope path asks"

# Test 22: same Windows payload with lib.sh UNSOURCEABLE → the guard's inline
# fallback sb_normalize_path must keep the resource-scope check armed. That
# fallback branch was previously untested — drift between the inline copy and
# lib.sh's canonical would disarm the guard only in the lib-missing
# configuration, invisibly (panel finding). CLAUDE_PLUGIN_ROOT=/nonexistent
# also removes persona-rules.DEFAULT.json (the guard exits 0 with no rules at
# all — before ever reaching the scope check), so the rules must come from the
# USER file in BRAIN_DIR: that isolates exactly the lib-missing branch.
NOLIB_BRAIN=$(mktemp -d)
cp "$(dirname "$SCRIPT")/persona-rules.default.json" "$NOLIB_BRAIN/persona-rules.json"
out=$(BRAIN_DIR="$NOLIB_BRAIN" HOME="/c/Users/victim" CLAUDE_PLUGIN_ROOT=/nonexistent PATH="$WINBIN:$PATH" bash "$SCRIPT" < "$WINBIN/payload.json")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "lib.sh unsourceable: Windows out-of-scope Edit should still ASK via the inline fallback: $out"
pass "resource-scope: inline fallback (lib.sh unsourceable) still asks on Windows path"
rm -rf "$WINBIN" "$NOLIB_BRAIN"

# --- learned WARN rules (auto-armed by merge-persona-signals.sh) ---
# Test 23: a learned bash warn rule fires advisory additionalContext, sets NO
# permissionDecision (an explicit "allow" would auto-approve the call and
# bypass the user's permission prompts), and exits 0.
cat > "$TS_BRAIN/persona-rules.json" <<'EOF'
{
  "rules": [],
  "learned": [
    {"event":"bash","pattern":"npm install -g","action":"warn","message":"Learned: install project-local, not global."},
    {"event":"file","pattern":"src/generated/","action":"warn","message":"Learned: src/generated is build output; change the generator."}
  ]
}
EOF
out=$(BRAIN_DIR="$TS_BRAIN" \
  echo '{"tool_name":"Bash","tool_input":{"command":"npm install -g typescript"},"session_id":"w1"}' \
  | BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT") || fail "warn rule must exit 0"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("project-local")' >/dev/null \
  || fail "learned bash warn should emit its message as additionalContext (got: $out)"
echo "$out" | jq -e '.hookSpecificOutput | has("permissionDecision") | not' >/dev/null \
  || fail "warn must NOT set permissionDecision — advisory only (got: $out)"
pass "learned warn: bash rule fires advisory, allows, exits 0"

# Test 24: learned file warn rule matches Edit paths; bash-event rules don't.
out=$(BRAIN_DIR="$TS_BRAIN" \
  echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/u/proj/src/generated/api.ts"},"cwd":"/home/u/proj","session_id":"w2"}' \
  | BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT") || fail "file warn rule must exit 0"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("build output")' >/dev/null \
  || fail "learned file warn should emit advisory on matching Edit path (got: $out)"
echo "$out" | jq -e '.hookSpecificOutput | has("permissionDecision") | not' >/dev/null \
  || fail "file warn must NOT set permissionDecision (got: $out)"
# Non-matching input stays silent (advisory never fires spuriously).
out=$(BRAIN_DIR="$TS_BRAIN" \
  echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"w3"}' \
  | BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "non-matching command must stay silent with learned rules present (got: $out)"
pass "learned warn: file rule fires on Edit, non-matches silent"

# Test 25: warn verdicts land in the audit log like ask/deny/rewrite.
grep -q '"verdict":"warn"' "$TS_BRAIN/audit-log.jsonl" \
  || fail "audit-log should contain warn verdicts"
grep -q '"rule":"learned:bash:npm install -g"' "$TS_BRAIN/audit-log.jsonl" \
  || fail "audit-log should name the learned rule that fired"
pass "learned warn: verdicts audit-logged"

echo
echo "ALL PASS"
