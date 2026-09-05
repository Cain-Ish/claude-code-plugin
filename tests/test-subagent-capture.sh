#!/bin/bash
# pins: SB_SUBAGENT_CAPTURE — kill-switch test: asserts =off suppresses capture
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

# --- Test 11: subagent floods must NOT evict main-session archives (adversarial-
# review finding). A busy multi-agent session can write many sub- files; they get
# their OWN prune budget so they can never crowd out real session memory.
# Cross-OS note: each run_hook call spawns bash+jq several times; on Windows/
# Git-Bash that costs ~2s/call so 60 calls (the original loop) runs ~120s and
# times out.  We override SB_SUBAGENT_ARCHIVE_CAP=5 and use 7 calls (cap+2) to
# prove the cap enforces WITHOUT blowing the 90s wall-clock budget. ---
B="$TMP/b11"; mkdir -p "$B/transcripts"; T="$TMP/t11.jsonl"; mk_transcript "$T" 1 "$LONG"
echo "PRECIOUS MAIN SESSION ARCHIVE" > "$B/transcripts/s1_repo_2026-01-01.txt"  # old, must survive
T11_CAP=5  # small cap so we only need cap+2 = 7 calls to prove the cap fires
# write cap+2 distinct substantive subagent results (> the cap)
for i in $(seq 1 $((T11_CAP + 2))); do
  run_hook "$B" "general-purpose" "aid${i}" "$T" SB_SUBAGENT_ARCHIVE_CAP="$T11_CAP" >/dev/null 2>&1
done
[ -f "$B/transcripts/s1_repo_2026-01-01.txt" ] || fail "11: main-session archive was EVICTED by a subagent flood"
grep -q "PRECIOUS" "$B/transcripts/s1_repo_2026-01-01.txt" || fail "11: main-session archive corrupted"
SUBN=$(ls "$B/transcripts/"sub-*.txt 2>/dev/null | wc -l | tr -d ' ')
[ "$SUBN" -le "$T11_CAP" ] || fail "11: subagent archives exceeded their own cap (got $SUBN, cap $T11_CAP)"
pass "subagent flood capped separately (got $SUBN sub-files); main-session archive survived"

# --- Test 12 (R1.2, HOOK-5): workflow "holding" stub — the FINAL assistant
# record is tool_use-only (StructuredOutput carries the real answer) and the
# last TEXT block is an interim holding message => must NOT archive.
B="$TMP/b12"; mkdir -p "$B"; T="$TMP/t12.jsonl"
: > "$T"
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do the task"}]}}' >> "$T"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}]}}' >> "$T"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Holding here until the review returns; this filler comfortably exceeds the eighty-character minimum so the pre-R1 gate would have archived it as a result."}]}}' >> "$T"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"StructuredOutput","input":{"result":"the real answer went through the tool call"}}]}}' >> "$T"
run_hook "$B" "general-purpose" "hold1" "$T" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "12: hook must exit 0"
[ -z "$(arc "$B")" ] || fail "12: holding-message stub was archived"
pass "workflow holding-message stub: NOT archived"

# --- Test 13 (R1.2 regression): a final text-only record (real prose result)
# after tool activity still archives — the Test-12 skip must not overreach.
B="$TMP/b13"; mkdir -p "$B"; T="$TMP/t13.jsonl"; mk_transcript "$T" 1 "$LONG"
run_hook "$B" "general-purpose" "real1" "$T" >/dev/null 2>&1
ls "$B/transcripts/"sub-real1_*.txt >/dev/null 2>&1 || fail "13: real final prose result no longer archived"
pass "final text result still archived"

# --- Test 14 (deep-review): a trailing NON-StructuredOutput tool_use after a
# substantive prose result must still archive (the skip is workflow-specific).
B="$TMP/b14"; mkdir -p "$B"; T="$TMP/t14.jsonl"
: > "$T"
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do the task"}]}}' >> "$T"
jq -nc --arg t "$LONG" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' >> "$T"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[]}}]}}' >> "$T"
run_hook "$B" "general-purpose" "trail1" "$T" >/dev/null 2>&1
ls "$B/transcripts/"sub-trail1_*.txt >/dev/null 2>&1 || fail "14: prose result with trailing non-SO tool_use was dropped"
pass "trailing non-StructuredOutput tool_use: prose result still archived"

# --- Test 15 (0.45.0 regression): EMPTY agent_type must NOT archive ------------
# LIVE BUG (2026-08-21): SubagentStop payloads arrived with agent_type empty. The
# self-exclusion loop compares $bare_type against a name list, so an empty value
# matched nothing and capture PROCEEDED — archiving 50 stub files in 12 minutes,
# each containing the PARENT session's own assistant text. That violates the
# "no mining-self" property this hook's header calls load-bearing, and floods the
# extraction queue. Fail closed: if we cannot identify the agent, we cannot prove
# it is not self, so we do not archive.
# Every pre-0.45.0 case in this file supplied a non-empty agent_type, which is
# exactly why a 15-case green suite never saw the production path.
B="$TMP/b15"; mkdir -p "$B"; T="$TMP/t15.jsonl"; mk_transcript "$T" 1 "$LONG"
run_hook "$B" "" "aid15" "$T" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "15: hook must exit 0 even when skipping"
[ -z "$(arc "$B")" ] || fail "15: empty agent_type was archived (self-exclusion failed open)"
pass "empty agent_type: NOT archived (fail closed)"

