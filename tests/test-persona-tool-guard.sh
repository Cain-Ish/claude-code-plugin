#!/bin/bash
# Tests for scripts/persona-tool-guard.sh — Layer 3 PreToolUse hook.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/persona-tool-guard.sh"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Test 1 (INVERTED 2026-08-23): 2>/dev/null is ADVISORY, never rewritten, never auto-allowed.
# The old oracle asserted the shipped default REWROTE the command and emitted "allow". That
# rewrite was a blind sed over the whole string (it turned `grep -rn "2>/dev/null" x` into
# `grep -rn "" x` and altered heredoc bodies), and because a rewrite must emit "allow", any
# dangerous command with a trailing 2>/dev/null skipped the ask rules. Now: additionalContext
# only, no permissionDecision, command untouched.
T1_BRAIN=$(mktemp -d)
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls foo 2>/dev/null"},"session_id":"t1"}' | BRAIN_DIR="$T1_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("fail loud")' >/dev/null \
  || fail "strip-silent-fallback: should be an advisory (additionalContext), got: $out"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == null and .hookSpecificOutput.updatedInput == null' >/dev/null \
  || fail "strip-silent-fallback: must NOT emit a permissionDecision or rewrite the command (got: $out)"
pass "strip-silent-fallback is advisory-only (no rewrite, no allow)"

# Test 1b: PRECEDENCE — a dangerous command does not get weaker by appending 2>/dev/null.
# Before the fix: `rm -rf x 2>/dev/null` -> allow (rewrite rule matched first, loop exited),
# `rm -rf x` -> ask. Most-restrictive verdict must win regardless of rule order.
for dangerous in 'rm -rf /home/u/important 2>/dev/null' 'git push --force origin main 2>/dev/null'; do
  out=$(jq -nc --arg c "$dangerous" '{tool_name:"Bash",tool_input:{command:$c},session_id:"t1b"}' | BRAIN_DIR="$T1_BRAIN" bash "$SCRIPT")
  [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
    || fail "precedence: '$dangerous' must be ask, got: $out"
done
pass "precedence: ask rules win over the 2>/dev/null advisory (no auto-allow via redirect)"
rm -rf "$T1_BRAIN"

# Test 2: force-push to main → ask
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "force-push-main should ask (got: $out)"
pass "force-push-main asks"

# Test 3: direct write to USER.md → ask
out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/x/.second-brain/USER.md","content":"foo"}}' | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "rm -rf should ask (got: $out)"
pass "rm -rf asks"

# --- v2.9.0 Phase 2: hook self-protection ---
# Test 7: Edit to plugin script → ask (defends safety layer from
# injection-driven self-disable).
out=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/x/claude-code-plugin/scripts/lib.sh"}}' | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "Edit to plugin script should ask (got: $out)"
pass "self-protection: plugin script edit asks"

out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/x/persona-rules.json","content":"{}"}}' | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "out-of-scope Edit (/etc/hosts) should ask (got: $out)"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("resource scope|outside the project")' >/dev/null \
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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "out-of-scope WebFetch should ask (got: $out)"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("tool scope|not in the declared|allowlist")' >/dev/null \
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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("project-local")' >/dev/null \
  || fail "learned bash warn should emit its message as additionalContext (got: $out)"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput | has("permissionDecision") | not' >/dev/null \
  || fail "warn must NOT set permissionDecision — advisory only (got: $out)"
pass "learned warn: bash rule fires advisory, allows, exits 0"

# Test 24: learned file warn rule matches Edit paths; bash-event rules don't.
out=$(BRAIN_DIR="$TS_BRAIN" \
  echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/u/proj/src/generated/api.ts"},"cwd":"/home/u/proj","session_id":"w2"}' \
  | BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT") || fail "file warn rule must exit 0"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("build output")' >/dev/null \
  || fail "learned file warn should emit advisory on matching Edit path (got: $out)"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput | has("permissionDecision") | not' >/dev/null \
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

# --- Session Intent Spine: implement → verify phase flip on a verification command ---
SPINE_BRAIN=$(mktemp -d)
mkdir -p "$SPINE_BRAIN/.injected"

# Test 26: a test-shaped Bash command flips implement → verify (guard verdict untouched).
printf 'implement' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"npx vitest run prose-locks"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "verify" ] \
  || fail "vitest command should flip phase implement -> verify"
pass "spine: verification command flips phase to verify"

# Test 27: a non-verification command leaves the phase alone.
printf 'implement' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"git status"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "implement" ] \
  || fail "non-verify command must not flip the phase"
pass "spine: non-verification command leaves phase untouched"

# Test 28: no phase file → the guard never creates one (plan-first-nudge owns creation).
rm -f "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"npx vitest run"},"session_id":"sess-flip"}
JSON
[ -f "$SPINE_BRAIN/.injected/sess-flip.phase" ] \
  && fail "guard must not create the phase file"
pass "spine: absent phase file is never created here"

# Test 29: SB_INTENT_SPINE=off leaves the phase alone (kill switch checked first).
printf 'implement' > "$SPINE_BRAIN/.injected/sess-flip.phase"
SB_INTENT_SPINE=off BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"npx vitest run"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "implement" ] \
  || fail "SB_INTENT_SPINE=off must not flip the phase"
pass "spine: SB_INTENT_SPINE=off suppresses the flip"

