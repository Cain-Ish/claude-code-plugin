#!/bin/bash
# run-all-timeout: 600   (measured 296s alone on MSYS 2026-10-08 with 9.6 GB free and ~400 processes, after the R3B credential-alias/GX3/GX6 cases; 208-282s in other runs that day; 94s on 2026-09-28)
# pins: SB_INTENT_SPINE — kill-switch test: asserts =off leaves the phase alone (Test 29)
# pins: SB_PERSONA_GATE — kill-switch test: asserts =off is honored (Test 27)
# pins: SB_RESOURCE_SCOPE — kill-switch test: asserts =off widens the default resource scope
# pins: SB_RESOURCE_SCOPE_EXTRA — exercises the extra-scope allowlist directly — the value itself is the subject of that subtest
# pins: SB_RULES_LAYERS — G3: =off is the mode whose rules read names the default file twice (the jq-failure stand-in's trigger)
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

# Test 20b (final review, 0.54.1): the rewritten command reached jq as an --arg, and a native
# jq.exe on Windows gets no command line past ~32 KB — it printed nothing, so a matched rewrite
# rule let the ORIGINAL command run with no row. It now goes through stdin; if jq still yields
# nothing the guard asks. Same alt-pipe-rewrite rule as Test 20, on a ~40 KB command.
_rw_pad=$(printf '%40000s' '' | tr ' ' x)
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"echo foo %s"},"session_id":"rw40k"}' "$_rw_pad"   | BRAIN_DIR="$TS_BRAIN" bash "$SCRIPT")
new_cmd=$([ -n "$out" ] && printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null)
[ "${#new_cmd}" -eq $(( 9 + 40000 )) ]   || fail "20b: a ~40 KB command under a rewrite rule must come back rewritten in full (got ${#new_cmd} chars; out head: ${out:0:160})"
case "$new_cmd" in "echo baz "*) ;; *) fail "20b: the rewrite was not applied (head: ${new_cmd:0:40})" ;; esac
pass "rewrite: a ~40 KB command is rewritten and emitted in full (no argv-size drop)"

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
# Item 17: on bash < 4.3 (the macOS lane's /bin/bash 3.2) the guards' builtin payload reader steps
# aside and jq decides every call, as on main — a stalled jq can then hold the verdict, so these
# stalled-dependency cases cannot hold there by design and are skipped (loudly) on such a bash.
FP_OFF=0
bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }' && FP_OFF=1
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
b7() {  # b7 <payload-json> [wrapper…] -> B7_OUT, B7_EL (whole seconds), B7_MS (ms: EPOCHREALTIME, else B7_EL x 1000)
  local p="$1" s t0="${EPOCHREALTIME:-}" t1; shift
  s=$SECONDS
  B7_OUT=$(printf '%s' "$p" | SB_RESOURCE_SCOPE="$B7_SCOPE" CLAUDE_PLUGIN_ROOT="$B7/root" BRAIN_DIR="$B7/brain" PATH="$B7/shims:$PATH" bash "$@" "$SCRIPT")
  B7_EL=$(( SECONDS - s )) t1="${EPOCHREALTIME:-}"
  if [ -n "$t0" ] && [ -n "$t1" ]; then B7_MS=$(( (10#${t1//[!0-9]/} - 10#${t0//[!0-9]/}) / 1000 )); else B7_MS=$(( B7_EL * 1000 )); fi
}
b7_base() {  # b7_base -> B7_BASE_MS: a bash no-op's run time in the same setting, right now
  local t0="${EPOCHREALTIME:-}" t1
  printf '%s' x | PATH="$B7/shims:$PATH" bash -c ':'
  t1="${EPOCHREALTIME:-}"
  if [ -n "$t0" ] && [ -n "$t1" ]; then B7_BASE_MS=$(( (10#${t1//[!0-9]/} - 10#${t0//[!0-9]/}) / 1000 )); else B7_BASE_MS=0; fi
}
# b7_ask <label> <rule> <payload-json> [wrapper…]. Bound: B7_BOUND seconds; a bound of 1-2 s is
# measured above a bash no-op timed just before and just after the run (the slower one): on a
# loaded MSYS box bash alone starts in 0.1-1.6 s (R3, 2026-10-07), so an absolute 1 s would time
# the machine, not the guard. Such a bound gets one retry: a single load spike (a 3.7 s run beside a
# 0.9 s no-op, the fast path itself forking nothing) is not a slow guard; two in a row are failed.
b7_ask() {
  if [ "$FP_OFF" = 1 ]; then echo "SKIP: B7 $1 — the fast path is off on bash < 4.3 (item 17: jq decides, as on main)"; return 0; fi
  local label="$1" rule="$2" p="$3" base=0 lim n=0; shift 3
  while :; do
    rm -f "$B7/brain/audit-log.jsonl"
    base=0
    [ "$B7_BOUND" -le 2 ] && { b7_base; base=$B7_BASE_MS; }
    b7 "$p" "$@"
    [ "$B7_BOUND" -le 2 ] && { b7_base; [ "$B7_BASE_MS" -le "$base" ] || base=$B7_BASE_MS; }
    lim=$(( base + B7_BOUND * 1000 ))
    [ "$B7_MS" -le "$lim" ] && break
    n=$((n + 1))
    [ "$B7_BOUND" -le 2 ] && [ "$n" -lt 2 ] && { echo "NOTE: B7 $label: ${B7_MS} ms over a ${base} ms no-op — retrying once"; continue; }
    fail "B7 $label: took ${B7_MS} ms under a sleeping lib.sh/jq (bound ${B7_BOUND}s over a ${base} ms bash no-op) — a loaded machine cancels this hook and the call RUNS"
    break
  done
  [ -n "$B7_OUT" ] && printf '%s' "$B7_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
    || fail "B7 $label: expected ask with every dependency stalled, got: '$B7_OUT'"
  grep -q "\"rule\":\"$rule\".*\"fastpath\":true" "$B7/brain/audit-log.jsonl" 2>/dev/null \
    || fail "B7 $label: the fast-path verdict must be audit-logged as rule $rule (audit: $(cat "$B7/brain/audit-log.jsonl" 2>/dev/null))"
  pass "B7 $label: ask via $rule in ${B7_MS} ms with lib.sh and every spawn stalled"
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
# G1 (R3, 2026-10-07): every Read, and a file-tool call no locked rule matched, went to the full
# logic whatever its target — a Read of C:\Users\nobody\.ssh\id_rsa took 3.7 s median through
# hook-timer on a loaded MSYS box (4 of 9 runs past 5 s), and live, 9 Reads cancelled at 5 s still
# returned the file. The out-of-scope ask and a credential-store Read are decided on the fast path,
# within 1 s of a bash no-op with every dependency stalled. Credential Reads: in scope (cwd = HOME) and with the
# resource scope off — the two ways one is not already an out-of-scope ask.
B7_SCOPE=on B7_BOUND=1
b7_ask "out-of-scope Read" resource-scope-out-of-scope '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"},"cwd":"/home/u/proj","session_id":"b7o"}'
b7_ask "out-of-scope Write, no locked rule" resource-scope-out-of-scope '{"tool_name":"Write","tool_input":{"file_path":"/home/x/notes.txt","content":"hi"},"cwd":"/home/u/proj","session_id":"b7p"}'
HOME=/home/b7u b7_ask "credential Read inside the scope (cwd = HOME)" credential-read '{"tool_name":"Read","tool_input":{"file_path":"/home/b7u/.ssh/id_rsa"},"cwd":"/home/b7u","session_id":"b7q"}'
# NTFS/APFS: ~/.AWS is ~/.aws there (the 0.45.2 case-insensitivity class).
HOME=/home/b7u b7_ask "case-varied credential Read" credential-read '{"tool_name":"Read","tool_input":{"file_path":"/home/b7u/.AWS/Credentials"},"cwd":"/home/b7u","session_id":"b7t"}'
B7_SCOPE=off
HOME=/home/b7u b7_ask "credential Read, resource scope off" credential-read '{"tool_name":"Read","tool_input":{"file_path":"/home/b7u/.claude/.credentials.json"},"cwd":"/home/u/proj","session_id":"b7s"}'
B7_SCOPE=on
# The Windows form the verifier measured, on a host with an MSYS mount table (the fast path reads
# it to tell a drive path that cygpath would respell under a mount — %TEMP% is /tmp — from one it
# spells /x/… as the full logic does). Elsewhere a drive path is undecidable there: skipped, loudly.
if [ -r /proc/mounts ] && command -v cygpath >/dev/null 2>&1; then
  HOME=/c/Users/b7u b7_ask "Windows-form credential Read" credential-read '{"tool_name":"Read","tool_input":{"file_path":"C:\\Users\\b7u\\.ssh\\id_rsa"},"cwd":"C:\\Users\\b7u","session_id":"b7w"}'
  b7_ask "Windows-form out-of-scope Read" resource-scope-out-of-scope '{"tool_name":"Read","tool_input":{"file_path":"C:\\Users\\nobody\\.ssh\\id_rsa"},"cwd":"C:\\Workplace\\proj","session_id":"b7x"}'
else
  echo "SKIP: B7 Windows-form Reads — no MSYS mount table (/proc/mounts + cygpath) on this host"
fi
B7_SCOPE=off B7_BOUND=10
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
# The same name-only raise in the USER layer, beside a learned entry (the auto-armed kind that alone
# keeps the fast path armed — SEC-M3 above): the name-only rule must still stand it down.
rm -f "$B7L/projects/rl1/rules.json" "$B7L/.injected/b7rl1.slug"; : > "$B7L/audit-log.jsonl"
printf '{"rules":[{"name":"warn-rm-rf","action":"deny"}],"learned":[{"event":"bash","pattern":"foo","action":"warn","message":"m"}]}\n' > "$B7L/persona-rules.json"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/b7-rl1u"},"session_id":"b7rl1u"}' | BRAIN_DIR="$B7L" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "RR-RL1: a user layer's name-only raise of warn-rm-rf to deny (beside a learned entry) must win (got: $out)"
grep -q '"rule":"warn-rm-rf"' "$B7L/audit-log.jsonl" || fail "RR-RL1: the user-layer deny was not audit-logged"
grep -q '"fastpath":true' "$B7L/audit-log.jsonl" \
  && fail "RR-RL1: a user-layer name-only override must stand the fast path down (audit: $(cat "$B7L/audit-log.jsonl"))"
pass "RR-RL1: user layer name-only raise beside a learned entry → full logic, deny wins, no fastpath row"
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
  if [ -n "$d1" ] && [ "$FP_OFF" = 0 ]; then
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
# G1: Read and the no-rule file-tool calls — the scope ask, the credential ask (before the scope
# ask, and with the scope off), and what neither path asks about.
par Read file_path /etc/hosts /home/u/proj
par Read file_path /home/u/proj/../.aws/credentials /home/u/proj
par Read file_path "$HOME/.ssh/id_rsa" "$HOME"
par Read file_path "$HOME/.SSH/known_hosts" /home/u/proj
par Read file_path "$HOME/.claude/.credentials.json" "$HOME"
par Read file_path "$HOME/.claude/settings.json" "$HOME"
par Read file_path /home/u/proj/src/a.ts /home/u/proj
par Edit file_path /srv/x/notes.md /home/u/proj
par MultiEdit file_path /home/u/proj/src/a.ts /home/u/proj
par Read file_path "$HOME/.gnupg/pubring.kbx"
# GW: the session's project root ($PROJECT = CLAUDE_PROJECT_DIR) is a scope root beside $CWD.
CLAUDE_PROJECT_DIR=/w/repo par Read file_path /w/repo/.claude/worktrees/r3-ro/scripts/lib.sh /w/repo/.claude/worktrees/r3-mt
CLAUDE_PROJECT_DIR= par Read file_path /w/repo/.claude/worktrees/r3-ro/scripts/lib.sh /w/repo/.claude/worktrees/r3-mt
# On bash < 4.3 (item 17) no verdict comes from the fast path: parity still holds, the count is 0.
[ "$FP_OFF" = 1 ] || [ "$PAR_FAST" -ge 30 ] || fail "B7 parity: only $PAR_FAST of $PAR_N payloads were decided on the fast path"
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
# off, resource_scope on for Write/Edit/MultiEdit/Read (G1: Read is decided there too), no rule
# for Read, and _PTG_RS_ALLOW == its allowlist.
DEF="$(dirname "$SCRIPT")/persona-rules.default.json"
jq -e '(.tool_scope.enabled // false) == false and .resource_scope.enabled == true
       and ((.resource_scope.tools // []) | index("Write") != null and index("Edit") != null and index("MultiEdit") != null and index("Read") != null)
       and ([.rules[] | select(.tool == "Read")] | length) == 0' "$DEF" >/dev/null \
  || fail "L3: the default's scope config changed (tool_scope off, resource_scope on for Write/Edit/MultiEdit/Read, no Read rule) — update _ptg_fast's scope test"
want_allow=$(jq -r '.resource_scope.allowlist[]' "$DEF" | tr -d '\r')
have_allow=$(eval "$(grep -E '^_PTG_RS_ALLOW=' "$SCRIPT")"; printf '%s' "$_PTG_RS_ALLOW")
[ -n "$have_allow" ] && [ "$want_allow" = "$have_allow" ] \
  || fail "L3: _PTG_RS_ALLOW != the default's resource_scope.allowlist. want: $(echo $want_allow) | have: $(echo $have_allow)"
pass "L3: the fast path's scope test mirrors the default's resource_scope"
rm -rf "$B7"

# G1 structural lock: the credential stores a Read asks about are symlink-guard's (the guard that
# denies writes into them) — the same directories and files, under the same labels, so the two
# lists cannot drift apart. symlink-guard's /etc arm is deliberately not mirrored (see _ptg_cred).
# GX6/GT10 (R3B): one HOME-relative and one APPDATA-relative list per guard (arrays: "GitHub CLI"
# holds a space), and symlink-guard's every credential test — the spelling match and the inode
# match — reads its lists: no inline copy of an entry is left to drift.
SG="$(dirname "$SCRIPT")/symlink-guard.sh"
for g1_l in H A; do
  g1_p=$(eval "$(grep -E "^_PTG_CRED_$g1_l=" "$SCRIPT")"; eval "printf '%s\n' \"\${_PTG_CRED_$g1_l[@]}\"" | sort)
  g1_s=$(eval "$(grep -E "^_SG_CRED_$g1_l=" "$SG")"; eval "printf '%s\n' \"\${_SG_CRED_$g1_l[@]}\"" | sort)
  [ -n "$g1_s" ] && [ "$g1_s" = "$g1_p" ] \
    || fail "G1: _PTG_CRED_$g1_l != symlink-guard's _SG_CRED_$g1_l. want: $(echo $g1_s) | have: $(echo $g1_p)"
done
for g1_f in _sg_cred_match _sg_inode; do
  sed -n "/^$g1_f()/,/^}/p" "$SG" | grep -q '_SG_CRED_H\[@\]' || fail "GT10: symlink-guard's $g1_f must read _SG_CRED_H"
  sed -n "/^$g1_f()/,/^}/p" "$SG" | grep -q '_SG_CRED_A\[@\]' || fail "GT10: symlink-guard's $g1_f must read _SG_CRED_A"
done
[ "$(grep -c 'ssh:\.ssh' "$SG")" = 1 ] || fail "GT10: symlink-guard spells an entry outside _SG_CRED_H (a copy that can drift)"
[ "$(grep -c 'ssh:\.ssh' "$SCRIPT")" = 1 ] || fail "GT10: persona-tool-guard spells an entry outside _PTG_CRED_H"
# P-C2: every entry names its Write tier (tier:label:path, tier deny|ask), and the deny tier is
# exactly the stores symlink-guard denied at 407fa24 (the 0.56.0 additions ask). The lists above are
# compared with their tiers, so the two guards agree on each entry's tier as well.
g1_all=$(eval "$(grep -E '^_SG_CRED_H=' "$SG")"; eval "$(grep -E '^_SG_CRED_A=' "$SG")"; printf '%s\n' "${_SG_CRED_H[@]}" "${_SG_CRED_A[@]}")
g1_bad=$(printf '%s\n' "$g1_all" | grep -vE '^(deny|ask):[a-z0-9-]+:[^:]+$')
[ -z "$g1_bad" ] || fail "P-C2: credential entries without a deny|ask tier (tier:label:path): $(echo $g1_bad)"
g1_deny=$(printf '%s\n' "$g1_all" | grep '^deny:' | LC_ALL=C sort | tr '\n' ' ')
[ "$g1_deny" = "deny:aws:.aws deny:claude-config:.config/claude deny:claude-oauth:.claude/.credentials.json deny:gh-config:.config/gh deny:gnupg:.gnupg deny:netrc:.netrc deny:passwordstore:.password-store deny:ssh:.ssh " ] \
  || fail "P-C2: the deny tier must be the stores denied at 407fa24, no more, no fewer (have: $g1_deny)"
pass "G1: the Read credential lists mirror symlink-guard's, tiers included, which every one of its credential tests reads"

# GX3 (R3B): credential-read is a floor below the rules, as path-too-long is. Before, its ask exited
# ahead of the rule loop, so a user or repo rule that DENIES a Read of a credential store was
# weakened to an ask. A rules file with Read rules stands the fast path down; in scope or out of it,
# the deny wins, and a rule that only warns still gets the credential ask.
GX3=$(mktemp -d)
jq '.rules += [{name:"deny-ssh-read",tool:"Read",action:"deny",match_path:"/\\.ssh/",reason:"user layer: no ssh reads"},
               {name:"warn-aws-read",tool:"Read",action:"warn",match_path:"/\\.aws/",reason:"user layer: aws reads"}]' \
  "$(dirname "$SCRIPT")/persona-rules.default.json" > "$GX3/persona-rules.json"
gx3() {  # gx3 <file> <cwd> -> out
  out=$(MSYS2_ARG_CONV_EXCL='*' jq -nc --arg f "$1" --arg c "$2" '{tool_name:"Read",tool_input:{file_path:$f},cwd:$c,session_id:"gx3"}' \
    | HOME=/home/gx3 BRAIN_DIR="$GX3" bash "$SCRIPT")
}
gx3 /home/gx3/.ssh/id_rsa /home/gx3
[ -n "$out" ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("user layer"))' >/dev/null \
  || fail "GX3: a user rule denying a credential Read must stay a deny (in scope) (got: $out)"
gx3 /home/gx3/.ssh/id_rsa /w/proj
[ -n "$out" ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "GX3: a user rule denying a credential Read must stay a deny (out of scope) (got: $out)"
gx3 /home/gx3/.aws/credentials /home/gx3
[ -n "$out" ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask" and (.hookSpecificOutput.permissionDecisionReason | contains("credential store"))' >/dev/null \
  || fail "GX3: a warn rule must not lower the credential Read ask (got: $out)"
grep -q '"rule":"credential-read"' "$GX3/audit-log.jsonl" || fail "GX3: the floor's ask must be audited as credential-read"
pass "GX3: credential-read is a floor below the rules — a deny rule stays deny, a warn rule still asks"

# GS2/GC2/GX2 (R3B): other spellings of a credential store. symlink-guard's _sg_alias saw them for
# writes; the Read check compared the plain spelling only, and node reads every one of these. A
# literal ~/… is HOME's on every host (GX2a: the `~/*)` case arm was tilde-expanded, dead, and ~/.ssh
# went to $CWD/~/.ssh). On a Windows host: \\?\UNC\localhost\C$\…, \\LOCALHOST\c$\… (any case) and
# \\127.0.0.1\C$\… are the drive; a \\?\ device path naming no drive (GLOBALROOT, Volume{…}) and a
# UNC share under the machine's own name cannot be compared, nor can NTFS stream syntax (.netrc::$DATA,
# .ssh::$INDEX_ALLOCATION\id_rsa): they ask; trailing dots and spaces are dropped as Win32 drops them.
# Fast path and full logic alike (a user rules file stands the fast path down), the scope off so only
# the credential check can ask.
A2=$(mktemp -d); mkdir -p "$A2/fast" "$A2/full"
cp "$(dirname "$SCRIPT")/persona-rules.default.json" "$A2/full/persona-rules.json"
w() { printf '%s' "$1" | tr '|' '\134'; }
a2() {  # a2 <rule|-> <file_path> <cwd> <HOME> [VAR=val…]: both paths reach <rule> (- = no verdict)
  local b p r="$1" f="$2" c="$3" h="$4"
  shift 4
  p=$(MSYS2_ARG_CONV_EXCL='*' jq -nc --arg f "$f" --arg c "$c" '{tool_name:"Read",tool_input:{file_path:$f},cwd:$c,session_id:"a2"}')
  set -- "$r" "$f" "$c" "$h" "$@"
  for b in fast full; do
    : > "$A2/$b/audit-log.jsonl"
    out=$(printf '%s' "$p" | env SB_RESOURCE_SCOPE=off HOME="$4" BRAIN_DIR="$A2/$b" "${@:5}" bash "$SCRIPT" 2>"$A2/err"); a2_rc=$?
    if [ "$1" = - ]; then
      [ -z "$out" ] && [ "$a2_rc" = 0 ] && [ ! -s "$A2/err" ] \
        || fail "GS2 $b: a Read of '$2' must not ask (rc=$a2_rc, out: $out, stderr: $(head -c 300 "$A2/err"))"
    else
      printf '%s' "$out" | grep -q '"permissionDecision":"ask"' || fail "GS2 $b: a Read of '$2' must ask ($1) (got: '$out')"
      grep -q "\"rule\":\"$1\"" "$A2/$b/audit-log.jsonl" || fail "GS2 $b: '$2' must ask as $1 (audit: $(cat "$A2/$b/audit-log.jsonl"))"
    fi
  done
}
a2 credential-read '~/.ssh/id_rsa' /w/proj /home/a2u
a2 credential-read '~/.claude/.credentials.json' /w/proj /home/a2u
# GX6: the stores beyond the first eight, under HOME, under USERPROFILE when HOME points elsewhere,
# and under APPDATA (Windows: gh's hosts.yml, gcloud's directory). P-S8: _netrc (curl on Windows),
# git's XDG credential file, .pgpass, .vault-token, cargo's, terraform's and RubyGems' tokens. A Read
# asks for symlink-guard's ask tier and deny tier alike (P-C2 tiers Writes only).
for a2_f in .git-credentials .npmrc .docker/config.json .kube/config .pypirc .config/gcloud/credentials.db .azure/msal_token_cache.json \
            _netrc .config/git/credentials .pgpass .vault-token .cargo/credentials .cargo/credentials.toml \
            .terraform.d/credentials.tfrc.json .gem/credentials; do
  a2 credential-read "/home/a2u/$a2_f" /w/proj /home/a2u
done
a2 - /home/a2u/.docker/daemon.json /w/proj /home/a2u
a2 - /home/a2u/.cargo/config.toml /w/proj /home/a2u
a2 credential-read /home/a2p/.claude/.credentials.json /w/proj /home/a2u USERPROFILE=/home/a2p
a2 credential-read "/home/a2u/AppData/Roaming/GitHub CLI/hosts.yml" /w/proj /home/a2u APPDATA=/home/a2u/AppData/Roaming
a2 credential-read /home/a2u/AppData/Roaming/gcloud/credentials.db /w/proj /home/a2u APPDATA=/home/a2u/AppData/Roaming
a2 - /home/a2u/AppData/Roaming/Code/settings.json /w/proj /home/a2u APPDATA=/home/a2u/AppData/Roaming
# GT10: HOME's physical spelling counts as well (a junctioned or symlinked profile reaches the full
# logic resolved — cygpath, realpath — while HOME keeps its own spelling): builtin cd -P, as
# symlink-guard's _sg_homes. A HOME spelled through '..', and a symlinked one where ln -s makes links.
mkdir -p "$A2/phys/home/.ssh" "$A2/phys/x"; : > "$A2/phys/home/.ssh/id_rsa"
a2 credential-read "$A2/phys/home/.ssh/id_rsa" /w/proj "$A2/phys/x/../home"
ln -s "$A2/phys/home" "$A2/phys/link" 2>/dev/null
if [ -L "$A2/phys/link" ]; then
  a2 credential-read "$A2/phys/home/.ssh/id_rsa" /w/proj "$A2/phys/link"
else
  echo "SKIP: GT10 symlinked HOME — ln -s makes no symlink here (MSYS copies)"
fi
if command -v cygpath >/dev/null 2>&1; then
  a2 credential-read "$(w '||?|UNC|localhost|C$|Users|a2u|.ssh|id_rsa')" 'C:\w\proj' /c/Users/a2u
  a2 credential-read "$(w '||LOCALHOST|c$|Users|a2u|.ssh|id_rsa')" 'C:\w\proj' /c/Users/a2u
  a2 credential-read "$(w '||127.0.0.1|C$|Users|a2u|.netrc')" 'C:\w\proj' /c/Users/a2u
  a2 windows-alias:unc "$(w '||?|GLOBALROOT|Device|HarddiskVolume3|Users|a2u|.ssh|id_rsa')" 'C:\w\proj' /c/Users/a2u
  a2 windows-alias:unc "$(w '||?|Volume{2a024647-cc9f-415d-963e-f119fc16be42}|Users|a2u|.ssh|id_rsa')" 'C:\w\proj' /c/Users/a2u
  a2 windows-alias:unc "$(w '||MYHOST|C$|Users|a2u|.ssh|id_rsa')" 'C:\w\proj' /c/Users/a2u
  a2 windows-alias:stream "$(w 'C:|Users|a2u|.netrc::$DATA')" 'C:\w\proj' /c/Users/a2u
  a2 windows-alias:stream "$(w 'C:|Users|a2u|.ssh::$INDEX_ALLOCATION|id_rsa')" 'C:\w\proj' /c/Users/a2u
  a2 credential-read "$(w 'C:|Users|a2u|.ssh.|id_rsa')" 'C:\w\proj' /c/Users/a2u
  a2 credential-read "$(w 'C:|Users|a2u|.ssh |id_rsa')" 'C:\w\proj' /c/Users/a2u
  a2 credential-read "$(w 'C:|Users|a2u|.claude|.credentials.json.')" 'C:\w\proj' /c/Users/a2u
  a2 - "$(w 'C:|Users|a2u|notes.txt')" 'C:\w\proj' /c/Users/a2u
  # 8.3 short names (GC2/GX2c), on disk: SSH~1 is .ssh. The fast path cannot resolve one and stands
  # down; the full logic asks unless test -ef shows no credential store among the target and its
  # existing ancestors (a long-named project directory's short name stays silent).
  A2H="$A2/home"; mkdir -p "$A2H/.ssh" "$A2H/longprojectdirectory"; : > "$A2H/.ssh/id_rsa"; : > "$A2H/longprojectdirectory/notes.txt"
  A2S=$(cygpath -d "$A2H/.ssh" 2>/dev/null); A2L=$(cygpath -d "$A2H/longprojectdirectory" 2>/dev/null)
  case "$A2S" in
    *'~'[0-9]*)
      a2 credential-read "$A2S\\id_rsa" 'C:\w\proj' "$A2H"
      grep -q '"fastpath":true' "$A2/fast/audit-log.jsonl" && fail "GS2: an 8.3 Read must be left to the full logic (the fast path cannot resolve it)"
      a2 - "$A2L\\notes.txt" 'C:\w\proj' "$A2H"
      a2 windows-alias:8.3 "$A2L\\missing.txt" 'C:\w\proj' "$A2H" ;;
    *) echo "SKIP: GS2 8.3 cases — no short names on this volume (cygpath -d gave '$A2S')" ;;
  esac
  # GS3: a cygpath that fails leaves C:/… — the full logic spells it /c/… as the fast path does (and
  # logs it once), where _ptg_abs had taken it for a relative path: in scope, no credential match.
  mkdir -p "$A2/cyg"; printf '#!/bin/sh\nexit 1\n' > "$A2/cyg/cygpath"; chmod +x "$A2/cyg/cygpath"
  : > "$A2/full/error-log.jsonl"; : > "$A2/full/audit-log.jsonl"
  out=$(MSYS2_ARG_CONV_EXCL='*' jq -nc --arg f "$(w 'C:|Users|a2u|.ssh|id_rsa')" --arg c "$(w 'C:|w|proj')" '{tool_name:"Read",tool_input:{file_path:$f},cwd:$c,session_id:"a2"}' \
    | HOME=/c/Users/a2u PATH="$A2/cyg:$PATH" BRAIN_DIR="$A2/full" bash "$SCRIPT")
  grep -q '"rule":"credential-read"' "$A2/full/audit-log.jsonl" \
    || fail "GS3: with cygpath failing, a credential Read must still ask (out: $out, audit: $(cat "$A2/full/audit-log.jsonl"))"
  grep -q 'cygpath' "$A2/full/error-log.jsonl" || fail "GS3: the failed cygpath must be logged (error-log: $(cat "$A2/full/error-log.jsonl"))"
  # GT9: a project root given with a trailing backslash (C:\w\repo\, a drive root C:\) is still a
  # scope root — its /x/… spelling kept the separator and no target matched "/c/w/repo//*".
  for a2_p in 'C:\w\repo\' 'C:\'; do
    out=$(MSYS2_ARG_CONV_EXCL='*' jq -nc --arg f 'C:\w\repo\.claude\worktrees\r3-ro\scripts\lib.sh' --arg c 'C:\w\repo\.claude\worktrees\r3-mt' '{tool_name:"Read",tool_input:{file_path:$f},cwd:$c,session_id:"a2"}' \
      | CLAUDE_PROJECT_DIR="$a2_p" BRAIN_DIR="$A2/fast" bash "$SCRIPT")
    [ -z "$out" ] || fail "GT9: CLAUDE_PROJECT_DIR='$a2_p' must be a scope root (got: $out)"
  done
else
  echo "SKIP: GS2/GS3/GT9 Windows spellings — not a Windows host (no cygpath)"
fi
# Off Windows a ':' is a file-name character and nothing here is an alias.
if ! command -v cygpath >/dev/null 2>&1 && [[ ${OSTYPE:-} != msys* && ${OSTYPE:-} != cygwin* ]]; then
  a2 - '/w/proj/notes:2026.txt' /w/proj /home/a2u
fi
pass "GS2/GS3/GT9: Windows spellings of a credential store ask on both paths; a literal ~ is HOME; cygpath failure and a trailing-separator project root are handled"

# GW (R3, 2026-10-07): a session's payload cwd follows its shell's `cd` — live, the cwd was the
# r3-mt worktree while the session's project was the repo root, and Reads of the sibling worktree
# <repo>/.claude/worktrees/r3-ro/… got the out-of-scope ask. $PROJECT (CLAUDE_PROJECT_DIR, the
# directory the session was started in) is a scope root beside $CWD; an empty one adds nothing.
GW=$(mktemp -d)
gw() {  # gw <CLAUDE_PROJECT_DIR> -> out, gw_rc (stderr in $GW/err)
  out=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/w/repo/.claude/worktrees/r3-ro/scripts/lib.sh"},"cwd":"/w/repo/.claude/worktrees/r3-mt","session_id":"gw"}' \
    | CLAUDE_PROJECT_DIR="$1" BRAIN_DIR="$GW" bash "$SCRIPT" 2>"$GW/err"); gw_rc=$?
}
# GT7 (R3B): silent = no output, rc 0 and an empty stderr (a guard that aborts prints nothing either).
gw_silent() { [ -z "$out" ] && [ "$gw_rc" = 0 ] && [ ! -s "$GW/err" ]; }
gw /w/repo
gw_silent || fail "GW: a Read under the session's project root (cwd in a sibling worktree) must be in scope (rc=$gw_rc, got: $out, stderr: $(head -c 300 "$GW/err"))"
gw '/w/repo/'
gw_silent || fail "GW: a project root with a trailing '/' must still be a scope root (rc=$gw_rc, got: $out, stderr: $(head -c 300 "$GW/err"))"
gw ''
[ -n "$out" ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "GW: with CLAUDE_PROJECT_DIR empty the sibling worktree is out of scope again — an empty \$PROJECT must not match every path (got: $out)"
pass "GW: the session's project root (CLAUDE_PROJECT_DIR) is in scope, worktrees included; an empty one adds nothing"
# GC6 (R3B): bash 5.2's patsub_replacement turns an unquoted '&' in a ${v//pat/rep} replacement into
# the matched text — a project root, cwd or HOME holding '&' became another prefix ("/w/R$PROJECTD"),
# and every Read under it asked.
gc6() {  # gc6 <file> <cwd> <CLAUDE_PROJECT_DIR> [HOME] -> out
  # MSYS2_ARG_CONV_EXCL: MSYS would rewrite a /w/… argument to C:/Program Files/Git/w/… for jq.exe.
  out=$(MSYS2_ARG_CONV_EXCL='*' jq -nc --arg f "$1" --arg c "$2" '{tool_name:"Read",tool_input:{file_path:$f},cwd:$c,session_id:"gc6"}' \
    | CLAUDE_PROJECT_DIR="$3" HOME="${4:-$HOME}" BRAIN_DIR="$GW" bash "$SCRIPT" 2>"$GW/err"); gw_rc=$?
}
gc6 '/w/R&D/repo/.claude/worktrees/r3-ro/x.sh' '/w/R&D/repo/.claude/worktrees/r3-mt' '/w/R&D/repo'
gw_silent || fail "GC6: a Read under a project root holding '&' must be in scope (rc=$gw_rc, got: $out)"
gc6 '/w/R&D/proj/a.txt' '/w/R&D/proj' ''
gw_silent || fail "GC6: a Read under a cwd holding '&' must be in scope (rc=$gw_rc, got: $out)"
gc6 '/h/a&b/knowledge/x.md' '/w/proj' '' '/h/a&b'
gw_silent || fail "GC6: a Read under \$HOME/knowledge with '&' in HOME must be in scope (rc=$gw_rc, got: $out)"
pass "GC6: '&' in the project root, cwd or HOME keeps its scope root"
rm -rf "$GW"

# G1 MSYS mounts: cygpath spells a drive path under a mount by the mount's name (%TEMP% is /tmp),
# and the full logic finds it in scope there. The fast path, which spells drive paths /x/…, must
# stand down for such a path rather than ask (a false ask on every Read of the temp dir).
if [ -r /proc/mounts ] && command -v cygpath >/dev/null 2>&1 && W2_TMP=$(cygpath -m /tmp 2>/dev/null) \
   && case "$W2_TMP" in [A-Za-z]:/*) true ;; *) false ;; esac; then
  W2=$(mktemp -d)
  out=$(MSYS2_ARG_CONV_EXCL='*' jq -nc --arg f "$W2_TMP/g1-w2.txt" '{tool_name:"Read",tool_input:{file_path:$f},cwd:"C:\\Workplace\\proj",session_id:"w2"}' \
    | BRAIN_DIR="$W2" bash "$SCRIPT" 2>"$W2/err"); w2_rc=$?
  [ -z "$out" ] && [ "$w2_rc" = 0 ] && [ ! -s "$W2/err" ] \
    || fail "G1 mounts: a Read of $W2_TMP/g1-w2.txt (= /tmp/g1-w2.txt, in scope) must not ask (rc=$w2_rc, got: $out, stderr: $(head -c 300 "$W2/err"))"
  pass "G1 mounts: a drive path under an MSYS mount (the temp dir) gets no false out-of-scope ask"
  rm -rf "$W2"
else
  echo "SKIP: G1 mounts — no MSYS mount table on this host (no drive paths to respell)"
fi

# --- G3 (R3, 2026-10-07): a failed rules read is not "no rules" ------------------------------
# _ptg_rules_data's jq failing came back as an empty RD: the unchecked default read went on to
# `exit 0` (resource scope and every rule off the fast path silently disarmed), and the layered read
# called it "failed the lock invariant", deleted the cache and rebuilt (live: 62 such rows, 2 "STILL
# fails"). Stand-ins for a jq that fails (killed, out of memory): one failing only when it names
# the default rules file twice (the default read), one failing on every rules-file read.
G3=$(mktemp -d); mkdir -p "$G3/dup" "$G3/rules" "$G3/brain/.injected" "$G3/nolib/scripts"
G3_JQ=$(command -v jq)
printf '#!/bin/sh\nn=0\nfor a in "$@"; do case "$a" in *persona-rules.default.json) n=$((n+1)) ;; esac; done\n[ "$n" -ge 2 ] && exit 5\nexec "%s" "$@"\n' "$G3_JQ" > "$G3/dup/jq"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *persona-rules.default.json|*.rules-effective.json) exit 5 ;; esac; done\nexec "%s" "$@"\n' "$G3_JQ" > "$G3/rules/jq"
chmod +x "$G3/dup/jq" "$G3/rules/jq"
printf '%s' g3proj > "$G3/brain/.injected/g3.slug"
g3() {  # g3 <stand-in dir, or -> [VAR=val…] -> out, for a benign Bash call (the full logic decides it)
  local p="$PATH"; [ "$1" = - ] || p="$G3/$1:$PATH"; shift
  out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"g3"}' | env "$@" PATH="$p" BRAIN_DIR="$G3/brain" bash "$SCRIPT")
}
g3_ask() {  # g3_ask <label>: out is an ask, and error-log.jsonl names the failed jq read
  [ -n "$out" ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
    || fail "G3 $1: a failed rules read must ask, not pass the call silently (got: '$out')"
  grep -q 'jq exited [0-9]* reading' "$G3/brain/error-log.jsonl" 2>/dev/null \
    || fail "G3 $1: error-log.jsonl must name the failed jq read (got: $(cat "$G3/brain/error-log.jsonl" 2>/dev/null))"
  grep -q 'lock invariant' "$G3/brain/error-log.jsonl" 2>/dev/null \
    && fail "G3 $1: a failed jq is not a lock-invariant failure (error-log: $(cat "$G3/brain/error-log.jsonl"))"
  return 0
}
# (a) SB_RULES_LAYERS=off: the rules file is the default itself, read with --rawfile p and as input.
: > "$G3/brain/error-log.jsonl"; g3 dup SB_RULES_LAYERS=off; g3_ask "layers off"
# (b) lib.sh unsourceable: no layered read at all, the default read is the only one.
cp "$(dirname "$SCRIPT")/persona-rules.default.json" "$G3/nolib/scripts/"
: > "$G3/brain/error-log.jsonl"; g3 dup CLAUDE_PLUGIN_ROOT="$G3/nolib"; g3_ask "default read, no lib.sh"
# (c) Layered: a cache built by a healthy call, then every rules read fails. The cache stays (it was
#     never shown bad), and nothing is called a lock-invariant failure.
: > "$G3/brain/error-log.jsonl"; g3 -
[ -z "$out" ] || fail "G3 (c) precondition: a benign call with a healthy jq is silent (got: $out)"
G3_EFF="$G3/brain/projects/g3proj/.rules-effective.json"
[ -s "$G3_EFF" ] || fail "G3 (c) precondition: the healthy call builds $G3_EFF"
: > "$G3/brain/error-log.jsonl"; g3 rules; g3_ask "layered read"
[ -s "$G3_EFF" ] || fail "G3 (c): a cache that was never shown bad must not be deleted on a failed jq read"
# (d) A jq whose output stops short but exits 0 (a reader cut off): no closing mark, so no verdict.
mkdir -p "$G3/cut"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *persona-rules.default.json) "%s" "$@" | head -n 3; exit 0 ;; esac; done\nexec "%s" "$@"\n' "$G3_JQ" "$G3_JQ" > "$G3/cut/jq"; chmod +x "$G3/cut/jq"
: > "$G3/brain/error-log.jsonl"; g3 cut SB_RULES_LAYERS=off; g3_ask "output cut short"
pass "G3: a failed rules read asks and logs the jq failure (layers off, no lib.sh, layered, cut short), never 'lock invariant', cache kept"
# (e) A default that jq reads fine but that is not JSON: no usable rules, denied (D154's stance).
mkdir -p "$G3/broken/scripts"; printf '{"rules":[' > "$G3/broken/scripts/persona-rules.default.json"
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"g3"}' | CLAUDE_PLUGIN_ROOT="$G3/broken" BRAIN_DIR="$G3/brain" bash "$SCRIPT")
[ -n "$out" ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "G3 (e): a default rules file that is not JSON must deny (no usable rules), not pass (got: '$out')"
pass "G3: a default rules file that is not JSON denies"
# A cache that IS bad is rebuilt in place: its .sig is dropped so sb_rules_effective rebuilds (tmp +
# mv), never deleted first — a concurrent guard that had just been handed the path read a missing file.
# GT6 (R3B): any spelling of it — rm or unlink with any flags, ${EFF}, an mv away, or a truncation.
grep -vE '^[[:space:]]*#' "$SCRIPT" \
  | grep -qE '((^|[^A-Za-z_])(rm|unlink|mv)[[:space:]]+([^;&|#]*[[:space:]])?|>[[:space:]]*)"?\$\{?EFF\}?"?([[:space:];&|)]|$)' \
  && fail "G3: the guard deletes (or empties) the effective-rules cache before rebuilding it (a concurrent reader gets no file)"
pass "G3: a failed cache is rebuilt in place, not deleted"
# GC4 (R3B): a missing jq is not a failed rules read. _fp_jqfail's rule — jq ran and failed: ask; jq
# absent: log and pass (SessionStart's banner reports it) — held for the payload read but not for the
# rules read, so every call the fast path left undecided (every allow) asked. PATH: exec shims for
# what the full logic and lib.sh use, and no jq (on Linux jq shares /usr/bin with grep).
mkdir -p "$G3/nojq"
for t in grep sed cat tr date mkdir dirname head tail cut wc awk sort uniq mv rm uname basename git cygpath readlink realpath; do
  g4_p=$(command -v "$t") || continue
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$g4_p" > "$G3/nojq/$t"; chmod +x "$G3/nojq/$t"
done
PATH="$G3/nojq" "$BASH" -c 'command -v jq' >/dev/null 2>&1 && fail "GC4 precondition: jq must be off the shim PATH"
: > "$G3/brain/error-log.jsonl"
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"g3"}' | PATH="$G3/nojq" BRAIN_DIR="$G3/brain" "$BASH" "$SCRIPT" 2>/dev/null)
[ -z "$out" ] || fail "GC4: with jq missing, a benign call is logged and passes, it does not ask (got: $out)"
grep -q 'jq is not on PATH' "$G3/brain/error-log.jsonl" \
  || fail "GC4: the missing jq must be logged (error-log: $(cat "$G3/brain/error-log.jsonl"))"
pass "GC4: jq missing — the rules cannot be read, the call is logged and passes (jq that ran and failed still asks)"
# P-F1/P-C1: a missing jq stands the rules down, not the two floors below them. A user layer stands
# the fast path down (as an unsigned cache, an 8.3 name or an MSYS-mount respelling does), and the
# full logic's no-jq exit came before the credential-store floor and path-too-long's: a Read of
# ~/.ssh/id_rsa passed with no verdict. A payload the builtins cannot decode (bash < 4.3 decodes
# none; here a duplicated key) is scanned by spelling instead; a benign one still passes.
cp "$(dirname "$SCRIPT")/persona-rules.default.json" "$G3/brain/persona-rules.json"
f1() {  # f1 <payload> -> out, f1_rc (stderr in $G3/f1err)
  : > "$G3/brain/audit-log.jsonl"
  out=$(printf '%s' "$1" | HOME=/home/f1u PATH="$G3/nojq" BRAIN_DIR="$G3/brain" "$BASH" "$SCRIPT" 2>"$G3/f1err"); f1_rc=$?
}
f1_ask() {  # f1_ask <label> <rule>: out is an ask, audited as <rule>
  [ "$f1_rc" = 0 ] && printf '%s' "$out" | grep -q '"permissionDecision":"ask"' \
    || fail "P-F1 $1: with jq missing and a user layer, the call must ask (rc=$f1_rc, got: '$out', stderr: $(head -c 300 "$G3/f1err"))"
  grep -q "\"rule\":\"$2\"" "$G3/brain/audit-log.jsonl" \
    || fail "P-F1 $1: the ask must be audited as $2 (audit: $(cat "$G3/brain/audit-log.jsonl"))"
}
f1 '{"tool_name":"Read","tool_input":{"file_path":"/home/f1u/.ssh/id_rsa"},"cwd":"/w/proj","session_id":"f1"}'
f1_ask "credential Read" credential-read
f1 "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/w/proj/$(printf '%05000d' 0)\"},\"cwd\":\"/w/proj\",\"session_id\":\"f1\"}"
f1_ask "5000-character target" path-too-long
f1 '{"tool_name":"Read","tool_input":{"file_path":"/w/proj/a.txt","file_path":"/home/f1u/.ssh/id_rsa"},"cwd":"/w/proj","session_id":"f1"}'
f1_ask "undecodable payload" credential-read
f1 '{"tool_name":"Read","tool_input":{"file_path":"/w/proj/a.txt","file_path":"/w/proj/b.txt"},"cwd":"/w/proj","session_id":"f1"}'
[ -z "$out" ] && [ "$f1_rc" = 0 ] || fail "P-F1: an undecodable benign Read with jq missing is logged and passes (rc=$f1_rc, got: $out)"
f1 '{"tool_name":"Read","tool_input":{"file_path":"/w/proj/a.txt"},"cwd":"/w/proj","session_id":"f1"}'
[ -z "$out" ] && [ "$f1_rc" = 0 ] && [ ! -s "$G3/f1err" ] \
  || fail "P-F1: a benign Read with jq missing is logged and passes (rc=$f1_rc, got: $out, stderr: $(head -c 300 "$G3/f1err"))"
rm -f "$G3/brain/persona-rules.json"
pass "P-F1: jq missing — the credential-store Read floor and path-too-long's still ask (decoded or by spelling); benign Reads pass"
rm -rf "$G3"

# --- G2 (R3, 2026-10-07): a verdict written past the hook deadline says so --------------------
# hook-timer.sh hands the guard SB_HOOK_LATE_MS (its start + budget - 2000 ms). A verdict row
# written at or past it carries extra.late:true: Claude Code had likely cancelled the hook and run
# the call, so the row records an ask that enforced nothing. Budget 2 puts the deadline at the
# wrapper's own start (every verdict is late); budget 60 puts it out of reach. Both the fast path's
# row (_fp_audit) and the full logic's (sb_log_audit: a user rules file stands the fast path down).
if [ -n "${EPOCHREALTIME:-}" ]; then
  G2=$(mktemp -d); mkdir -p "$G2/fast" "$G2/full"
  cp "$(dirname "$SCRIPT")/persona-rules.default.json" "$G2/full/persona-rules.json"
  for b in fast full; do
    for budget in 2 60; do
      : > "$G2/$b/audit-log.jsonl"
      printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"},"cwd":"/home/u/proj","session_id":"g2"}' \
        | BRAIN_DIR="$G2/$b" bash "$(dirname "$SCRIPT")/hook-timer.sh" "$budget" "$SCRIPT" >/dev/null
      g2_row=$(grep '"verdict":"ask"' "$G2/$b/audit-log.jsonl" | head -1)
      [ -n "$g2_row" ] || fail "G2 $b, budget $budget: no verdict row (audit: $(cat "$G2/$b/audit-log.jsonl"))"
      g2_want=false; [ "$budget" = 2 ] && g2_want=true
      [ -n "$g2_row" ] && printf '%s' "$g2_row" | jq -e --argjson w "$g2_want" '((.extra.late // false) == $w)' >/dev/null \
        || fail "G2 $b, budget $budget: extra.late must be $g2_want: $g2_row"
    done
  done
  grep -q '"fastpath":true' "$G2/fast/audit-log.jsonl" || fail "G2: the fast brain's verdict must come from the fast path"
  grep -q '"fastpath":true' "$G2/full/audit-log.jsonl" && fail "G2: the full brain's verdict must come from the full logic"
  pass "G2: a verdict row past hook-timer's deadline carries extra.late (fast path and full logic); one before it does not"
  rm -rf "$G2"
else
  echo "SKIP: G2 late stamp — no EPOCHREALTIME (bash < 5): no clock without a process"
fi

# --- perf (R3, 2026-10-07) + GS5/GT1 (R3B): the verdict, then its row from this process -------
# The full logic's sb_log_audit (~7 process creations) ran before the verdict was printed; R3 moved
# it into a detached job, which no test read (every case ran SB_GUARD_LOG_SYNC=on) and which is lost
# with a hook the CLI kills. Now the row is _fp_audit's, written after the verdict and before exit:
# builtins, no lib.sh, no fork. Run as production runs it — SB_GUARD_LOG_SYNC off, through hook-timer
# with budget 2 (deadline = its start, so the verdict is late) — with a jq stand-in that sleeps 30 s
# for sb_log_audit's row jq (given `--arg target`): the guard returns at once, its row already on
# disk, the full logic's (no fastpath marker), stamped late. A user rules file stands the fast path
# down.
PF=$(mktemp -d); mkdir -p "$PF/bin" "$PF/brain"
cp "$(dirname "$SCRIPT")/persona-rules.default.json" "$PF/brain/persona-rules.json"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in target) sleep 30; break ;; esac; done\nexec "%s" "$@"\n' "$(command -v jq)" > "$PF/bin/jq"
chmod +x "$PF/bin/jq"
printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"},"cwd":"/home/u/proj","session_id":"pf"}' > "$PF/p.json"
pf_s=$SECONDS
out=$(SB_GUARD_LOG_SYNC=off BRAIN_DIR="$PF/brain" PATH="$PF/bin:$PATH" bash "$(dirname "$SCRIPT")/hook-timer.sh" 2 "$SCRIPT" < "$PF/p.json")
pf_s=$(( SECONDS - pf_s ))
printf '%s' "$out" | grep -q '"permissionDecision":"ask"' || fail "perf: the full logic must still ask for an out-of-scope Read (got: $out)"
[ "$pf_s" -lt 25 ] || fail "perf: the guard waited ${pf_s}s for a jq (sb_log_audit's sleeps 30 s): its row must not need one"
pf_row=$(grep '"verdict":"ask"' "$PF/brain/audit-log.jsonl" 2>/dev/null)
[ -n "$pf_row" ] || fail "GS5: the ask's audit row must be on disk when the guard returns (audit: $(cat "$PF/brain/audit-log.jsonl" 2>/dev/null))"
[ -n "$pf_row" ] && printf '%s' "$pf_row" | jq -e '.rule == "resource-scope-out-of-scope" and .session_id == "pf" and (.extra.fastpath | not)' >/dev/null \
  || fail "GS5: the row must be the full logic's resource-scope ask (no fastpath marker): $pf_row"
if [ -n "${EPOCHREALTIME:-}" ]; then
  [ -n "$pf_row" ] && printf '%s' "$pf_row" | jq -e '.extra.late == true' >/dev/null || fail "GT1: a verdict past hook-timer's deadline must be stamped late: $pf_row"
else
  echo "SKIP: GT1 late stamp — no EPOCHREALTIME (bash < 5): no clock without a process"
fi
pass "perf/GS5: production mode — the guard returned in ${pf_s}s, its row already on disk (full logic, late)"

# --- Payload size: every verdict must arrive before the 5 s hook timeout ---------------------
# bounded LABEL LIMIT PAYLOAD-FILE [VAR=val…]: run the guard in the background, stdout to a file,
# a watchdog killing it past LIMIT seconds — a hung guard must FAIL the test, not hang it. BD_OUT;
# BD_MS = elapsed ms (EPOCHREALTIME on bash 5; whole seconds from `date` on older bash, the macOS
# lane); BD_EL = whole seconds. The guard must exit 0 (a crash is not a verdict). LIMIT is only the
# kill; every run must also answer within HOOK_BOUND_MS. Runs use a UTF-8 locale when there is one
# (DA #3: the multibyte payloads exist to hit bash's wide-character slow paths, which the C locale a
# bare CI shell starts in never takes).
SZ=$(mktemp -d)
UTF8_LOC=""
for l in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  [ "$( (LC_ALL=$l; s=$'\303\251'; printf %s "${#s}") 2>/dev/null)" = 1 ] && { UTF8_LOC=$l; break; }
done
[ -n "$UTF8_LOC" ] || echo "SKIP: no UTF-8 locale — the size cases below run in the C locale, off the wide-character paths"
now_ms() { local n="${EPOCHREALTIME:-}"; n="${n//[!0-9]/}"; if [ -n "$n" ]; then echo $((10#$n / 1000)); else echo $(( $(date +%s) * 1000 )); fi; }
bounded() {
  local label="$1" lim="$2" pf="$3" pid wd rc t0; shift 3
  t0=$(now_ms)
  env BRAIN_DIR="$SZ" ${UTF8_LOC:+LC_ALL=$UTF8_LOC} "$@" bash "$SCRIPT" < "$pf" > "$SZ/bounded.out" 2> "$SZ/bounded.err" & pid=$!
  # TERM, then KILL 2 s later: a guard blocked writing a pipe on MSYS ignores TERM, and `wait` on it
  # never returned — the test hung until run-all's timeout with no message (final review, 0.54.1).
  ( sleep "$lim"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 & wd=$!
  wait "$pid"; rc=$?
  BD_MS=$(( $(now_ms) - t0 )); BD_EL=$((BD_MS / 1000))
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ "$BD_MS" -lt $((lim * 1000)) ] || fail "$label: still running after ${lim}s (killed)"
  [ "$rc" = 0 ] || fail "$label: the guard exited $rc ($(head -c 300 "$SZ/bounded.err"))"
  # Every size case must answer inside the hook budget (item F8/DA #6: the old 10 s lock let a
  # 9 s answer pass while production cancelled it at 5 s).
  [ "$BD_MS" -le "$HOOK_BOUND_MS" ] || fail "$label: answered in ${BD_MS} ms, bound $HOOK_BOUND_MS ms — past it the hook is cancelled and the tool RUNS"
  BD_OUT=$(cat "$SZ/bounded.out")
}
# within LABEL MS: the last bounded run answered inside MS milliseconds.
within() { [ "$BD_MS" -le "$2" ] || fail "$1: answered in ${BD_MS} ms, bound $2 ms — past it the hook is cancelled and the tool RUNS"; }
# The hook timeout is 5 s; hook-timer.sh, bash's start and the spawn under a loaded box take the
# rest: a case that must answer in time is bound at 4 s. BIG_BOUND stays the kill limit.
HOOK_BOUND_MS=4000
# run_v PAYLOAD [VAR=val…]: a VERDICT/argument-log run — the guard on PAYLOAD, BD_OUT set, killed at
# BIG_BOUND, with NO 4 s hook-budget assertion. For the G3 danger-window cases, which lock the verdict
# (a bound raised past 32,767 re-opens the fail-open) and the "cygpath never over 4096" invariant, not
# timing: a long path's hook budget is already covered by the item-18 16/32 KB `bounded` cases, and a
# 35 KB path answers in ~1.5 s but has thin margin at the tail of a loaded suite.
run_v() {
  local pf="$1" pid wd; shift
  # Background + watchdog kill, NOT the `timeout` binary: macOS has no `timeout` (only gtimeout), so a
  # `timeout …` here errored on the macos bash-3.2 lane and left BD_OUT empty. Mirrors bounded() minus
  # the 4 s hook-budget assertion — these cases lock the verdict and the cygpath argument bound.
  env BRAIN_DIR="$SZ" ${UTF8_LOC:+LC_ALL=$UTF8_LOC} "$@" bash "$SCRIPT" < "$pf" > "$SZ/rv.out" 2>/dev/null & pid=$!
  ( sleep "$BIG_BOUND"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 & wd=$!
  wait "$pid" 2>/dev/null
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  BD_OUT=$(cat "$SZ/rv.out")
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
within "RR-CR1 50,000 trailing newlines" "$HOOK_BOUND_MS"
# The command is past the 16 KiB read, so the ask must be the full logic's.
grep -q '"rule":"warn-rm-rf"' "$SZ/audit-log.jsonl" || fail "RR-CR1: the ask was not audit-logged"
grep -q '"fastpath":true' "$SZ/audit-log.jsonl" \
  && fail "RR-CR1: a command past the 16 KiB read cannot be the fast path's to answer (audit: $(head -c 400 "$SZ/audit-log.jsonl"))"
pass "RR-CR1: 50,000 consecutive trailing newlines answered in ${BD_MS} ms (rm -rf still asks, full logic)"

# F8 #1: the same run INSIDE the command, text after it. The `($_fp_nl+)$` regex the trim used
# was O(run^2) on glibc for this shape: 24 s for this payload on Debian (MSYS: linear, 1.3 s).
printf '{"session_id":"cr1i","tool_name":"Bash","tool_input":{"command":"rm -rf ~/proj%s#"}}' "$TRAIL50K" > "$SZ/cr1i.json"
rm -f "$SZ/audit-log.jsonl"
bounded "F8 50,000 interior newlines, rm -rf" "$BIG_BOUND" "$SZ/cr1i.json"
is_ask "$BD_OUT" || fail "F8: rm -rf with 50,000 interior newlines must still ask (got: $BD_OUT)"
within "F8 50,000 interior newlines" "$HOOK_BOUND_MS"
pass "F8: 50,000 newlines inside the command answered in ${BD_MS} ms (rm -rf still asks)"

# DA #1: escape-dense values. _fp_str walked one bash iteration per escaped quote / escape
# (~110-120 us each on MSYS): 100k \" took 10.8 s, 150k 'a\n' lines 6.5 s, past the timeout. Past
# _fp_emax escapes the value is jq's now.
QD=$(printf '%100000s' '' | sed 's/ /\\"a/g')
printf '{"session_id":"da1","tool_name":"Bash","tool_input":{"command":"echo %s; rm -rf /tmp/da1"}}' "$QD" > "$SZ/da1q.json"
bounded "DA #1 300 KB quote-dense command" "$BIG_BOUND" "$SZ/da1q.json"
is_ask "$BD_OUT" || fail "DA #1: a 300 KB \\\"-dense command ending in rm -rf must ask (got: $BD_OUT)"
within "DA #1 300 KB quote-dense command" "$HOOK_BOUND_MS"
pass "DA #1: a 300 KB command of 100k escaped quotes asks in ${BD_MS} ms"
NLD=$(printf '%150000s' '' | sed 's/ /a\\n/g')
printf '{"session_id":"da1","tool_name":"Bash","tool_input":{"command":"echo %s; rm -rf /tmp/da1"}}' "$NLD" > "$SZ/da1n.json"
bounded "DA #1 150k-line command" "$BIG_BOUND" "$SZ/da1n.json"
is_ask "$BD_OUT" || fail "DA #1: a 150k-line command ending in rm -rf must ask (got: $BD_OUT)"
within "DA #1 150k-line command" "$HOOK_BOUND_MS"
pass "DA #1: a 450 KB command of 150k 'a\\n' lines asks in ${BD_MS} ms"
QD1M=$(printf '%333333s' '' | sed 's/ /\\"a/g')
printf '{"session_id":"da1","tool_name":"Write","tool_input":{"content":"%s","file_path":"/x/persona-rules.json"}}' "$QD1M" > "$SZ/da1w.json"
rm -f "$SZ/audit-log.jsonl"
bounded "DA #1 1 MB quote-dense Write" "$BIG_BOUND" "$SZ/da1w.json" SB_RESOURCE_SCOPE=off
is_ask "$BD_OUT" && grep -q '"rule":"warn-direct-write-hot-tier"' "$SZ/audit-log.jsonl" \
  || fail "DA #1: a 1 MB quote-dense Write to persona-rules.json must ask via warn-direct-write-hot-tier (got: $BD_OUT)"
within "DA #1 1 MB quote-dense Write" "$HOOK_BOUND_MS"
pass "DA #1: a 1 MB Write of 333k escaped quotes to persona-rules.json asks in ${BD_MS} ms"

# F8 item 18: long Write paths with capitals (a Windows long path reaches 32,767 characters). The fast
# path lowers the path it matches rules on; its per-character _fp_lower took 1.8 s at 16 KB on MSYS
# (25 s on bash 3.2). 16 KB still fits the fast path's read; 32 KB goes to the full logic.
for n in 16000 32000; do
  PAD=$(printf '%*s' "$n" '' | tr ' ' A)
  printf '{"session_id":"i18","tool_name":"Write","tool_input":{"file_path":"/X/Users/Me/%s/persona-rules.json","content":"x"}}' "$PAD" > "$SZ/i18-$n.json"
  rm -f "$SZ/audit-log.jsonl"
  bounded "item 18: $n-character Write path" "$BIG_BOUND" "$SZ/i18-$n.json" SB_RESOURCE_SCOPE=off
  is_ask "$BD_OUT" && grep -q '"rule":"warn-direct-write-hot-tier"' "$SZ/audit-log.jsonl" \
    || fail "item 18: a $n-character Write path to persona-rules.json must ask via warn-direct-write-hot-tier (got: $BD_OUT)"
  pass "item 18: a $n-character Write path of capitals asks in ${BD_MS} ms"
done
# The drive form (C:/…) of the 32 KB path also goes through _ptg_norm's one cygpath -u on Windows.
printf '{"session_id":"i18d","tool_name":"Write","tool_input":{"file_path":"C:/Users/Me/%s/persona-rules.json","content":"x"}}' "$PAD" > "$SZ/i18-drive.json"
rm -f "$SZ/audit-log.jsonl"
bounded "item 18: 32,000-character drive-form Write path" "$BIG_BOUND" "$SZ/i18-drive.json" SB_RESOURCE_SCOPE=off
is_ask "$BD_OUT" && grep -q '"rule":"warn-direct-write-hot-tier"' "$SZ/audit-log.jsonl" \
  || fail "item 18: a 32,000-character C:/ Write path to persona-rules.json must ask via warn-direct-write-hot-tier (got: $BD_OUT)"
pass "item 18: a 32,000-character C:/ Write path asks in ${BD_MS} ms"

# F8 item 18 (spine): with an "implement" phase, an 8,185-character command of ';' goes through the
# intent spine's ${v//pat/rep} passes — 2.4 s on bash 3.2 (O(matches x length^2) below 4.3). There
# the spine now stops at 1,024 characters (no flip, the degraded direction); newer bash still reads
# 8,192 and flips on the vitest run.
SEMIS=$(printf '%8170s' '' | tr ' ' ';')
printf '{"session_id":"i18s","tool_name":"Bash","tool_input":{"command":"vitest run %s"}}' "$SEMIS" > "$SZ/i18s.json"
mkdir -p "$SZ/.injected"; printf 'implement' > "$SZ/.injected/i18s.phase"
bounded "item 18: 8,181-character command through the intent spine" "$BIG_BOUND" "$SZ/i18s.json"
if bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }'; then
  [ "$(cat "$SZ/.injected/i18s.phase")" = implement ] || fail "item 18: bash < 4.3 must not evaluate an 8,181-character command in the spine"
else
  [ "$(cat "$SZ/.injected/i18s.phase")" = verify ] || fail "item 18: an 8,181-character vitest run must still flip the phase on bash >= 4.3"
fi
pass "item 18: an 8,181-character ';' command through the intent spine answered in ${BD_MS} ms"

# G3 (0.54.1 final review, CRITICAL): the full logic handed a drive path of any length to cygpath -u,
# which truncates a path longer than 32,767 characters at its input and still exits 0 (MSYS2, 2026-10-01) — the
# file name at the end of a 40,000-character path was gone before any rule saw it, and the Write
# passed. Past 4096 characters a target keeps its lexical spelling (no cygpath), every rule still
# applies, and a call no rule asks about is asked about anyway (path-too-long). The stub behaves as
# the real tool does, so this runs on every lane; its argument log locks the bound itself.
CUTBIN=$(mktemp -d); : > "$CUTBIN/args.log"
cat > "$CUTBIN/cygpath" <<'EOF'
#!/bin/sh
[ "$1" = -u ] && shift
for p in "$@"; do
  printf '%s\n' "${#p}" >> "$CYG_LOG"
  case "$p" in
    [A-Za-z]:/*) d=$(printf '%s' "$p" | cut -c1 | tr 'A-Z' 'a-z'); p="/$d$(printf '%s' "$p" | cut -c3-)" ;;
  esac
  printf '%s\n' "$p" | cut -c1-32767
done
EOF
chmod +x "$CUTBIN/cygpath"
P40K=$(printf '%40000s' '' | tr ' ' a)
P4K=$(printf '%4000s' '' | tr ' ' a)
printf '{"session_id":"g3a","tool_name":"Write","tool_input":{"file_path":"C:/Users/Me/%s/persona-rules.json","content":"x"}}' "$P40K" > "$SZ/g3a.json"
printf '{"session_id":"g3b","tool_name":"Write","tool_input":{"file_path":"C:/Users/Me/%s/notes.txt","content":"x"}}' "$P40K" > "$SZ/g3b.json"
printf '{"session_id":"g3c","tool_name":"Write","tool_input":{"file_path":"C:/Users/Me/%s/notes.txt","content":"x"}}' "$P4K" > "$SZ/g3c.json"
rm -f "$SZ/audit-log.jsonl"
run_v "$SZ/g3a.json" SB_RESOURCE_SCOPE=off PATH="$CUTBIN:$PATH" CYG_LOG="$CUTBIN/args.log"
is_ask "$BD_OUT" && grep -q '"rule":"warn-direct-write-hot-tier"' "$SZ/audit-log.jsonl" \
  || fail "G3: a 40,000-character C:/ Write path to persona-rules.json must ask via warn-direct-write-hot-tier — the rules saw a cut path (got: $BD_OUT)"
pass "G3: a 40,000-character C:/ path keeps its file name for the rules"
rm -f "$SZ/audit-log.jsonl"
run_v "$SZ/g3b.json" SB_RESOURCE_SCOPE=off PATH="$CUTBIN:$PATH" CYG_LOG="$CUTBIN/args.log"
is_ask "$BD_OUT" && grep -q '"rule":"path-too-long"' "$SZ/audit-log.jsonl" \
  || fail "G3: a 40,000-character C:/ Write path no rule matches must still ask (path-too-long), got: $BD_OUT"
pass "G3: a 40,000-character benign C:/ path asks (path-too-long)"
G3_MAX=$(sort -n "$CUTBIN/args.log" | tail -1)
[ "${G3_MAX:-0}" -le 4096 ] || fail "G3: cygpath was handed a ${G3_MAX}-character argument — past 4096 a path must keep its lexical spelling"
pass "G3: no cygpath argument past 4096 characters (longest: ${G3_MAX:-none})"
: > "$CUTBIN/args.log"
run_v "$SZ/g3c.json" SB_RESOURCE_SCOPE=off PATH="$CUTBIN:$PATH" CYG_LOG="$CUTBIN/args.log"
[ -z "$BD_OUT" ] || fail "G3: a 4,022-character benign C:/ path is under the bound and must pass (got: $BD_OUT)"
G3_MAX=$(sort -n "$CUTBIN/args.log" | tail -1)
[ "${G3_MAX:-0}" -ge 4000 ] || fail "G3: under the bound a C:/ target must still go through cygpath (longest argument: ${G3_MAX:-none})"
pass "G3: under 4096 characters a C:/ path still goes through cygpath and passes"
# G3 danger window (test-review gap 1): the two cases above only pin the bound at 4,022 and 40,000, so
# ANY bound in between — including one above 32,767 that re-opens the exact fail-open — would pass. Pin
# the edges and one value inside the cygpath-cut zone. P4096 is exactly 4096 chars (12 prefix + 4074 +
# 10 "/notes.txt"); P4097 one more; P35K a 35,000-char Write to persona-rules.json (> 32,767, so a bound
# raised that far would hand cygpath the cut path and the rule would miss the file name).
PAD4074=$(printf '%4074s' '' | tr ' ' a)
printf '{"session_id":"g3e","tool_name":"Write","tool_input":{"file_path":"C:/Users/Me/%s/notes.txt","content":"x"}}' "$PAD4074" > "$SZ/g3e.json"
printf '{"session_id":"g3f","tool_name":"Write","tool_input":{"file_path":"C:/Users/Me/%sa/notes.txt","content":"x"}}' "$PAD4074" > "$SZ/g3f.json"
PAD34969=$(printf '%34969s' '' | tr ' ' a)
printf '{"session_id":"g3g","tool_name":"Write","tool_input":{"file_path":"C:/Users/Me/%s/persona-rules.json","content":"x"}}' "$PAD34969" > "$SZ/g3g.json"
: > "$CUTBIN/args.log"
run_v "$SZ/g3e.json" SB_RESOURCE_SCOPE=off PATH="$CUTBIN:$PATH" CYG_LOG="$CUTBIN/args.log"
[ -z "$BD_OUT" ] || fail "G3: a 4096-character path is NOT over the bound and must pass silently — a lowered bound would ask (got: $BD_OUT)"
G3_MAX=$(sort -n "$CUTBIN/args.log" | tail -1)
[ "${G3_MAX:-0}" -ge 4096 ] || fail "G3: a 4096-character path must still reach cygpath (bound lowered? longest arg: ${G3_MAX:-none})"
pass "G3: a path at exactly the 4096 bound still goes through cygpath and passes"
rm -f "$SZ/audit-log.jsonl"; : > "$CUTBIN/args.log"
run_v "$SZ/g3f.json" SB_RESOURCE_SCOPE=off PATH="$CUTBIN:$PATH" CYG_LOG="$CUTBIN/args.log"
is_ask "$BD_OUT" && grep -q '"rule":"path-too-long"' "$SZ/audit-log.jsonl" \
  || fail "G3: a 4097-character path is one over the bound and must ask (path-too-long), got: $BD_OUT"
G3_MAX=$(sort -n "$CUTBIN/args.log" | tail -1)
[ "${G3_MAX:-0}" -le 4096 ] || fail "G3: a 4097-character path must NOT reach cygpath (got arg ${G3_MAX})"
pass "G3: one character over the bound asks and never reaches cygpath"
rm -f "$SZ/audit-log.jsonl"; : > "$CUTBIN/args.log"
run_v "$SZ/g3g.json" SB_RESOURCE_SCOPE=off PATH="$CUTBIN:$PATH" CYG_LOG="$CUTBIN/args.log"
is_ask "$BD_OUT" && grep -q '"rule":"warn-direct-write-hot-tier"' "$SZ/audit-log.jsonl" \
  || fail "G3: a 35,000-character C:/ Write to persona-rules.json must ask via warn-direct-write-hot-tier — a bound above 32,767 would feed cygpath a cut path and miss the file name (got: $BD_OUT)"
G3_MAX=$(sort -n "$CUTBIN/args.log" | tail -1)
[ "${G3_MAX:-0}" -le 4096 ] || fail "G3: a 35,000-character path must keep its lexical spelling, not reach cygpath (got arg ${G3_MAX})"
pass "G3: a 35,000-character path (inside the cygpath-cut zone) asks via its rule, never reaching cygpath"
rm -rf "$CUTBIN"
rm -rf "$SZ"

echo
echo "ALL PASS"
