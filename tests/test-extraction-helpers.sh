#!/bin/bash
# Tests for the lib.sh extraction helpers
# shellcheck disable=SC2015  # `cond && ok || no`: ok/no always return 0, so || is never wrongly taken
# shellcheck disable=SC2129  # consecutive >> appends to the state fixture are intentional
# shellcheck disable=SC2317  # sb_call_extractor is overridden as a stub; reached indirectly via sb_extract_transcript
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export BRAIN_DIR="$SANDBOX/brain"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SANDBOX/knowledge"
mkdir -p "$BRAIN_DIR/projects" "$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR/wiki"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
no()   { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || no "$1 — '$2' != '$3'"; }

STATE="$BRAIN_DIR/.extraction-state.jsonl"

echo "=== extraction helpers ==="

# --- done-set ---
: > "$STATE"
printf '{"basename":"a.txt","ts":"t","outcome":"ok"}\n'    >> "$STATE"
printf '{"basename":"b.txt","ts":"t","outcome":"retry"}\n' >> "$STATE"
printf '{"basename":"c.txt","ts":"t","outcome":"error"}\n' >> "$STATE"
sb_extraction_done "a.txt" "$STATE" && ok "done: ok is terminal"   || no "done: ok is terminal"
sb_extraction_done "c.txt" "$STATE" && ok "done: error is terminal" || no "done: error is terminal"
sb_extraction_done "b.txt" "$STATE" && no "done: retry NOT terminal" || ok "done: retry NOT terminal"
sb_extraction_done "z.txt" "$STATE" && no "done: unknown NOT terminal" || ok "done: unknown NOT terminal"

# --- fails count ---
printf '{"basename":"b.txt","ts":"t","outcome":"retry"}\n' >> "$STATE"
eq "fails: two retries for b" "$(sb_extraction_fails b.txt "$STATE")" "2"
eq "fails: none for a"        "$(sb_extraction_fails a.txt "$STATE")" "0"

# --- resilience: a corrupt JSONL line must not break detection ---
CSTATE="$BRAIN_DIR/.corrupt-state.jsonl"
{
  printf '{"basename":"x.txt","ts":"t","outcome":"retry"}\n'
  printf 'GARBAGE NOT JSON\n'
  printf '{"basename":"x.txt","ts":"t","outcome":"error"}\n'
} > "$CSTATE"
sb_extraction_done "x.txt" "$CSTATE" && ok "done: survives a corrupt line" || no "done: survives a corrupt line"
eq "fails: survives a corrupt line" "$(sb_extraction_fails x.txt "$CSTATE")" "1"

# --- slug from header ---
TX="$BRAIN_DIR/transcripts/sess1_my-proj_2026-05-24.txt"
mkdir -p "$BRAIN_DIR/transcripts"
cat > "$TX" <<'EOF'
--- session-meta ---
session_id: sess1
project_slug: my-proj
date: 2026-05-24
tool_count: 3
line_count: 10
---

USER: hello
ASSISTANT: hi
EOF
eq "slug from header" "$(sb_slug_from_archived_transcript "$TX")" "my-proj"

# --- extract one transcript (stub the LLM, run real merge) ---
sb_call_extractor() {  # stub: write a canned delta, succeed
  local out="$2"
  printf '{"recent_decisions":["drained test decision"],"open_blockers":[],"cross_refs":[],"files_touched":[],"persona_signals":[]}' > "$out"
  return 0
}
sb_extract_transcript "$TX" "my-proj" && ok "extract returns 0" || no "extract returns 0"
grep -q "drained test decision" "$BRAIN_DIR/projects/my-proj/PROJECT.md" \
  && ok "extract merged the delta into PROJECT.md" || no "extract merged the delta into PROJECT.md"

# --- security: a malicious project_slug must NOT escape BRAIN_DIR (path traversal) ---
EVIL_TARGET="/tmp/sb-pwned-$$/PROJECT.md"
rm -rf "/tmp/sb-pwned-$$" 2>/dev/null || true
sb_extract_transcript "$TX" "../../../../tmp/sb-pwned-$$" >/dev/null 2>&1 || true
[ ! -e "$EVIL_TARGET" ] && ok "traversal slug does not escape BRAIN_DIR" || no "traversal slug ESCAPED to $EVIL_TARGET"
rm -rf "/tmp/sb-pwned-$$" 2>/dev/null || true

# --- extract returns non-zero when the LLM yields nothing ---
sb_call_extractor() { : > "$2"; return 1; }
sb_extract_transcript "$TX" "my-proj" && no "extract fails on empty LLM" || ok "extract fails on empty LLM"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
