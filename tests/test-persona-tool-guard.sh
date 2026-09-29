#!/bin/bash
# run-all-timeout: 480   (measured 94s alone on MSYS 2026-09-28; 145-195s alone on a loaded MSYS box 2026-09-29 after the T2/L3/parity/512 KB cases)
# pins: SB_INTENT_SPINE — kill-switch test: asserts =off leaves the phase alone (Test 29)
# pins: SB_PERSONA_GATE — kill-switch test: asserts =off is honored (Test 27)
# pins: SB_RESOURCE_SCOPE — kill-switch test: asserts =off widens the default resource scope
# pins: SB_RESOURCE_SCOPE_EXTRA — exercises the extra-scope allowlist directly — the value itself is the subject of that subtest
# pins: SB_TOOL_SCOPE — kill-switch test: asserts =off (Test 16)
# pins: SB_TOOL_SCOPE_EXTRA — exercises the extra-tool allowlist directly — the value itself is the subject of that subtest
# Tests for scripts/persona-tool-guard.sh — Layer 3 PreToolUse hook.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/persona-tool-guard.sh"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Every mktemp below lands under one root that the EXIT trap removes, so a failing assertion (fail
# exits at once) leaves no brain or fixture dir behind.
PTG_TMP=$(mktemp -d); export TMPDIR="$PTG_TMP"
trap 'rm -rf "$PTG_TMP"' EXIT

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

# D219: tests 2-7 previously ran with no BRAIN_DIR override, so sb_log_audit
# wrote every verdict to the MAINTAINER'S LIVE ~/.second-brain/audit-log.jsonl.
# Sandbox them behind their own throwaway BRAIN_DIR like every other block in
# this file already does.
T27_BRAIN=$(mktemp -d)

# Test 2: force-push to main → ask
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"},"session_id":"t2"}' | BRAIN_DIR="$T27_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "force-push-main should ask (got: $out)"
pass "force-push-main asks"

# Test 3: direct write to USER.md → ask. D218: assert the SPECIFIC rule fired
# (warn-direct-write-hot-tier), not just "some ask rule matched" — a
# tautological assertion would also pass if e.g. the self-edit rule matched
# by accident, or if the rule engine picked the wrong verdict for the right
# reason. Check the audit-log's "rule" field, the machine-readable record of
# which rule actually decided.
rm -f "$T27_BRAIN/audit-log.jsonl"
# SB_RESOURCE_SCOPE=off: /x/... is outside the default resource-scope
# allowlist ($CWD/$HOME/.second-brain/knowledge/tmp), so without this the
# resource-scope guard asks FIRST for an unrelated reason and the assertion
# below would never actually exercise warn-direct-write-hot-tier.
out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/x/.second-brain/USER.md","content":"foo"},"session_id":"t3"}' \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$T27_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "write-USER.md should ask (got: $out)"
grep -q '"rule":"warn-direct-write-hot-tier"' "$T27_BRAIN/audit-log.jsonl" \
  || fail "write-USER.md should ask via warn-direct-write-hot-tier specifically (audit-log: $(cat "$T27_BRAIN/audit-log.jsonl" 2>/dev/null))"
pass "write-USER.md asks via warn-direct-write-hot-tier"

# Test 4: harmless ls → silent
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"t4"}' | BRAIN_DIR="$T27_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "harmless Bash should be silent (got: $out)"
pass "harmless Bash silent"

# Test 5: kill switch
out=$(SB_PERSONA_GATE=off BRAIN_DIR="$T27_BRAIN" bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls 2>/dev/null\"}}' | '$SCRIPT'")
[ -z "$out" ] || fail "SB_PERSONA_GATE=off should suppress output"
pass "kill switch honored"

# Test 6: rm -rf → ask
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/foo"},"session_id":"t6"}' | BRAIN_DIR="$T27_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "rm -rf should ask (got: $out)"
pass "rm -rf asks"

# --- v2.9.0 Phase 2: hook self-protection ---
# Test 7: Edit to plugin script → ask (defends safety layer from
# injection-driven self-disable). D218: assert the specific self-edit rule,
# not just any ask.
# Both targets below are outside the default resource-scope allowlist;
# SB_RESOURCE_SCOPE=off isolates the self-edit RULE being tested from the
# (separately-tested) resource-scope guard, which would otherwise ask first.
rm -f "$T27_BRAIN/audit-log.jsonl"
out=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/x/claude-code-plugin/scripts/lib.sh"},"session_id":"t7a"}' \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$T27_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "Edit to plugin script should ask (got: $out)"
grep -q '"rule":"warn-self-edit-plugin-scripts-edit"' "$T27_BRAIN/audit-log.jsonl" \
  || fail "plugin script edit should ask via warn-self-edit-plugin-scripts-edit specifically (audit-log: $(cat "$T27_BRAIN/audit-log.jsonl" 2>/dev/null))"
pass "self-protection: plugin script edit asks via warn-self-edit-plugin-scripts-edit"

rm -f "$T27_BRAIN/audit-log.jsonl"
# persona-rules.default.json (not persona-rules.json): the plain filename also
# matches warn-direct-write-hot-tier, which fires first (same "ask" rank, JSON
# order wins ties) and would mask whether warn-self-edit-persona-rules itself
# matched. The .default variant is covered ONLY by the self-edit rule.
out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/x/persona-rules.default.json","content":"{}"},"session_id":"t7b"}' \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$T27_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "Write to persona-rules.default.json should ask (got: $out)"
grep -q '"rule":"warn-self-edit-persona-rules"' "$T27_BRAIN/audit-log.jsonl" \
  || fail "persona-rules write should ask via warn-self-edit-persona-rules specifically (audit-log: $(cat "$T27_BRAIN/audit-log.jsonl" 2>/dev/null))"
pass "self-protection: persona-rules edit asks via warn-self-edit-persona-rules"