# Test 30: first-token anchoring — a test-runner NAME inside an argument must not
# flip. `cat .eslintrc.json` (eslint substring) and a commit message carrying a
# test path were the live false-flip class.
printf 'implement' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"cat .eslintrc.json"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "implement" ] \
  || fail "cat .eslintrc.json must NOT flip the phase (substring false positive)"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"git commit -m \"cleanup tests/test-foo.sh comment\""},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "implement" ] \
  || fail "a commit message mentioning a test path must NOT flip the phase"
pass "spine: argument mentions of runners/test paths never flip (first-token anchor)"

# Test 31: env-assignment prefixes are skipped before anchoring; npm script forms flip.
printf 'implement' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"SB_X=1 bash tests/test-foo.sh"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "verify" ] \
  || fail "SB_X=1 bash tests/test-foo.sh MUST flip (env assignment skipped)"
printf 'implement' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"npm run test:unit"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "verify" ] \
  || fail "npm run test:unit MUST flip"
pass "spine: env-prefixed test run + npm run test:* flip"

# Test 33: quote-aware splitting — separators INSIDE quoted text never form spans,
# and subshell parens never glue to tokens (both reviewer-reproduced live).
printf 'implement' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"git commit -m \"old msg; npm test still fails\""},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "implement" ] \
  || fail "';' inside a quoted commit message must NOT split a span (false flip)"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"git commit -m \"build && npm test always green\""},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "implement" ] \
  || fail "'&&' inside a quoted commit message must NOT split a span (false flip)"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"(cd foo && npm test)"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "verify" ] \
  || fail "(cd foo && npm test) MUST flip (paren must not glue to the token)"
printf 'implement' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"(npm test)"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "verify" ] \
  || fail "(npm test) MUST flip (paren must not glue to the token)"
pass "spine: quoted separators inert; subshell-wrapped test runs still anchor"

# Test 34: quote-parity guard — an UNTERMINATED quote is invalid shell (bash
# rejects it, nothing executes), so the phase must never be evaluated for it;
# the sentinel keeps a legitimate closing quote at end-of-string flip-capable.
printf 'implement' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"npm test -- --grep it's_slow"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "implement" ] \
  || fail "odd-apostrophe command is invalid shell — must NOT flip"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"npm test \"$FILTER\""},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "verify" ] \
  || fail "command ENDING in a closing double quote MUST flip (sentinel regression trap)"
printf 'implement' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"echo \"it's fine\" && npm test"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "verify" ] \
  || fail "apostrophe inside balanced double quotes MUST still flip"
pass "spine: quote parity — unterminated skips, sentinel keeps trailing-quote flips"

# Test 32: verify → implement revert — a file edit after verification means the
# evidence is stale; a residual false flip also self-heals through this path.
printf 'verify' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x.ts"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "implement" ] \
  || fail "Edit during verify must revert phase to implement"
printf 'plan' > "$SPINE_BRAIN/.injected/sess-flip.phase"
BRAIN_DIR="$SPINE_BRAIN" bash "$SCRIPT" >/dev/null <<'JSON'
{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x.ts"},"session_id":"sess-flip"}
JSON
[ "$(cat "$SPINE_BRAIN/.injected/sess-flip.phase")" = "plan" ] \
  || fail "Edit during plan must not touch the phase (only verify reverts)"
pass "spine: verify -> implement revert on file edits (plan untouched)"
rm -rf "$SPINE_BRAIN"


# --- Case-insensitive rule matching (0.45.2 security fix) --------------------
# Windows (NTFS) and default macOS (APFS) are case-INSENSITIVE: `Persona-Rules.json`
# and `persona-rules.json` are the SAME FILE. The rule regexes are case-sensitive, so
# before this fix a write steered to a case-varied path hit the real file while the
# `ask` gate never fired — removing the human checkpoint on edits to the guard's own
# rules and to scripts/hooks, the classic prompt-injection escalation path.
#
# Paths MUST be inside cwd. An out-of-repo path makes resource_scope answer `ask` on its
# own, which would make these cases pass against the UNFIXED guard — a tautology. Verified:
# with the pre-fix guard and out-of-repo paths, these "passed"; in-repo they correctly fail.
RRT="$(cd "$(dirname "$0")"/.. && pwd)"
gv() { printf '{"tool_name":"%s","session_id":"caseT","cwd":"%s","tool_input":{"file_path":"%s/%s","content":"y"}}' "$1" "$RRT" "$RRT" "$2" | bash "$SCRIPT"; }

for variant in "persona-rules.json" "Persona-Rules.json" "PERSONA-RULES.JSON" "PeRsOnA-RuLeS.jSoN"; do
  out=$(gv Write "$variant")
  [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
    || fail "case-varied rules-file write '$variant' must ask (got: $out)"
done
pass "case-varied persona-rules writes all ask"

for variant in "scripts/lib.sh" "scripts/LIB.SH" "SCRIPTS/lib.sh" "scripts/Lib.Sh" "hooks/HOOKS.json"; do
  out=$(gv Write "$variant")
  [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
    || fail "case-varied plugin-script write '$variant' must ask (got: $out)"
done
pass "case-varied plugin-script writes all ask"

# Command rules run through the same loop.
for cmd in "git push --force origin main" "git push --FORCE origin MAIN"; do
  out=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd" | bash "$SCRIPT")
  [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
    || fail "case-varied command '$cmd' must ask (got: $out)"
done
pass "case-varied force-push asks"

# Guard the guard: -i must NOT turn every write into an ask. An in-repo file matching no
# rule stays silent.
out=$(gv Write "README.md")
[ -z "$out" ] || fail "ordinary in-repo write must stay silent after -i (got: $out)"
pass "-i does not over-block ordinary writes"
echo
echo "ALL PASS"
