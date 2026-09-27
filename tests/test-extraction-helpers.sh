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

# --- D121: the drainer must use the archived header slug VERBATIM (same
# CR-strip/tmp-collapse as sb_slug_from_dir), not sb_sanitize_slug's
# lowercase/charset rewrite — else it writes a DIFFERENT project dir than the
# one already registered/written by the capture funnel for any slug with
# uppercase, '_' or '.' (the shipped monorepo `root__leaf` form included). ---
sb_call_extractor() {
  local out="$2"
  printf '{"recent_decisions":["drainer test decision"],"open_blockers":[],"cross_refs":[],"files_touched":[],"persona_signals":[]}' > "$out"
  return 0
}
sb_extract_transcript "$TX" "Mono__Api" >/dev/null 2>&1
[ -f "$BRAIN_DIR/projects/Mono__Api/PROJECT.md" ] \
  && ok "D121: verbatim slug Mono__Api resolves to projects/Mono__Api/" \
  || no "D121: Mono__Api did not land in projects/Mono__Api/ (sanitized elsewhere?)"
[ ! -d "$BRAIN_DIR/projects/mono-api" ] \
  && ok "D121: no split-brain sanitized sibling dir (mono-api) created" \
  || no "D121: split-brain sanitized sibling dir 'mono-api' was created"
grep -q "drainer test decision" "$BRAIN_DIR/projects/Mono__Api/PROJECT.md" 2>/dev/null \
  && ok "D121: delta merged into the verbatim-slug PROJECT.md" \
  || no "D121: delta not found in projects/Mono__Api/PROJECT.md"

# --- D121 edge: a bare "." or ".." header must not resolve outside projects/ ---
sb_extract_transcript "$TX" ".." >/dev/null 2>&1 || true
[ ! -e "$BRAIN_DIR/PROJECT.md" ] \
  && ok "D121: '..' slug rejected, no escape to BRAIN_DIR/PROJECT.md" \
  || no "D121: '..' slug escaped to BRAIN_DIR/PROJECT.md"

# --- security: a malicious project_slug must NOT escape BRAIN_DIR (path traversal) ---
EVIL_TARGET="/tmp/sb-pwned-$$/PROJECT.md"
rm -rf "/tmp/sb-pwned-$$" 2>/dev/null || true
sb_extract_transcript "$TX" "../../../../tmp/sb-pwned-$$" >/dev/null 2>&1 || true
[ ! -e "$EVIL_TARGET" ] && ok "traversal slug does not escape BRAIN_DIR" || no "traversal slug ESCAPED to $EVIL_TARGET"
rm -rf "/tmp/sb-pwned-$$" 2>/dev/null || true

# --- extract returns non-zero when the LLM yields nothing ---
sb_call_extractor() { : > "$2"; return 1; }
sb_extract_transcript "$TX" "my-proj" && no "extract fails on empty LLM" || ok "extract fails on empty LLM"

# --- DR-1 (Slice 1 §5.4): the drainer passes --session from the archive header, and a seeded
# .prov file makes the Handoff stamp reflect the ORIGINAL session's epoch (not drainer merge
# time) -- a back-dated handoff must not look fresh. ---
TX_DR1="$BRAIN_DIR/transcripts/sessDRAIN01_dr-proj_2026-05-24.txt"
cat > "$TX_DR1" <<'EOF'
--- session-meta ---
session_id: sessDRAIN01
project_slug: dr-proj
date: 2026-05-24
tool_count: 1
line_count: 5
---

USER: hello
ASSISTANT: hi
EOF
mkdir -p "$BRAIN_DIR/.injected"
printf '1789000000\tabc1234\tmain' > "$BRAIN_DIR/.injected/sessDRAIN01.prov"
sb_call_extractor() {
  local out="$2"
  printf '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[],"handoff":{"in_flight":"dr-1 probe","failed_approaches":[],"pointers":[]}}' > "$out"
  return 0
}
sb_extract_transcript "$TX_DR1" "dr-proj" >/dev/null 2>&1
PROJ_DR="$BRAIN_DIR/projects/dr-proj/PROJECT.md"
DR1_STAMP=$(awk '/^## Handoff$/{f=1;next} /^## /{f=0} f && /^written: /{print; exit}' "$PROJ_DR")
case "$DR1_STAMP" in
  "written: t=1789000000 session=sessDRAI"*) ok "DR-1: drainer stamp uses the archive's .prov epoch (back-dated, not fresh)" ;;
  *) no "DR-1: unexpected stamp: $DR1_STAMP" ;;
esac

# --- DR-2: the drainer's merge call uses the SAME merge_plan carry guard as in-session capture
# -- an existing unfinished item the stub's plan omits is carried, not dropped. ---
printf '%s' '{"plan":["[ ] drainer-kept"]}' \
  | bash "$SCRIPT_DIR/merge-project-update.sh" --project-md "$PROJ_DR" --knowledge-dir "$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR" >/dev/null 2>&1