# Slice 3 (docs/plans/2026-09-24-repo-brain.md §B): the repo layer's own rules.json is
# self-edit-protected too — Write asks via warn-self-edit-repo-rules, Edit via the -edit twin.
rm -f "$T27_BRAIN/audit-log.jsonl"
out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/x/.second-brain/projects/demo/rules.json","content":"{}"},"session_id":"t7c"}' \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$T27_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "Write to repo rules.json should ask (got: $out)"
grep -q '"rule":"warn-self-edit-repo-rules"' "$T27_BRAIN/audit-log.jsonl" \
  || fail "repo rules.json write should ask via warn-self-edit-repo-rules specifically (audit-log: $(cat "$T27_BRAIN/audit-log.jsonl" 2>/dev/null))"
pass "self-protection: repo rules.json Write asks via warn-self-edit-repo-rules"

rm -f "$T27_BRAIN/audit-log.jsonl"
out=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/x/.second-brain/projects/demo/rules.json"},"session_id":"t7d"}' \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$T27_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "Edit to repo rules.json should ask (got: $out)"
grep -q '"rule":"warn-self-edit-repo-rules-edit"' "$T27_BRAIN/audit-log.jsonl" \
  || fail "repo rules.json edit should ask via warn-self-edit-repo-rules-edit specifically (audit-log: $(cat "$T27_BRAIN/audit-log.jsonl" 2>/dev/null))"
pass "self-protection: repo rules.json Edit asks via warn-self-edit-repo-rules-edit"
rm -rf "$T27_BRAIN"

# --- v2.9.0 Phase 3: resource-scope guard ---
# Set up an isolated brain dir so audit-log lands somewhere we can check.
SCOPE_BRAIN=$(mktemp -d)
TS_BRAIN=$(mktemp -d)

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
#
# Hermetic fixture root (review fix): match_path requires a literal `/claude-code-plugin/` or
# `/second-brain/` path segment. Using the real checkout root here made this section pass or
# fail depending on what the checkout DIRECTORY happened to be named (e.g. a worktree checked
# out as "claude-code-plugin-repo-brain" has no `/claude-code-plugin/` segment at all) — build
# a throwaway root that is always literally named claude-code-plugin/ instead.
RRT="$(mktemp -d)/claude-code-plugin"; mkdir -p "$RRT/scripts" "$RRT/hooks"
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
rm -rf "$(dirname "$RRT")" 2>/dev/null

# --- D151: self-edit rule must match the INSTALLED plugin cache layout -------
# <cache>/second-brain/second-brain/<version>/scripts/... — a version directory
# sits between the plugin-name segment and scripts/hooks. The old regex
# required them adjacent and silently missed the layout that actually runs.
CACHE_BRAIN=$(mktemp -d)
# SB_RESOURCE_SCOPE=off: the cache path is outside the default resource-scope
# allowlist, which would ask FIRST for an unrelated reason and mask whether
# the self-edit RULE regex actually matched — assert the specific rule below.
out=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/u/.claude/plugins/cache/second-brain/second-brain/0.48.0/hooks/hooks.json"},"session_id":"d151"}' \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$CACHE_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "D151: installed cache-layout hooks.json edit should ask (got: $out)"
grep -q '"rule":"warn-self-edit-plugin-scripts-edit"' "$CACHE_BRAIN/audit-log.jsonl" \
  || fail "D151: should ask via warn-self-edit-plugin-scripts-edit specifically (audit-log: $(cat "$CACHE_BRAIN/audit-log.jsonl" 2>/dev/null))"
pass "D151: self-edit rule matches installed cache layout (version dir between plugin name and hooks/)"