# --- Test 16 (0.45.0 regression): the PARENT's own transcript must NOT archive --
# Root cause of the same incident: transcript_path pointed at the parent session's
# transcript, so the hook captured the main thread's last assistant message as if
# it were a subagent result. A main-session transcript is named <session_id>.jsonl,
# so basename-minus-extension == the payload's session_id is a precise, cheap
# oracle for "this is the parent's transcript, not a subagent's".
B="$TMP/b16"; mkdir -p "$B"; T="$TMP/sess1.jsonl"; mk_transcript "$T" 1 "$LONG"
run_hook "$B" "general-purpose" "aid16" "$T" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "16: hook must exit 0 even when skipping"
[ -z "$(arc "$B")" ] || fail "16: parent-session transcript was archived as a subagent result"
pass "parent-session transcript: NOT archived"

# --- Test 16b: the basename strip must handle BOTH path separators ------------
# SOURCE-SCAN lock, deliberately not a behavioural case. A behavioural test cannot
# reach this branch: the payload carries a NATIVE path, and a Windows-form path like
# C:\Users\...\sess1.jsonl does not exist as a file under git-bash, so the hook
# exits at the earlier `[ -f "$TRANSCRIPT" ]` check and the fixture passes for the
# WRONG reason (verified 2026-08-21 — the first draft of this test passed even with
# the backslash strip deleted). A source scan cannot be fooled that way and no env
# override can neuter it.
_SC="$ROOT/scripts/subagent-capture.sh"
if grep -q '_t_base##' "$_SC"; then
  pass "basename strip covers both / and \ separators (source scan)"
else
  fail "16b: subagent-capture.sh no longer strips the BACKSLASH separator when deriving the transcript basename; the parent-transcript guard fails open on Windows path forms"
fi

# --- Test 17: the Test-15/16 guards must not overreach ------------------------
# A named agent whose transcript is genuinely its own still archives.
B="$TMP/b17"; mkdir -p "$B"; T="$TMP/subagent-xyz.jsonl"; mk_transcript "$T" 1 "$LONG"
run_hook "$B" "general-purpose" "aid17" "$T" >/dev/null 2>&1
ls "$B/transcripts/"sub-aid17_*.txt >/dev/null 2>&1 || fail "17: legitimate subagent capture was over-blocked"
pass "named agent with own transcript: still archived"

# --- Test 18: the PRODUCTION payload shape — the one Claude Code actually sends ----------
# transcript_path = the PARENT session's file; agent_transcript_path = the subagent's own;
# last_assistant_message = the final text. Every earlier test sent transcript_path pointing at
# the subagent file (a shape Claude Code never emits), so the hook passed for the wrong reason
# while in production the parent-guard fired on EVERY SubagentStop and nothing was ever
# archived (2026-08-23: 97 agent transcripts, 0 archived). This test fails on every prior
# version of the hook.
B="$TMP/b18"; mkdir -p "$B"
PARENT="$TMP/sess18.jsonl"; : > "$PARENT"
SUB="$TMP/agent-sub18.jsonl"; mk_transcript "$SUB" 1 "holding text"
MULTI=$'# Final report\n\nParagraph one carries the real findings of this agent.\n\nParagraph two carries the rest. Both must survive intact.'
jq -nc --arg tp "$PARENT" --arg atp "$SUB" --arg msg "$MULTI" --arg cw "$TMP/repo" \
  '{hook_event_name:"SubagentStop", session_id:"sess18", agent_type:"general-purpose", agent_id:"aid18",
    transcript_path:$tp, agent_transcript_path:$atp, last_assistant_message:$msg, cwd:$cw}' \
  | env BRAIN_DIR="$B" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SCRIPT" >/dev/null 2>&1
F18=$(ls "$B/transcripts/"sub-aid18_*.txt 2>/dev/null | head -1)
[ -n "$F18" ] || fail "18: production-shape SubagentStop (transcript_path=PARENT, agent_transcript_path=SUB) was NOT archived — the hook is reading the wrong field again"
pass "production payload shape (parent transcript_path + agent_transcript_path) archives"
# EC-04: a multi-paragraph result must not be truncated to its last physical line.
[ "$(grep -c 'Paragraph' "$F18")" -eq 2 ] || fail "18b: multi-line last_assistant_message truncated ($(grep -c Paragraph "$F18") of 2 paragraphs kept)"
pass "multi-line final result archived intact (no tail -1 truncation)"

echo; echo "ALL PASS"