sb_call_extractor() {
  local out="$2"
  printf '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[],"plan":["[ ] a fresh drainer item"]}' > "$out"
  return 0
}
sb_extract_transcript "$TX_DR1" "dr-proj" >/dev/null 2>&1
grep -qE '^- \[ \] \[carried [0-9]{4}-[0-9]{2}-[0-9]{2}\] drainer-kept$' "$PROJ_DR" \
  && ok "DR-2: the drainer's merge carries an omitted unfinished item (same guard as in-session)" \
  || no "DR-2: drainer-kept was not carried (got: $(awk '/^## Plan$/{f=1;next} /^## /{f=0} f' "$PROJ_DR"))"

# --- DR-3: a subagent_result: true archive carries the PARENT's session id -- --session must
# NOT be passed, so the Handoff stamp has no session= token. ---
TX_DR3="$BRAIN_DIR/transcripts/sub-sessDRAIN01_dr-proj_2026-05-24.txt"
cat > "$TX_DR3" <<'EOF'
--- session-meta ---
session_id: sessDRAIN01
project_slug: dr-proj
subagent_result: true
date: 2026-05-24
tool_count: 1
line_count: 5
---

USER: hello
ASSISTANT: hi
EOF
sb_call_extractor() {
  local out="$2"
  printf '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[],"handoff":{"in_flight":"dr-3 probe","failed_approaches":[],"pointers":[]}}' > "$out"
  return 0
}
sb_extract_transcript "$TX_DR3" "dr-proj" >/dev/null 2>&1
DR3_STAMP=$(awk '/^## Handoff$/{f=1;next} /^## /{f=0} f && /^written: /{print; exit}' "$PROJ_DR")
case "$DR3_STAMP" in
  *"session="*) no "DR-3: subagent archive stamp carries a session= token: $DR3_STAMP" ;;
  "written: t="*) ok "DR-3: subagent archive stamp carries no session= token" ;;
  *) no "DR-3: unexpected stamp: $DR3_STAMP" ;;
esac

# --- SF-M3: sb_session_prov_write fails LOUD on write-path errors, not silently -----------
ERRLOG="$BRAIN_DIR/error-log.jsonl"
: > "$ERRLOG"
sb_session_prov_write 'bad!sid' "$SANDBOX" || true
[ -f "$BRAIN_DIR/.injected/bad!sid.prov" ] && no "SF-M3: a bad-charset sid still wrote a .prov file" || ok "SF-M3: a bad-charset sid writes no .prov file"
grep -q 'sid failed the charset guard' "$ERRLOG" 2>/dev/null && ok "SF-M3: bad-sid charset failure logged loud" || no "SF-M3: bad-sid charset failure was silent"

: > "$ERRLOG"
rm -rf "$BRAIN_DIR/.injected" 2>/dev/null || true
touch "$BRAIN_DIR/.injected"   # a FILE at this path -- mkdir -p must fail, not silently no-op
sb_session_prov_write 'mkdirfailsid' "$SANDBOX" || true
grep -q 'mkdir .*\.injected failed' "$ERRLOG" 2>/dev/null && ok "SF-M3: mkdir failure logged loud" || no "SF-M3: mkdir failure was silent (got: $(cat "$ERRLOG" 2>/dev/null))"
rm -f "$BRAIN_DIR/.injected"
mkdir -p "$BRAIN_DIR/.injected"

: > "$ERRLOG"
sb_session_prov_write 'goodsid12345' "$SANDBOX" || true
[ -f "$BRAIN_DIR/.injected/goodsid12345.prov" ] && ok "SF-M3: a valid sid still writes .prov (no regression)" || no "SF-M3: a valid sid failed to write .prov"

# --- F2 (portability): sb_timeout's bash-watchdog fallback must not hold the caller open
# past the wrapped command's own real runtime. sb_timeout looks up its bounding binary via
# exactly `command -v timeout` / `command -v gtimeout` -- shadow ONLY that lookup with a
# function (real PATH untouched, so date/sleep/rm/the EXIT trap all keep working normally;
# no MSYS ln -s deep-copy risk, no risk of nuking the dir that also holds date/sleep).
command() {
  if [ "${1:-}" = "-v" ] && { [ "${2:-}" = "timeout" ] || [ "${2:-}" = "gtimeout" ]; }; then
    return 1
  fi
  builtin command "$@"
}
F2_START=$(date +%s)
echo hi | sb_timeout 2 true >/dev/null 2>&1 || true
F2_END=$(date +%s)
unset -f command
F2_ELAPSED=$((F2_END - F2_START))
[ "$F2_ELAPSED" -le 1 ] && ok "F2: bash-watchdog fallback returns fast (${F2_ELAPSED}s, not the full 2s+ bound)" \
  || no "F2: bash-watchdog fallback took ${F2_ELAPSED}s, expected <=1s"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
