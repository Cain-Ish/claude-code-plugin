#!/bin/bash
# Tests for scripts/subagent-capture.sh — the SubagentStop hook that archives a
# substantive, non-self subagent's FINAL RESULT into ~/.second-brain/transcripts/.
# Each case runs with an isolated BRAIN_DIR sandbox; the script must ALWAYS exit 0
# (a blocking SubagentStop would wedge the parent's fan-out).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/subagent-capture.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$SCRIPT" ] || fail "scripts/subagent-capture.sh not found"

# Build a fake subagent transcript JSONL. $1=outfile $2=ntools(0|1) $3=final-result-text
mk_transcript() {
  local out="$1" ntools="$2" result="$3"
  : > "$out"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do the task"}]}}' >> "$out"
  if [ "$ntools" -ge 1 ]; then
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}]}}' >> "$out"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"hits"}]}}' >> "$out"
  fi
  # final assistant text record (the "return value")
  jq -nc --arg t "$result" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' >> "$out"
}

# Invoke the hook with a controlled BRAIN_DIR + stdin payload.
# args: <brain> <agent_type> <agent_id> <transcript_path> [extra-env...]
run_hook() {
  local brain="$1" atype="$2" aid="$3" tpath="$4"; shift 4
  local payload
  payload=$(jq -nc --arg at "$atype" --arg id "$aid" --arg tp "$tpath" --arg cw "$TMP/repo" --arg sid "sess1" \
    '{hook_event_name:"SubagentStop", agent_type:$at, agent_id:$id, transcript_path:$tp, cwd:$cw, session_id:$sid}')
  printf '%s' "$payload" | env BRAIN_DIR="$brain" CLAUDE_PLUGIN_ROOT="$ROOT" "$@" bash "$SCRIPT"
}
arc() { ls "$1/transcripts/"sub-*.txt 2>/dev/null; }

mkdir -p "$TMP/repo"
LONG="This is a substantial final result from the subagent summarizing real findings worth keeping across sessions, well over the minimum length."

# --- Test 1: substantive non-self => archived ---
B="$TMP/b1"; mkdir -p "$B"; T="$TMP/t1.jsonl"; mk_transcript "$T" 1 "$LONG"
run_hook "$B" "general-purpose" "aid111" "$T" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "1: hook exited non-zero ($RC) — must always exit 0"
F=$(arc "$B"); [ -n "$F" ] || fail "1: substantive non-self subagent was not archived"
grep -q "general-purpose" "$F" || fail "1: meta missing agent_type"
grep -qF "$LONG" "$F" || fail "1: final result text not archived"
# must be result-only, NOT the full transcript (no tool_use names like Grep)
grep -q '"tool_use"' "$F" && fail "1: archived the full transcript, not just the result"
pass "substantive non-self subagent: final result archived (not full transcript)"

# --- Test 2: self agent (dream-runner) => skipped ---
B="$TMP/b2"; mkdir -p "$B"; T="$TMP/t2.jsonl"; mk_transcript "$T" 1 "$LONG"
run_hook "$B" "dream-runner" "aid222" "$T" >/dev/null 2>&1
[ -z "$(arc "$B")" ] || fail "2: dream-runner (self) should be skipped"
pass "self agent dream-runner: skipped"

# --- Test 3: namespaced self => skipped ---
B="$TMP/b3"; mkdir -p "$B"; T="$TMP/t3.jsonl"; mk_transcript "$T" 1 "$LONG"
run_hook "$B" "plugin:second-brain:knowledge-maintainer" "aid333" "$T" >/dev/null 2>&1
[ -z "$(arc "$B")" ] || fail "3: namespaced self agent should be skipped"
pass "namespaced self agent: skipped"

# --- Test 4: below tool-gate (0 tool_use) => skipped ---
B="$TMP/b4"; mkdir -p "$B"; T="$TMP/t4.jsonl"; mk_transcript "$T" 0 "$LONG"
run_hook "$B" "general-purpose" "aid444" "$T" >/dev/null 2>&1
[ -z "$(arc "$B")" ] || fail "4: zero-tool subagent should be skipped"
pass "below tool-gate: skipped"

# --- Test 5: near-empty result (< 80 chars) => skipped (the real 4-byte case) ---
B="$TMP/b5"; mkdir -p "$B"; T="$TMP/t5.jsonl"; mk_transcript "$T" 1 "ok."
run_hook "$B" "general-purpose" "aid555" "$T" >/dev/null 2>&1
[ -z "$(arc "$B")" ] || fail "5: near-empty result should be skipped"
pass "near-empty result: skipped"

# --- Test 6: missing transcript_path => exit 0, no archive ---
B="$TMP/b6"; mkdir -p "$B"
run_hook "$B" "general-purpose" "aid666" "" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "6: missing transcript must exit 0"
[ -z "$(arc "$B")" ] || fail "6: nothing should be archived without a transcript"
pass "missing transcript_path: exit 0, no archive"

# --- Test 7: malformed stdin => exit 0 ---
B="$TMP/b7"; mkdir -p "$B"
printf 'not json at all' | env BRAIN_DIR="$B" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SCRIPT" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "7: malformed stdin must exit 0"
pass "malformed stdin: exit 0"

# --- Test 8: filename keys on agent_id; never collides with main-session archive ---
B="$TMP/b8"; mkdir -p "$B/transcripts"; T="$TMP/t8.jsonl"; mk_transcript "$T" 1 "$LONG"
# pre-seed a main-session archive to prove no overwrite
echo "MAIN" > "$B/transcripts/sess1_repo_2026-05-29.txt"
run_hook "$B" "general-purpose" "aidAAA" "$T" >/dev/null 2>&1
run_hook "$B" "Explore"         "aidBBB" "$T" >/dev/null 2>&1
N=$(ls "$B/transcripts/"sub-*.txt 2>/dev/null | wc -l | tr -d ' ')
[ "$N" -eq 2 ] || fail "8: expected 2 distinct sub- archives (one per agent_id), got $N"
grep -q MAIN "$B/transcripts/sess1_repo_2026-05-29.txt" || fail "8: main-session archive was clobbered"
pass "filename keys on agent_id; main-session archive untouched"

# --- Test 9: kill switch ---
B="$TMP/b9"; mkdir -p "$B"; T="$TMP/t9.jsonl"; mk_transcript "$T" 1 "$LONG"
run_hook "$B" "general-purpose" "aid999" "$T" SB_SUBAGENT_CAPTURE=off >/dev/null 2>&1
[ -z "$(arc "$B")" ] || fail "9: SB_SUBAGENT_CAPTURE=off should skip"
pass "kill switch SB_SUBAGENT_CAPTURE=off: no archive"

# --- Test 10: archive is episodic-parseable (session-meta header + ASSISTANT body) ---
B="$TMP/b10"; mkdir -p "$B"; T="$TMP/t10.jsonl"; mk_transcript "$T" 1 "$LONG"
run_hook "$B" "general-purpose" "aid010" "$T" >/dev/null 2>&1
F=$(arc "$B")
head -1 "$F" | grep -q '^---' || fail "10: archive missing meta header (episodic parseSessionMeta needs it)"
grep -q '^ASSISTANT:' "$F" || fail "10: archive missing ASSISTANT: body marker (episodic parseExchanges needs it)"
pass "archive is episodic-parseable (meta header + ASSISTANT body)"

echo; echo "ALL PASS"
