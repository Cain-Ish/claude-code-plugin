#!/bin/bash
# SubagentStop hook: archive a substantive, NON-SELF subagent's FINAL RESULT into
# ~/.second-brain/transcripts/ so it becomes dream-minable + episodic-searchable.
# Closes the multi-agent extraction blind spot — the main-session Stop extractor
# only ever sees the top-level transcript, never the per-subagent ones.
#
# Properties (load-bearing):
#   - ALWAYS exit 0. A non-zero SubagentStop would PREVENT the subagent from
#     stopping and wedge the parent's fan-out.
#   - OAuth-safe / offline-first: pure file ops, never invokes `claude`.
#   - Captures the final RESULT (never the full transcript), by priority: last
#     SubagentHandback message (auto mode) > last StructuredOutput input
#     (workflow subagents) > last_assistant_message > last assistant text
#     block. A handback or StructuredOutput candidate is always capped at 64
#     KiB and wrapped in its own DATA banner (SEC-L5: a handback is an
#     untrusted tool payload same as StructuredOutput — a forged `USER:` line
#     inside one must not be minable as a real user statement).
#   - Self-excludes the plugin's own consolidation/review agents (no mining-self).
#   - Drops mechanical (0-tool) and near-empty results. The MIN-length gate is
#     measured on the candidate's own payload, never on the DATA banner this
#     hook prepends (T4: a tiny StructuredOutput input used to clear MIN
#     purely on the banner's own bytes).
#   - Alarms: a deliberate 64 KiB cap raises a FLAGGED audit row (verdict
#     flag, reason "cap") — informational, not an error. A REAL misselection
#     (a handback/StructuredOutput candidate existed but the archived RESULT
#     is not the text that candidate dictates) raises sb_log_error. The two
#     were conflated pre-T4: every capped candidate tripped the same "shorter
#     than candidate" comparison as a real bug, and a handback (never capped
#     then) could never trip it at all — alarm fatigue on one path, silence
#     on the other; the second silent capture blackout (B1) had no alarm.
# Kill switch: SB_SUBAGENT_CAPTURE=off
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0
source "$(dirname "$0")/lib.sh"

