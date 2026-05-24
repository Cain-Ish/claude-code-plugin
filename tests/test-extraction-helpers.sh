#!/bin/bash
# Tests for the lib.sh extraction helpers
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

# --- extract returns non-zero when the LLM yields nothing ---
sb_call_extractor() { : > "$2"; return 1; }
sb_extract_transcript "$TX" "my-proj" && no "extract fails on empty LLM" || ok "extract fails on empty LLM"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