rm -f "$CACHE_BRAIN/audit-log.jsonl"
out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/home/u/.claude/plugins/cache/second-brain/second-brain/0.48.0/scripts/persona-tool-guard.sh","content":"x"},"session_id":"d151b"}' \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$CACHE_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "D151: installed cache-layout scripts/*.sh edit should ask (got: $out)"
grep -q '"rule":"warn-self-edit-plugin-scripts"' "$CACHE_BRAIN/audit-log.jsonl" \
  || fail "D151: should ask via warn-self-edit-plugin-scripts specifically (audit-log: $(cat "$CACHE_BRAIN/audit-log.jsonl" 2>/dev/null))"
pass "D151: self-edit rule matches installed cache-layout scripts/ too"
rm -rf "$CACHE_BRAIN"

# --- D154: missing/empty/unparseable user persona-rules.json falls back to
# persona-rules.default.json AND logs an sb_log_error row; verdicts still fire.
D154_BRAIN=$(mktemp -d)
mkdir -p "$D154_BRAIN"
printf '{"rules":[' > "$D154_BRAIN/persona-rules.json"   # truncated/unparseable
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf / && git push --force origin main"},"session_id":"d154"}' \
  | BRAIN_DIR="$D154_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "D154: malformed user persona-rules.json must still fall back and ask (got: $out)"
grep -q 'persona-rules.json' "$D154_BRAIN/error-log.jsonl" 2>/dev/null \
  || fail "D154: malformed user persona-rules.json must log an sb_log_error row (error-log: $(cat "$D154_BRAIN/error-log.jsonl" 2>/dev/null))"
pass "D154: malformed user persona-rules.json falls back to defaults and logs loudly"

# Empty (0-byte) user file — same contract.
rm -f "$D154_BRAIN/error-log.jsonl"
: > "$D154_BRAIN/persona-rules.json"
out=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/u/.aws/credentials"},"cwd":"/home/u/proj","session_id":"d154b"}' \
  | BRAIN_DIR="$D154_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "D154: empty user persona-rules.json must still fall back and ask (got: $out)"
grep -q 'persona-rules.json' "$D154_BRAIN/error-log.jsonl" 2>/dev/null \
  || fail "D154: empty user persona-rules.json must log an sb_log_error row"
pass "D154: empty user persona-rules.json falls back to defaults and logs loudly"

# D154 (review follow-up): well-formed JSON but `.rules` absent or an empty
# array with NO learned rules either is "nothing to evaluate", not a
# legitimate "user disabled every rule" signal — must also fall back.
rm -f "$D154_BRAIN/error-log.jsonl"
printf '{}' > "$D154_BRAIN/persona-rules.json"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf / && git push --force origin main"},"session_id":"d154c"}' \
  | BRAIN_DIR="$D154_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "D154: bare {} user persona-rules.json must fall back and ask (got: $out)"
grep -q 'persona-rules.json' "$D154_BRAIN/error-log.jsonl" 2>/dev/null \
  || fail "D154: bare {} user persona-rules.json must log an sb_log_error row"
pass "D154: bare {} falls back to defaults and logs loudly"

rm -f "$D154_BRAIN/error-log.jsonl"
printf '{"rules":[]}' > "$D154_BRAIN/persona-rules.json"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf / && git push --force origin main"},"session_id":"d154d"}' \
  | BRAIN_DIR="$D154_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "D154: {\"rules\":[]} with no learned rules must fall back and ask (got: $out)"
grep -q 'persona-rules.json' "$D154_BRAIN/error-log.jsonl" 2>/dev/null \
  || fail "D154: {\"rules\":[]} must log an sb_log_error row"
pass "D154: {\"rules\":[]} (no learned rules) falls back to defaults and logs loudly"

# Companion case (must NOT regress): rules:[] alongside a NON-empty learned[]
# is a legitimate sparse config (test 23 below relies on exactly this shape)
# and must be honored as-is, not treated as invalid.
rm -f "$D154_BRAIN/error-log.jsonl"
cat > "$D154_BRAIN/persona-rules.json" <<'EOF'
{"rules":[],"learned":[{"event":"bash","pattern":"npm install -g","action":"warn","message":"Learned: install project-local, not global."}]}
EOF
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"npm install -g typescript"},"session_id":"d154e"}' \
  | BRAIN_DIR="$D154_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("project-local")' >/dev/null \
  || fail "D154: rules:[] with a non-empty learned[] must still be honored (got: $out)"
[ -f "$D154_BRAIN/error-log.jsonl" ] && grep -q 'persona-rules.json' "$D154_BRAIN/error-log.jsonl" \
  && fail "D154: rules:[]+learned[...] is valid — must NOT log a fallback error"
pass "D154: rules:[] with non-empty learned[] is honored, not treated as invalid"
rm -rf "$D154_BRAIN"

# D154 (review follow-up): fail-SAFE, not fail-open — when the user file is
# invalid AND the shipped default is unreachable, the guard must deny rather
# than silently exit 0 (previously: no rules to evaluate = allow everything).
# CLAUDE_PLUGIN_ROOT points at a fake root carrying a REAL lib.sh (so
# sb_log_error keeps working and this isolates exactly "default missing")
# but no persona-rules.default.json.
D154F_BRAIN=$(mktemp -d)
D154F_ROOT=$(mktemp -d)
mkdir -p "$D154F_ROOT/scripts"
cp "$(dirname "$SCRIPT")/lib.sh" "$D154F_ROOT/scripts/lib.sh"
printf '{}' > "$D154F_BRAIN/persona-rules.json"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf / && git push --force origin main"},"session_id":"d154f"}' \
  | BRAIN_DIR="$D154F_BRAIN" CLAUDE_PLUGIN_ROOT="$D154F_ROOT" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "D154: user invalid + default missing must DENY, not silently allow (got: $out)"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("rules unavailable")' >/dev/null \
  || fail "D154: fail-safe deny must explain 'rules unavailable' (got: $out)"
grep -q 'denying' "$D154F_BRAIN/error-log.jsonl" 2>/dev/null \
  || fail "D154: fail-safe deny must be logged"
pass "D154: user invalid + default missing -> fail-safe deny (not silent allow)"
rm -rf "$D154F_BRAIN" "$D154F_ROOT"

# --- D155: resource-scope allowlist must lexically collapse '..' before the
# prefix match — a Read of "$CWD/../../../etc/shadow" must ASK, not silently
# stay in scope.
D155_BRAIN=$(mktemp -d)
out=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/home/u/proj/../../../etc/shadow"},"cwd":"/home/u/proj","session_id":"d155"}' \
  | BRAIN_DIR="$D155_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "D155: '..' traversal out of \$CWD must ask, not silently stay in scope (got: $out)"
pass "D155: resource-scope collapses '..' before the prefix match"

# In-scope path with a benign, fully-inside '..' must NOT be over-blocked.
out=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/home/u/proj/sub/../main.py"},"cwd":"/home/u/proj","session_id":"d155b"}' \
  | BRAIN_DIR="$D155_BRAIN" bash "$SCRIPT")
[ -z "$out" ] || fail "D155: '..' collapsing to an in-scope path must not be over-blocked (got: $out)"
pass "D155: '..' collapsing to an in-scope path stays silent"
rm -rf "$D155_BRAIN"

# --- D156: a rewrite rule whose REPLACEMENT is invalid for sed must fail to
# ask, never emit permissionDecision:allow with an empty updatedInput.command.
D156_BRAIN=$(mktemp -d)
cat > "$D156_BRAIN/persona-rules.json" <<'EOF'
{
  "rules": [
    {
      "name": "bad-replace-rewrite",
      "tool": "Bash",
      "match_command": "foo",
      "action": "rewrite",
      "replace": "bar\\",
      "reason": "test"
    }
  ]
}
EOF
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo foo"},"session_id":"d156"}' \
  | BRAIN_DIR="$D156_BRAIN" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "D156: invalid sed replacement must fail to ask, not allow (got: $out)"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.updatedInput == null' >/dev/null \
  || fail "D156: invalid rewrite must never carry an updatedInput (got: $out)"
pass "D156: rewrite rule with an unparseable replacement fails to ask, not allow+empty"
rm -rf "$D156_BRAIN"

# --- B7: fail SAFE under load — the locked rules are decided before any dependency -------------
# A PreToolUse hook that answers after its timeout is CANCELLED and the tool RUNS (CLI 2.1.283
# probe, 2026-09-28; ~217 guard runs failed open in 4 heavy sessions). Fixture: a plugin root whose
# lib.sh sleeps, plus PATH shims that sleep for every external the full logic spawns. The locked
# rules must still be answered within B7_BOUND seconds (the shims sleep B7_SLEEP). No GNU
# `timeout` (absent on macOS): whole-second SECONDS arithmetic. `date` is left unshimmed: bash
# < 4.2 (macOS /bin/bash) has no builtin clock for the audit row's timestamp. Generous bounds: a
# passing run never sleeps, a stalled one sleeps B7_SLEEP — machine load cannot flake the verdict.
# B7_SCOPE=off isolates the rule under test from the (separately tested) resource-scope ask.
B7_SLEEP=20; B7_BOUND=10; B7_SCOPE=off
B7=$(mktemp -d); mkdir -p "$B7/root/scripts" "$B7/shims" "$B7/brain"
# Precondition: the audit dir exists BEFORE the shims go on PATH — _fp_audit would otherwise run the
# shimmed (sleeping) mkdir and the bound would measure the fixture, not the guard.
[ -d "$B7/brain" ] || fail "B7 precondition: $B7/brain must exist before the shims are installed"
printf 'sleep %s\n' "$B7_SLEEP" > "$B7/root/scripts/lib.sh"
cp "$(dirname "$SCRIPT")/persona-rules.default.json" "$B7/root/scripts/"
for t in jq cat tr grep sed awk head tail cut wc realpath greadlink readlink cygpath dirname basename mkdir mv uname git; do
  printf '#!/bin/sh\nsleep %s\nexit 127\n' "$B7_SLEEP" > "$B7/shims/$t"; chmod +x "$B7/shims/$t"
done
b7() {  # b7 <payload-json> [wrapper…] -> B7_OUT, B7_EL (whole seconds)
  local p="$1" s; shift
  s=$SECONDS
  B7_OUT=$(printf '%s' "$p" | SB_RESOURCE_SCOPE="$B7_SCOPE" CLAUDE_PLUGIN_ROOT="$B7/root" BRAIN_DIR="$B7/brain" PATH="$B7/shims:$PATH" bash "$@" "$SCRIPT")
  B7_EL=$(( SECONDS - s ))
}
b7_ask() {  # b7_ask <label> <rule> <payload-json> [wrapper…]
  local label="$1" rule="$2" p="$3"; shift 3
  rm -f "$B7/brain/audit-log.jsonl"
  b7 "$p" "$@"
  [ "$B7_EL" -le "$B7_BOUND" ] \
    || fail "B7 $label: took ${B7_EL}s under a sleeping lib.sh/jq (bound ${B7_BOUND}s) — a loaded machine cancels this hook and the call RUNS"
  [ -n "$B7_OUT" ] && printf '%s' "$B7_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
    || fail "B7 $label: expected ask with every dependency stalled, got: '$B7_OUT'"
  grep -q "\"rule\":\"$rule\".*\"fastpath\":true" "$B7/brain/audit-log.jsonl" 2>/dev/null \
    || fail "B7 $label: the fast-path verdict must be audit-logged as rule $rule (audit: $(cat "$B7/brain/audit-log.jsonl" 2>/dev/null))"
  pass "B7 $label: ask via $rule in ${B7_EL}s with lib.sh and every spawn stalled"
}
b7_ask "rm -rf" warn-rm-rf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/b7-x"},"session_id":"b7a"}'
b7_ask "force-push (upper case, 2nd line)" warn-force-push-main '{"tool_name":"Bash","tool_input":{"command":"cd repo\nGIT PUSH --FORCE origin MAIN"},"session_id":"b7b"}'
b7_ask "Edit plugin script" warn-self-edit-plugin-scripts-edit '{"tool_name":"Edit","tool_input":{"file_path":"/home/x/claude-code-plugin/scripts/lib.sh","old_string":"a","new_string":"b"},"session_id":"b7c"}'
b7_ask "Windows-form hooks.json Write" warn-self-edit-plugin-scripts '{"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\x\\.claude\\plugins\\cache\\second-brain\\second-brain\\0.54.0\\hooks\\hooks.json","content":"{}"},"session_id":"b7d"}'
b7_ask "Write hot-tier file" warn-direct-write-hot-tier '{"tool_name":"Write","tool_input":{"file_path":"/x/.second-brain/persona-rules.json","content":"{}"},"session_id":"b7e"}'
b7_ask "MultiEdit repo rules" warn-self-edit-repo-rules-multiedit '{"tool_name":"MultiEdit","tool_input":{"file_path":"/x/.second-brain/projects/demo/rules.json","edits":[{"old_string":"a","new_string":"b"}]},"session_id":"b7f"}'
b7_ask "Edit rules cache" warn-self-edit-rules-cache-edit '{"tool_name":"Edit","tool_input":{"file_path":"/x/.second-brain/projects/demo/.rules-effective.json","old_string":"a","new_string":"b"},"session_id":"b7g"}'
# hook-timer.sh wraps this guard in hooks.json: the wrapper must add no dependency either.
b7_ask "rm -rf through hook-timer" warn-rm-rf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/b7-x"},"session_id":"b7h"}' "$(dirname "$SCRIPT")/hook-timer.sh" 5
# T1: the -edit twin of a self-edit rule is decided on the fast path too (a broken _PTG_RE_PRULES
# made the fast path decline while parity still passed).
b7_ask "Edit persona-rules.json" warn-self-edit-persona-rules-edit '{"tool_name":"Edit","tool_input":{"file_path":"/x/persona-rules.json","old_string":"a","new_string":"b"},"session_id":"b7i"}'
# SEC-M1: the role-card / slug caches the hooks inject are locked like the rule files.
b7_ask "Write into .second-brain/.injected" warn-self-edit-injected '{"tool_name":"Write","tool_input":{"file_path":"/x/.second-brain/.injected/s1.rolecard","content":"x"},"session_id":"b7j"}'
# L3: with resource_scope on (the default), an out-of-scope target gets the full logic's scope ask —
# on the fast path, still with every dependency stalled.
B7_SCOPE=on
b7_ask "out-of-scope Edit of a plugin script (scope on)" resource-scope-out-of-scope '{"tool_name":"Edit","tool_input":{"file_path":"/home/x/claude-code-plugin/scripts/lib.sh","old_string":"a","new_string":"b"},"cwd":"/home/u/proj","session_id":"b7k"}'
b7_ask "in-scope Edit of a plugin script (scope on)" warn-self-edit-plugin-scripts-edit '{"tool_name":"Edit","tool_input":{"file_path":"/home/u/proj/claude-code-plugin/scripts/lib.sh","old_string":"a","new_string":"b"},"cwd":"/home/u/proj","session_id":"b7l"}'
B7_SCOPE=off
# SEC-M3: a layer that cannot move the verdict (the auto-armed learned-only kind) keeps the fast
# path armed — before, ANY layer file sent every call down the slow path.
mkdir -p "$B7/brain/.injected" "$B7/brain/projects/armed"
printf '%s' armed > "$B7/brain/.injected/b7m.slug"
printf '{"schema":2,"rules":[],"learned":[{"event":"bash","pattern":"foo","action":"warn","message":"m"}]}\n' > "$B7/brain/projects/armed/rules.json"
b7_ask "learned-only repo layer" warn-rm-rf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/b7-x"},"session_id":"b7m"}'
printf '{"rules":[],"learned":[{"event":"bash","pattern":"foo","action":"warn","message":"m"}]}\n' > "$B7/brain/persona-rules.json"
b7_ask "learned-only user layer" warn-rm-rf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/b7-x"},"session_id":"b7n"}'
rm -f "$B7/brain/persona-rules.json" "$B7/brain/projects/armed/rules.json" "$B7/brain/.injected/b7m.slug"

# The fast path may only speak while the effective rules can be nothing but the shipped defaults.
# A user or repo layer that RAISES a locked rule to deny must still win (full logic, real lib).
B7L=$(mktemp -d); mkdir -p "$B7L/.injected" "$B7L/projects/demo"
RMRF_RE=$(jq -r '.rules[] | select(.name=="warn-rm-rf") | .match_command' "$(dirname "$SCRIPT")/persona-rules.default.json" | tr -d '\r')
jq -nc --arg m "$RMRF_RE" '{rules:[{name:"warn-rm-rf",tool:"Bash",action:"deny",lock:true,match_command:$m,reason:"user layer: never rm -rf"}]}' > "$B7L/persona-rules.json"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/b7-x"},"session_id":"b7u"}' | BRAIN_DIR="$B7L" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("user layer"))' >/dev/null \
  || fail "B7: a user layer raising warn-rm-rf to deny must win over the fast path's ask (got: $out)"
rm -f "$B7L/persona-rules.json"
printf '%s' demo > "$B7L/.injected/b7r.slug"
jq -nc --arg m "$RMRF_RE" '{rules:[{name:"warn-rm-rf",tool:"Bash",action:"deny",match_command:$m,reason:"repo layer: never rm -rf"}]}' > "$B7L/projects/demo/rules.json"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/b7-x"},"session_id":"b7r"}' | BRAIN_DIR="$B7L" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("repo layer"))' >/dev/null \
  || fail "B7: a repo layer raising warn-rm-rf to deny must win over the fast path's ask (got: $out)"
pass "B7: the fast path stands down when a user or repo layer exists (a raised deny still wins)"

# RR-RL1: a NAME-ONLY override needs neither "tool" nor a scope key — lib.sh's merge still lets it
# RAISE a locked rule's action by "name" alone. Before the fix, _ptg_layer_ok saw no "tool"/_scope
# key in this repo layer and stayed armed, so the fast path answered ask (its shipped default)
# while the full logic denied — a silently weakened verdict, and no violation logged.
mkdir -p "$B7L/.injected" "$B7L/projects/rl1"
printf '%s' rl1 > "$B7L/.injected/b7rl1.slug"
printf '{"rules":[{"name":"warn-rm-rf","action":"deny"}]}\n' > "$B7L/projects/rl1/rules.json"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/b7-rl1"},"session_id":"b7rl1"}' | BRAIN_DIR="$B7L" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "RR-RL1: a repo layer's name-only raise of warn-rm-rf to deny must win (got: $out)"
grep -q '"fastpath":true' "$B7L/audit-log.jsonl" 2>/dev/null \
  && fail "RR-RL1: a name-only override must stand the fast path down, not answer on it (audit: $(cat "$B7L/audit-log.jsonl"))"
pass "RR-RL1: repo layer name-only raise of warn-rm-rf to deny → full logic, deny wins, no fastpath row"
rm -rf "$B7L"

# T2: each stand-down branch of _ptg_fast, with the real lib.sh. no_fast <audit-log> <label>: the
# verdict came from the full logic (a row, none of them marked fastpath).
no_fast() {
  [ -s "$1" ] || fail "$2: no audit row at all (audit: $1)"
  grep -q '"fastpath":true' "$1" && fail "$2: the fast path decided — it must stand down (audit: $(cat "$1"))"
  return 0
}
T2=$(mktemp -d)
# (a) No slug memo: the fast path cannot tell which repo layer applies, so ANY projects/*/rules.json
#     that can move a verdict (here: raising warn-rm-rf to deny) sends it to the full logic.
mkdir -p "$T2/a/brain/projects/demo" "$T2/a/demo"
jq -nc --arg m "$RMRF_RE" '{rules:[{name:"warn-rm-rf",tool:"Bash",action:"deny",match_command:$m,reason:"repo layer: never rm -rf"}]}' > "$T2/a/brain/projects/demo/rules.json"
out=$(cd "$T2/a/demo" && echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/t2a"},"session_id":"t2a"}' \
  | CLAUDE_PROJECT_DIR="$T2/a/demo" BRAIN_DIR="$T2/a/brain" bash "$SCRIPT")
no_fast "$T2/a/brain/audit-log.jsonl" "T2(a) repo layer without a slug memo"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "T2(a): the repo layer's deny must win when no slug memo names the repo (got: $out)"
pass "T2(a): no slug memo + a repo layer that raises a rule → full logic, deny wins"
# (b) An effective-rules cache written after its .sig is a hand edit: the full logic must see it.
mkdir -p "$T2/b/brain/.injected" "$T2/b/brain/projects/parb"
printf '%s' parb > "$T2/b/brain/.injected/t2b.slug"
printf 'p=1 u=0 r=0 root=x\n' > "$T2/b/brain/projects/parb/.rules-effective.json.sig"
touch -t 202001010000 "$T2/b/brain/projects/parb/.rules-effective.json.sig"
cp "$(dirname "$SCRIPT")/persona-rules.default.json" "$T2/b/brain/projects/parb/.rules-effective.json"
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/t2b"},"session_id":"t2b"}' | BRAIN_DIR="$T2/b/brain" bash "$SCRIPT" >/dev/null
no_fast "$T2/b/brain/audit-log.jsonl" "T2(b) cache newer than its .sig"
pass "T2(b): an effective-rules cache newer than its .sig → full logic"
# (c) CLAUDE_PLUGIN_ROOT's default differs from the one beside the script (another version, an
#     edit): the table no longer mirrors P, and P's deny must win.
mkdir -p "$T2/c/root/scripts" "$T2/c/brain"
cp "$(dirname "$SCRIPT")/lib.sh" "$(dirname "$SCRIPT")/kb-schema.sh" "$T2/c/root/scripts/"
jq '(.rules[] | select(.name == "warn-rm-rf") | .action) = "deny"' "$(dirname "$SCRIPT")/persona-rules.default.json" > "$T2/c/root/scripts/persona-rules.default.json"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/t2c"},"session_id":"t2c"}' | CLAUDE_PLUGIN_ROOT="$T2/c/root" BRAIN_DIR="$T2/c/brain" bash "$SCRIPT")
no_fast "$T2/c/brain/audit-log.jsonl" "T2(c) plugin-root default differs"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "T2(c): a CLAUDE_PLUGIN_ROOT default raising warn-rm-rf to deny must win (got: $out)"
pass "T2(c): a CLAUDE_PLUGIN_ROOT default that differs from the sibling → full logic, its deny wins"
# SEC-M3: a layer that COULD move the verdict still stands the fast path down: a \u-escaped key.
mkdir -p "$T2/d/brain"
printf '{"rules":[{"t\\u006fol":"Bash","name":"x","action":"deny","match_command":"rm"}],"learned":[{"event":"bash"}]}\n' > "$T2/d/brain/persona-rules.json"
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/t2d"},"session_id":"t2d"}' | BRAIN_DIR="$T2/d/brain" bash "$SCRIPT" >/dev/null
no_fast "$T2/d/brain/audit-log.jsonl" "SEC-M3 layer with a \\u-spelled key"
pass "SEC-M3: a layer with a \\u escape stands the fast path down"
rm -rf "$T2"

# Parity: the fast path must reach exactly the verdict, reason and rule the full rule engine
# reaches. A user persona-rules.json that is a byte copy of the default forces the full logic
# (the fast path only runs with no user/repo layer) while yielding the same effective rules.
# SB_RESOURCE_SCOPE=off isolates the rules from the (separately tested) scope ask. Both brains
# carry the session's slug memo (as after SessionStart), so neither side pays sb_resolve_slug's git
# work; both paths emit through the same _fp_emit, so the verdict lines compare byte for byte.
PAR=$(mktemp -d); mkdir -p "$PAR/fast/.injected" "$PAR/full/.injected"
printf '%s' parproj > "$PAR/fast/.injected/par.slug"; printf '%s' parproj > "$PAR/full/.injected/par.slug"
cp "$(dirname "$SCRIPT")/persona-rules.default.json" "$PAR/full/persona-rules.json"
PAR_N=0
par_rule() {  # par_rule <audit-log> -> PR = the first "rule":"…" in it (builtins only)
  local a="" re='"rule":"([^"]*)"'
  PR=""
  [ -f "$1" ] && IFS= read -r -d '' a < "$1"
  [[ $a =~ $re ]] && PR="${BASH_REMATCH[1]}"
  return 0
}
par() {  # par <tool> <field> <value> [cwd]   (content carries dangerous-looking TEXT: never a verdict source)
  local p d1 d2 r1 scope=off
  # With a cwd, resource_scope runs (L3): the fast path must reach the full logic's scope ask too.
  [ -n "${4:-}" ] && scope=on
  # MSYS2_ARG_CONV_EXCL: MSYS would rewrite a /x/… argument to C:/Program Files/Git/x/… for jq.exe.
  p=$(MSYS2_ARG_CONV_EXCL='*' jq -nc --arg t "$1" --arg f "$2" --arg v "$3" --arg c "${4:-}" '{tool_name:$t, session_id:"par", tool_input:{($f):$v, content:"rm -rf / ; \"command\":\"rm -rf /\""}} + (if $c == "" then {} else {cwd:$c} end)')
  PAR_N=$((PAR_N + 1))
  rm -f "$PAR/fast/audit-log.jsonl" "$PAR/full/audit-log.jsonl"
  d1=$(printf '%s' "$p" | SB_RESOURCE_SCOPE="$scope" BRAIN_DIR="$PAR/fast" bash "$SCRIPT")
  d2=$(printf '%s' "$p" | SB_RESOURCE_SCOPE="$scope" BRAIN_DIR="$PAR/full" bash "$SCRIPT")
  par_rule "$PAR/fast/audit-log.jsonl"; r1="$PR"; par_rule "$PAR/full/audit-log.jsonl"
  [ "$d1" = "$d2" ] && [ "$r1" = "$PR" ] \
    || fail "B7 parity: $1 $2='$3' cwd='${4:-}' fast=[$d1 $r1] full=[$d2 $PR]"
  # T1: the same verdict must come FROM the fast path — a fast path that declines (a broken
  # pattern) hands the call to the full logic and parity alone would still pass.
  if [ -n "$d1" ]; then
    grep -q '"fastpath":true' "$PAR/fast/audit-log.jsonl" 2>/dev/null \
      || fail "B7 parity: $1 $2='$3' cwd='${4:-}' — verdict [$d1] did not come from the fast path (no fastpath row)"
    PAR_FAST=$((PAR_FAST + 1))
  fi
}
PAR_FAST=0
for c in 'rm -rf /tmp/x' 'rm -fr x' 'sudo rm -Rf x' $'ls\nrm -rf x' $'rm\n-rf x' 'xrm -rf y' 'rm -rf2 x' \
         'git push --force origin main' 'git push -f origin master' 'git push --force-with-lease origin main' \
         'GIT PUSH --FORCE ORIGIN MAIN' 'git push --force origin mainline' $'git push --force origin\nmain' \
         'git push origin main' 'ls -la'; do
  par Bash command "$c"
done
for f in /x/USER.md /x/superuser.md /x/persona-rules.json /x/persona-rules.default.json /x/.claude-plugin/plugin.json \
         /h/claude-code-plugin/scripts/x.sh /h/Second-Brain/SCRIPTS/Lib.SH /c/cache/second-brain/second-brain/0.1/hooks/hooks.json \
         /h/claude-code-plugin/scripts/sub/x.sh /b/projects/demo/rules.pending.json /b/.rules-effective.json \
         'C:\h\claude-code-plugin\scripts\x.sh' /x/README.md; do
  par Write file_path "$f"
done
for f in /x/USER.md /x/persona-rules.json /b/projects/demo/rules.json /h/claude-code-plugin/hooks/hooks.json; do par Edit file_path "$f"; done
for f in /x/persona-rules.default.json /b/projects/demo/.rules-effective.json; do par MultiEdit file_path "$f"; done
# SEC-M1: the .injected caches, all three tools.
for t in Write Edit MultiEdit; do par "$t" file_path /h/.second-brain/.injected/s1.rolecard; done
# L3: resource_scope on (a cwd given) — out-of-scope targets get the scope ask on both paths,
# in-scope ones the rule; '..' folds before the prefix test; a relative path resolves against cwd.
par Write file_path /x/persona-rules.json /home/u/proj
par Write file_path /home/u/proj/persona-rules.json /home/u/proj
par Write file_path persona-rules.json /home/u/proj
par Edit file_path /home/u/proj/../x/claude-code-plugin/scripts/a.sh /home/u/proj
par Edit file_path /home/u/proj/sub/../claude-code-plugin/scripts/a.sh /home/u/proj
par MultiEdit file_path /var/tmp/../etc/persona-rules.json /home/u/proj
par Write file_path /tmp/x/plugin.json /home/u/proj
par Write file_path /home/u/proj/README.md /home/u/proj
[ "$PAR_FAST" -ge 30 ] || fail "B7 parity: only $PAR_FAST of $PAR_N payloads were decided on the fast path"
pass "B7 parity: fast path == full rule engine (verdict, reason, rule) over $PAR_N payloads, $PAR_FAST decided on the fast path"
rm -rf "$PAR"

# Structural lock: the fast path's rule table covers exactly the default's LOCKED rules (a new
# locked rule without a fast-path twin would silently lose its fail-safe; a stale twin would ask
# for a rule the defaults dropped). Tool-suffixed variants (-edit/-multiedit) share one entry.
want=$(jq -r '.rules[] | select(.lock == true) | .name | sub("-(edit|multiedit)$"; "")' "$(dirname "$SCRIPT")/persona-rules.default.json" | tr -d '\r' | sort -u)
have=$(grep -oE '_ptg_set[[:space:]]+[a-z-]+' "$SCRIPT" | awk '{print $2}' | sort -u)
[ -n "$have" ] && [ "$want" = "$have" ] \
  || fail "B7: fast-path rule table (_ptg_set …) != default's locked rules. want: $(echo $want) | have: $(echo $have)"
pass "B7: fast-path rule table matches the default's locked rules"

# L3 structural lock: the fast path's scope test assumes the default's scope config — tool_scope
# off, resource_scope on for Write/Edit/MultiEdit, and _PTG_RS_ALLOW == its allowlist.
DEF="$(dirname "$SCRIPT")/persona-rules.default.json"
jq -e '(.tool_scope.enabled // false) == false and .resource_scope.enabled == true
       and ((.resource_scope.tools // []) | index("Write") != null and index("Edit") != null and index("MultiEdit") != null)' "$DEF" >/dev/null \
  || fail "L3: the default's scope config changed (tool_scope off, resource_scope on for Write/Edit/MultiEdit) — update _ptg_fast's scope test"
want_allow=$(jq -r '.resource_scope.allowlist[]' "$DEF" | tr -d '\r')
have_allow=$(eval "$(grep -E '^_PTG_RS_ALLOW=' "$SCRIPT")"; printf '%s' "$_PTG_RS_ALLOW")
[ -n "$have_allow" ] && [ "$want_allow" = "$have_allow" ] \
  || fail "L3: _PTG_RS_ALLOW != the default's resource_scope.allowlist. want: $(echo $want_allow) | have: $(echo $have_allow)"
pass "L3: the fast path's scope test mirrors the default's resource_scope"
rm -rf "$B7"

# --- Payload size: every verdict must arrive before the 5 s hook timeout ---------------------
# bounded LABEL LIMIT PAYLOAD-FILE [VAR=val…]: run the guard in the background, stdout to a file,
# and kill it past LIMIT seconds — a hung guard must FAIL the test, not hang it. BD_OUT, BD_EL (s).
SZ=$(mktemp -d)
bounded() {
  local label="$1" lim="$2" pf="$3" pid i=0; shift 3
  env BRAIN_DIR="$SZ" "$@" bash "$SCRIPT" < "$pf" > "$SZ/bounded.out" 2>/dev/null & pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$lim" ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fail "$label: still running after ${lim}s"; fi
  wait "$pid"; BD_OUT=$(cat "$SZ/bounded.out"); BD_EL=$i
}
is_ask() { printf '%s' "$1" | grep -q '"permissionDecision":"ask"'; }
# big_body N: an 'é' (bash then matches in wide characters, the slow case) and N bytes of lines.
big_body() { printf '\303\251'; printf '%*s' "$1" '' | tr ' ' x | fold -w 80 | awk '{printf "%s\\n", $0}'; }
BIG_BOUND=10
BODY=$(big_body 524288)
# P-H1: 512 KB payloads reach the full logic (the fast path reads 16 KiB); before, 146-222 s.
printf '{"session_id":"big","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' "$SZ" "$SZ/src/big.ts" "$BODY" > "$SZ/big1.json"
bounded "P-H1 512 KB benign in-scope Write" "$BIG_BOUND" "$SZ/big1.json"
[ -z "$BD_OUT" ] || fail "P-H1: a 512 KB benign in-scope Write must stay silent (got: $BD_OUT)"
pass "P-H1: 512 KB benign in-scope Write answered in ${BD_EL}s"
printf '{"session_id":"big","tool_name":"Bash","tool_input":{"command":"cat <<EOF\\n%sEOF\\nrm -rf /tmp/big-x"}}' "$BODY" > "$SZ/big2.json"
bounded "P-H1 512 KB heredoc ending in rm -rf" "$BIG_BOUND" "$SZ/big2.json"
is_ask "$BD_OUT" || fail "P-H1: a 512 KB command ending in rm -rf must ask (got: $BD_OUT)"
pass "P-H1: 512 KB command ending in rm -rf asks in ${BD_EL}s"
printf '{"session_id":"big","tool_name":"Write","tool_input":{"content":"%s","file_path":"/x/persona-rules.json"}}' "$BODY" > "$SZ/big3.json"
rm -f "$SZ/audit-log.jsonl"
bounded "P-H1 512 KB Write to persona-rules.json, file_path last" "$BIG_BOUND" "$SZ/big3.json" SB_RESOURCE_SCOPE=off
is_ask "$BD_OUT" && grep -q '"rule":"warn-direct-write-hot-tier"' "$SZ/audit-log.jsonl" \
  || fail "P-H1: a 512 KB Write to persona-rules.json (file_path last) must ask via warn-direct-write-hot-tier (got: $BD_OUT)"
pass "P-H1: 512 KB Write to persona-rules.json (file_path last) asks in ${BD_EL}s"

# SEC-H1: 5000 short lines inside the 16 KiB read (13 s in the per-line regex before) defer to grep.
LINES5K=$(i=0; while [ $i -lt 5000 ]; do printf 'x\\n'; i=$((i + 1)); done)
printf '{"session_id":"h1","tool_name":"Bash","tool_input":{"command":"%srm -rf /tmp/h1"}}' "$LINES5K" > "$SZ/h1.json"
rm -f "$SZ/audit-log.jsonl"
bounded "SEC-H1 5000-line command" "$BIG_BOUND" "$SZ/h1.json"
is_ask "$BD_OUT" || fail "SEC-H1: a 5000-line command ending in rm -rf must ask (got: $BD_OUT)"
# Over 64 lines the fast path must not decide (its per-line regex is what cost the time).
grep -q '"rule":"warn-rm-rf"' "$SZ/audit-log.jsonl" || fail "SEC-H1: the 5000-line ask was not audit-logged"
grep -q '"fastpath":true' "$SZ/audit-log.jsonl" \
  && fail "SEC-H1: a 5000-line command must be left to the full logic's grep, not the fast path's per-line regex"
pass "SEC-H1: 5000-line command asks in ${BD_EL}s, decided by the full logic"

# SEC-C1: a 65,600-character command: the pre-filter grep's here-string (65,601 bytes) hung on MSYS.
C1_PRE='{"session_id":"c1","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/c1 # '
{ printf '%s' "$C1_PRE"; printf '%*s' $(( 65600 - 17 )) '' | tr ' ' x; printf '"}}'; } > "$SZ/c1.json"
bounded "SEC-C1 65,600-character command" 20 "$SZ/c1.json"
is_ask "$BD_OUT" || fail "SEC-C1: the 65,600-character rm -rf command must ask (got: $BD_OUT)"
pass "SEC-C1: a 65,600-character command answers in ${BD_EL}s"

# RR-CR1: 50,000 CONSECUTIVE trailing newlines after the command text (SEC-H1/P-H1 above only have
# newlines INTERSPERSED with other text). The command is well over the fast path's 16 KiB read, so
# the payload reaches the full logic's _fp_clean — before, its per-newline `${v%"$_fp_nl"}` loop
# re-scanned the whole string once per trailing newline (O(N x length)): 43-48 s here, past the 5 s
# hook timeout (a fail-open DoS, not just slow).
TRAIL50K=$(i=0; while [ $i -lt 50000 ]; do printf '\\n'; i=$((i + 1)); done)
printf '{"session_id":"cr1","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/cr1%s"}}' "$TRAIL50K" > "$SZ/cr1.json"
rm -f "$SZ/audit-log.jsonl"
bounded "RR-CR1 50,000 consecutive trailing newlines, rm -rf" "$BIG_BOUND" "$SZ/cr1.json"
is_ask "$BD_OUT" || fail "RR-CR1: rm -rf with 50,000 trailing newlines must still ask (got: $BD_OUT)"
pass "RR-CR1: 50,000 consecutive trailing newlines answered in ${BD_EL}s (rm -rf still asks)"
rm -rf "$SZ"

echo
echo "ALL PASS"