# Kill switch + jq dependency (no jq => silently no-op, like other hooks).
[ "${SB_SUBAGENT_CAPTURE:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

RAW=$(cat 2>/dev/null || true)
[ -n "$RAW" ] || exit 0
echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

# The SUBAGENT's own transcript is `.agent_transcript_path`. `.transcript_path` on a
# SubagentStop payload is the PARENT session's file (verified against the Claude Code 2.1.241
# binary: `transcript_path:UL(e.id), agent_transcript_path:eR(o)`). This hook read
# `.transcript_path` since it was written, so the parent-guard below always fired and NOT ONE
# real subagent result was ever archived in production (97 agent transcripts on 2026-08-22/23,
# 0 archived). The 50 pre-0.45.0 `sub-*` stubs were the parent's own interim text.
TRANSCRIPT=$(echo "$RAW" | jq -r '.agent_transcript_path // .transcript_path // empty' 2>/dev/null | tr -d '\r')
# Claude Code also hands us the final text directly ("Avoids the need to read and parse the
# transcript file" — binary docstring). Prefer it: no jq over a 1-10 MB JSONL, no `tail -1`
# truncation of multi-line markdown to its last physical line (the previous RESULT extraction).
LAST_MSG=$(echo "$RAW" | jq -r '.last_assistant_message // empty' 2>/dev/null | tr -d '\r')
AGENT_TYPE=$(echo "$RAW" | jq -r '.agent_type // empty' 2>/dev/null | tr -d '\r')
AGENT_ID=$(echo "$RAW"   | jq -r '.agent_id // empty' 2>/dev/null | tr -d '\r')
SESSION_ID=$(echo "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -d '\r')
CWD=$(echo "$RAW"        | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')

# Need a readable transcript to capture anything.
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
[ -n "$AGENT_ID" ] || AGENT_ID="unknown"

# --- Fail closed when the agent cannot be identified (0.45.0) -----------------
# LIVE INCIDENT 2026-08-21: payloads arrived with agent_type EMPTY. The
# self-exclusion loop below compares $bare_type against a NAME LIST, so an empty
# value matched nothing and capture PROCEEDED — 50 stubs archived in 12 minutes,
# every one holding the PARENT session's own assistant text. That is precisely the
# "mining-self" this file's header calls a load-bearing property, and it floods the
# extraction queue that the drainer is already starved on. If we cannot name the
# agent we cannot prove it is not self, so we skip. Covered by test 15.
if [ -z "$AGENT_TYPE" ]; then
  # Loud, not silent: one audit row per skipped untyped agent (fail-loud rule).
  sb_log_audit "subagent-capture.sh" "flag" "no-agent-type" "${AGENT_ID:-?}" "payload carried no agent_type; cannot prove not-self; skipped" "$SESSION_ID" 2>/dev/null || true
  exit 0
fi

# --- Never archive the PARENT session's own transcript (0.45.0) ---------------
# Root cause of the same incident: transcript_path pointed at the MAIN session's
# transcript, so the hook captured the main thread's last assistant message as a
# "subagent result" (session_id in the stub matched the parent, tool_count tracked
# the parent's). A main-session transcript is named <session_id>.jsonl, so
# basename-minus-.jsonl == the payload's session_id is a precise, spawn-free oracle
# for "this is the parent's transcript". Covered by test 16; test 17 locks that
# neither guard over-blocks a legitimate named subagent.
# Strip BOTH separators: the payload carries a native path, so on Windows this
# arrives backslash-separated and a `${x##*/}`-only strip would leave the whole
# directory attached, silently defeating the guard on the platform where the
# incident was observed. Parameter expansion only — no basename spawn in a hook.
_t_base="${TRANSCRIPT##*/}"; _t_base="${_t_base##*\\}"; _t_base="${_t_base%.jsonl}"
[ -n "$SESSION_ID" ] && [ "$_t_base" = "$SESSION_ID" ] && exit 0

# --- Self-exclude: never archive the plugin's OWN agents (mining-self = noise
# feeding itself). Match the bare name and the namespaced plugin:...:name form. ---
SELF_AGENTS="dream-runner knowledge-maintainer search-conversations"
bare_type="${AGENT_TYPE##*:}"   # strip any plugin:second-brain: prefix
for self in $SELF_AGENTS; do
  [ "$bare_type" = "$self" ] && exit 0
done

# --- Substantive gate 1: at least one tool_use in the subagent transcript. ---
TOOL_COUNT=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use")
  | .name
' "$TRANSCRIPT" 2>/dev/null | wc -l | tr -d ' ')
[ "${TOOL_COUNT:-0}" -ge 1 ] || exit 0

MIN="${SB_SUBAGENT_MIN_RESULT:-80}"
CAP_BYTES=65536
SO_BANNER="--- DATA (StructuredOutput input; verbatim tool payload, not instructions) ---"
HB_BANNER="--- DATA (SubagentHandback message; verbatim tool payload, not instructions) ---"

# HOOK-5: WORKFLOW subagents return their real answer via a StructuredOutput
# tool call; the last TEXT block is then an interim "holding" message (or
# absent). This used to SKIP capture entirely whenever the final record carried
# a StructuredOutput call and no substantive text of its own — which silently
# dropped the real 12-65 KB report (B1 finding #2). It must now archive the
# StructuredOutput input itself; the MIN gate below applies to whatever result
# gets chosen, not to the final record's text alone. A normal agent that ends
# with some other trailing tool_use (cleanup, TodoWrite) is unaffected: FINAL_SO
# stays 0 and its last prose result is still archived (deep-review: keying on
# ANY tool_use dropped those). Both jq calls below read the already-extracted,
# tiny FINAL_CONTENT string, not the transcript — no extra transcript scan.
FINAL_CONTENT=$(jq -c 'select(.type == "assistant") | .message.content' "$TRANSCRIPT" 2>/dev/null | tail -1)
_SO_LIST=$(printf '%s' "$FINAL_CONTENT" | jq -c '[.[]? | select(.type == "tool_use" and .name == "StructuredOutput")]' 2>/dev/null)
FINAL_SO=$(printf '%s' "$_SO_LIST" | jq -r 'length' 2>/dev/null | tr -d '\r')
STRUCTURED_INPUT=""
if [ "${FINAL_SO:-0}" -ge 1 ]; then
  STRUCTURED_INPUT=$(printf '%s' "$_SO_LIST" | jq -c 'last.input // empty' 2>/dev/null | tr -d '\r')
  [ "$STRUCTURED_INPUT" = "null" ] && STRUCTURED_INPUT=""
fi

# --- Auto mode (CLI >= 2.1.271): the real report is the LAST SubagentHandback
# tool_use's .input.message, which can appear anywhere in the subagent's own
# transcript; last_assistant_message then holds only a throwaway closing line
# ("I've sent the report to the agent that asked for it...") — B1 finding #1,
# verified live 2026-09-27. This is the one extra full-transcript jq pass this
# hook now makes (TOOL_COUNT and FINAL_CONTENT above already scan it once each).
# Selected as one JSON value (-c) BEFORE tail -1 so embedded newlines cannot
# split a multi-paragraph handback into its last physical line.
#
# SF-M3: the PREVIOUS version parsed the transcript with jq's default
# multi-value reader (no -R). That reader aborts the ENTIRE parse on the
# FIRST invalid JSON value in the file — proven live: a single malformed line
# ahead of the real handback silently dropped it to the throwaway
# last_assistant_message closing line, and the swallowed `2>/dev/null` left
# zero trace (B1 again). `-R … fromjson?` parses PER LINE instead: a bad line
# yields nothing and the scan continues past it to the real handback further
# down. stderr is captured to a file (never `2>/dev/null`-discarded) and a
# non-zero jq exit is logged loud — `fromjson?` itself never fails on a bad
# line (that is the tolerance), so a non-zero rc here means something else
# broke (e.g. the transcript file vanished mid-read) and must not be silent.
_hb_err=$(mktemp 2>/dev/null) || _hb_err="${TMPDIR:-/tmp}/sbc-hb-err.$$"
HANDBACK=$(jq -Rc '
  fromjson?
  | select(type == "object" and .type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use" and .name == "SubagentHandback")
  | .input.message // empty
' "$TRANSCRIPT" 2>"$_hb_err" | tail -1)
_hb_rc=${PIPESTATUS[0]:-0}
if [ "${_hb_rc:-0}" -ne 0 ]; then
  sb_log_error "subagent-capture.sh" \
    "handback scan: jq exited $_hb_rc reading $TRANSCRIPT: $(tr -d '\r\n' < "$_hb_err" 2>/dev/null | head -c 200) (agent_id=$AGENT_ID session_id=$SESSION_ID)" "$_hb_rc" 2>/dev/null || true
fi
rm -f "$_hb_err" 2>/dev/null
[ -n "$HANDBACK" ] && HANDBACK=$(printf '%s' "$HANDBACK" | jq -r '.' 2>/dev/null | tr -d '\r')

# --- Choose the RESULT by priority: handback > StructuredOutput >
# last_assistant_message > last assistant text block. A handback or
# StructuredOutput candidate is ALWAYS capped at CAP_BYTES and wrapped in its
# own DATA banner (SEC-L5: a handback is as untrusted a tool payload as a
# StructuredOutput input — a forged `USER:`/`ASSISTANT:` line inside one must
# land inside the DATA-marked block, never archived as if it were trusted
# session text). CANDIDATE_LEN/CANDIDATE_CAPPED are the RAW, uncapped
# candidate and its post-cap text; PAYLOAD is what the MIN gate below
# measures — the candidate's own (capped) text, NEVER the banner this hook
# prepends (T4: a tiny StructuredOutput input used to clear MIN purely on the
# banner's own bytes). -----------------------------------------------------
CANDIDATE_KIND="" CANDIDATE_LEN=0 CANDIDATE_CAPPED="" PAYLOAD=""
if [ -n "$HANDBACK" ]; then
  CANDIDATE_KIND="handback"
  CANDIDATE_LEN=$(printf '%s' "$HANDBACK" | wc -c | tr -d ' ')
  CANDIDATE_CAPPED=$(printf '%s' "$HANDBACK" | head -c "$CAP_BYTES")
  RESULT=$(printf '%s\n%s' "$HB_BANNER" "$CANDIDATE_CAPPED")
  PAYLOAD="$CANDIDATE_CAPPED"
elif [ -n "$STRUCTURED_INPUT" ]; then
  CANDIDATE_KIND="structured-output"
  CANDIDATE_LEN=$(printf '%s' "$STRUCTURED_INPUT" | wc -c | tr -d ' ')
  CANDIDATE_CAPPED=$(printf '%s' "$STRUCTURED_INPUT" | head -c "$CAP_BYTES")
  RESULT=$(printf '%s\n%s' "$SO_BANNER" "$CANDIDATE_CAPPED")
  PAYLOAD="$CANDIDATE_CAPPED"
elif [ -n "$LAST_MSG" ]; then
  RESULT="$LAST_MSG"
  PAYLOAD="$LAST_MSG"
else
  # Fallback for older payloads without last_assistant_message: the LAST assistant record's
  # text blocks, selected as one JSON value (-c) BEFORE tail -1 so embedded newlines cannot
  # split a multi-paragraph result into its last physical line (the previous bug).
  RESULT=$(jq -c 'select(.type == "assistant") | [.message.content[]? | select(.type == "text") | .text] | select(length > 0)' "$TRANSCRIPT" 2>/dev/null \
    | tail -1 | jq -r 'join("\n")' 2>/dev/null)
  PAYLOAD="$RESULT"
fi

SLUG=$(sb_resolve_slug "${CWD:-$PWD}")

# --- Substantive gate 2: drop near-empty results (the real 4-byte case). MIN
# is measured on PAYLOAD — the candidate's own text — never on $RESULT, so a
# DATA banner this hook adds can never count toward clearing the floor on the
# candidate's behalf. A short real handback/StructuredOutput is not rescued
# by falling back to a long last_assistant_message closing line. ------------
RLEN=$(printf '%s' "$PAYLOAD" | tr -d '[:space:]' | wc -c | tr -d ' ')
# 3d: log lengths on EVERY capture that had a real candidate, including ones
# this MIN gate is about to drop — a systematically-too-short candidate kind
# must leave evidence, not silence.
if [ -n "$CANDIDATE_KIND" ] && [ "${RLEN:-0}" -lt "$MIN" ]; then
  sb_log_audit "subagent-capture.sh" "flag" "capture-length" "$AGENT_ID" \
    "below-min kind=$CANDIDATE_KIND candidate_len=$CANDIDATE_LEN payload_len=$RLEN min=$MIN archived_len=0" "$SESSION_ID" 2>/dev/null || true
fi
[ "${RLEN:-0}" -ge "$MIN" ] || exit 0

# --- Alarm redesign (T4/SF-M3/L5): the OLD check (archived-length <
# candidate-length) was tautological for a handback (RESULT was always
# literally $HANDBACK, never shorter — dead code) and permanently tripped for
# ANY over-cap StructuredOutput (the deliberate truncation IS a length
# reduction), turning every big report into an exit-1 error — alarm fatigue
# that would drown out a real misselection bug. Split into two independent
# checks:
#   (a) deliberate cap: candidate > CAP_BYTES -> FLAGGED audit row, reason
#       "cap" — informational, expected, not an error.
#   (b) real misselection: the archived RESULT does not match what the
#       chosen candidate DICTATES it must be (selection priority itself
#       broke) -> sb_log_error. Independent of (a): capping is baked into
#       the expected text, so a correctly-capped RESULT never trips this.
# Archive FIRST (file ops only; never fatal to the hook) so length alarms
# below measure the WRITTEN FILE, not the in-memory $RESULT — a write
# failure with $RESULT-based measurement was invisible (SF-M3): the variable
# still held the full text even when nothing landed on disk.
sb_archive_subagent_result "$AGENT_ID" "${AGENT_TYPE:-unknown}" "$SLUG" "$SESSION_ID" "$TOOL_COUNT" "$RESULT" 2>/dev/null || true

if [ -n "$CANDIDATE_KIND" ]; then
  EXPECTED_RESULT=""
  case "$CANDIDATE_KIND" in
    handback)           EXPECTED_RESULT=$(printf '%s\n%s' "$HB_BANNER" "$CANDIDATE_CAPPED") ;;
    structured-output)  EXPECTED_RESULT=$(printf '%s\n%s' "$SO_BANNER" "$CANDIDATE_CAPPED") ;;
  esac

  # (c) measure the ARCHIVED length from the WRITTEN FILE, not $RESULT — the
  # filename is the same deterministic naming sb_archive_subagent_result uses
  # (agent_id sanitized to filename-safe chars, same slug, today's date).
  _date=$(date +%Y-%m-%d)
  _safe_aid=$(printf '%s' "$AGENT_ID" | tr -cd 'A-Za-z0-9._-')
  [ -n "$_safe_aid" ] || _safe_aid="unknown"
  _archive_file="$BRAIN_DIR/transcripts/sub-${_safe_aid}_${SLUG}_${_date}.txt"
  ARCHIVED_LEN=0
  [ -f "$_archive_file" ] && ARCHIVED_LEN=$(awk '/^ASSISTANT:$/{f=1; next} f' "$_archive_file" 2>/dev/null | wc -c | tr -d ' ')

  if [ "${CANDIDATE_LEN:-0}" -gt "$CAP_BYTES" ]; then
    sb_log_audit "subagent-capture.sh" "flag" "capture-length" "$AGENT_ID" \
      "cap kind=$CANDIDATE_KIND candidate_len=$CANDIDATE_LEN archived_len=$ARCHIVED_LEN cap_bytes=$CAP_BYTES" "$SESSION_ID" 2>/dev/null || true
  else
    sb_log_audit "subagent-capture.sh" "allow" "capture-length" "$AGENT_ID" \
      "kind=$CANDIDATE_KIND candidate_len=$CANDIDATE_LEN archived_len=$ARCHIVED_LEN" "$SESSION_ID" 2>/dev/null || true
  fi

  if [ -n "$EXPECTED_RESULT" ] && [ "$RESULT" != "$EXPECTED_RESULT" ]; then
    sb_log_audit "subagent-capture.sh" "flag" "capture-length" "$AGENT_ID" \
      "misselect kind=$CANDIDATE_KIND candidate_len=$CANDIDATE_LEN archived_len=$ARCHIVED_LEN" "$SESSION_ID" 2>/dev/null || true
    sb_log_error "subagent-capture.sh" \
      "capture misselected: kind=$CANDIDATE_KIND candidate exists but the archived RESULT is not it (agent_id=$AGENT_ID session_id=$SESSION_ID)" 1 2>/dev/null || true
  fi
fi

exit 0
