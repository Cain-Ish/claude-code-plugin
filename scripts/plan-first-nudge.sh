#!/bin/bash
# plan-first-nudge.sh — PreToolUse advisory (spec 2026-06-26 §6 "P5 — Plan-first guardrail").
# A SOFT, ONCE-PER-SESSION nudge toward planning when a session turns into MULTI-FILE coding
# work. Fires the first time the session has made a SUBSTANTIVE edit to its Nth distinct code
# file (N = SB_PLAN_FIRST_FILES, default 2). Stays SILENT for single-file work and one-line
# diffs (a change below SB_PLAN_FIRST_MIN_LINES lines never counts a file toward the threshold).
# Advisory only: emits additionalContext with permissionDecision "allow" — never blocks, never asks.
#
# Limitation (documented, deliberate): a PreToolUse hook cannot observe whether the user already
# used plan mode earlier in the session, so the nudge may occasionally fire after planning already
# happened. It is gentle and fires AT MOST ONCE per session, so the false-positive cost is one
# ignorable line. Detecting prior planning reliably would need a harness signal that does not exist.
#
# Kill switch: SB_PLAN_FIRST_NUDGE=off. No awk (mawk-safe). Fail-soft; always exits 0.
set -u
[ "${SB_PLAN_FIRST_NUDGE:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true); [ -z "$RAW" ] && exit 0
printf '%s' "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')
case "$TOOL" in Write|Edit|MultiEdit) ;; *) exit 0 ;; esac

FP=$(printf '%s' "$RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null | tr -d '\r')
[ -z "$FP" ] && exit 0

# Coding-prompt scope: only source-code files count toward multi-file work. Docs/config/data
# edits (.md/.json/.txt/...) are out of scope for a "plan the code first" nudge.
shopt -s nocasematch 2>/dev/null || true
case "$FP" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py|*.go|*.rs|*.java|*.kt|*.kts|*.c|*.h|*.cc|*.cpp|*.hpp|*.cs|*.rb|*.php|*.swift|*.sh|*.bash|*.lua|*.scala|*.clj|*.ex|*.exs|*.vue|*.svelte|*.sql) ;;
  *) exit 0 ;;
esac
shopt -u nocasematch 2>/dev/null || true

# Lines this change writes = Write.content OR Edit.new_string OR sum of MultiEdit new_strings
# (same accounting as simplicity-gate.sh). One-line diffs fall below MIN_LINES and never count.
LINES=$(printf '%s' "$RAW" | jq -r '
  ((.tool_input.content // .tool_input.new_string // "")
   + "\n"
   + ([.tool_input.edits[]?.new_string // ""] | join("\n")))' 2>/dev/null | grep -c . )
MIN_LINES="${SB_PLAN_FIRST_MIN_LINES:-3}"; case "$MIN_LINES" in ''|*[!0-9]*) MIN_LINES=3 ;; esac
[ "${LINES:-0}" -ge "$MIN_LINES" ] 2>/dev/null || exit 0

THRESH="${SB_PLAN_FIRST_FILES:-2}"; case "$THRESH" in ''|*[!0-9]*) THRESH=2 ;; esac

# State dir under BRAIN_DIR (resolve like lib.sh; Windows git-bash arrives in C:\ form -> cygpath).
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
command -v cygpath >/dev/null 2>&1 && BRAIN_DIR=$(cygpath -u "$BRAIN_DIR" 2>/dev/null || printf '%s' "$BRAIN_DIR")
STATE="$BRAIN_DIR/.plan-nudge"
mkdir -p "$STATE" 2>/dev/null || exit 0
# Opportunistic GC: drop session markers older than a day so the dir can't grow unbounded.
find "$STATE" -type f -mmin +1440 -delete 2>/dev/null || true

# Sanitise session_id into a safe filename component (never let it carry path separators).
SID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null | tr -dc 'A-Za-z0-9_-' | cut -c1-64)
[ -z "$SID" ] && SID="default"

DONE="$STATE/$SID.done"
[ -f "$DONE" ] && exit 0          # already nudged this session — stay silent
SEEN="$STATE/$SID.seen"

# Register this file once (distinct count = non-empty lines, since we only append unseen paths).
grep -qxF "$FP" "$SEEN" 2>/dev/null || printf '%s\n' "$FP" >> "$SEEN"
COUNT=$(grep -c . "$SEEN" 2>/dev/null || echo 0)
[ "${COUNT:-0}" -ge "$THRESH" ] 2>/dev/null || exit 0

: > "$DONE" 2>/dev/null || true   # fire at most once per session

CTX="[Plan-first — think before multi-file work] This session has now made substantive edits to ${COUNT} code files. If you haven't already sketched a plan, consider pausing to plan the change (plan mode, or the brainstorming skill) so the pieces fit before more edits — it reduces code→re-code churn. One-time, advisory nudge; nothing was blocked. Silence: SB_PLAN_FIRST_NUDGE=off."

jq -nc --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    additionalContext: $ctx
  }
}' 2>/dev/null || true

exit 0
