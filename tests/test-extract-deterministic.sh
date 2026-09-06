#!/bin/bash
# Tests scripts/lib.sh:sb_extract_deterministic — the no-LLM capture floor (P1 Task 1).
# It must emit a valid delta JSON with files_touched derived from Edit/Write/MultiEdit
# tool_use, plus a SINGLE grounded summary decision (never a per-message dump —
# Constitution: "if it does not guide a future decision, it does not belong").
unset CLAUDECODE
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

TX="$TMP/transcript.jsonl"
cat > "$TX" <<'EOF'
{"type":"user","message":{"content":"please add feature X"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"src/a.ts"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}
EOF

DELTA=$(sb_extract_deterministic "$TX" 1 3)

[ -n "$DELTA" ] && echo "$DELTA" | jq -e 'type == "object"' >/dev/null 2>&1 || fail "output is not a JSON object: $DELTA"
pass "emits valid JSON object"

[ -n "$DELTA" ] && echo "$DELTA" | jq -e '.files_touched | index("src/a.ts")' >/dev/null 2>&1 || fail "files_touched missing src/a.ts: $DELTA"
pass "files_touched derived from Write tool_use"

N=$(echo "$DELTA" | jq -r '.recent_decisions | length')
[ "$N" = "1" ] || fail "expected exactly 1 summary decision, got $N: $DELTA"
[ -n "$DELTA" ] && echo "$DELTA" | jq -e '.recent_decisions[0] | test("src/a.ts")' >/dev/null 2>&1 || fail "decision not grounded in files: $DELTA"
pass "single grounded summary decision (no per-message trash)"

# Scratch paths excluded; no real files -> empty delta (not noise).
TX2="$TMP/t2.jsonl"
cat > "$TX2" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/scratch.ts"}}]}}
EOF
D2=$(sb_extract_deterministic "$TX2" 1 1)
[ "$(echo "$D2" | jq -r '.files_touched | length')" = "0" ] || fail "scratch path not excluded: $D2"
[ "$(echo "$D2" | jq -r '.recent_decisions | length')" = "0" ] || fail "expected no decision when no real files: $D2"
pass "scratch paths excluded; empty delta when nothing real changed"

# Windows-path boundary: on Windows the raw JSONL file_path is backslash-form ("C:\Work\a.ts").
# The in-session floor must normalize it to forward slashes — same as the drainer twin — so the
# decision is clean + clickable + consistent (the live 0.33.18 capture wrote raw backslashes before).
TX3="$TMP/t3.jsonl"
cat > "$TX3" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"C:\\Work\\proj\\tests\\thing.ts"}}]}}
EOF
D3=$(sb_extract_deterministic "$TX3" 1 1)
[ -n "$D3" ] && echo "$D3" | jq -e '.files_touched | index("C:/Work/proj/tests/thing.ts")' >/dev/null 2>&1 || fail "win path not normalized to forward slashes: $D3"
[ -n "$D3" ] && echo "$D3" | jq -e '.files_touched[0] | test("\\\\") | not' >/dev/null 2>&1 || fail "raw backslash survived in files_touched: $D3"
[ -n "$D3" ] && echo "$D3" | jq -e '.recent_decisions[0] | test("C:/Work/proj/tests/thing.ts")' >/dev/null 2>&1 || fail "decision missing normalized win path: $D3"
pass "Windows backslash paths normalized to forward slashes (in-session twin matches drainer twin)"

# D111: scratch-path filter must catch Windows AppData\Local\Temp and macOS $TMPDIR
# (/var/folders/...) forms, not just the POSIX /tmp|/var/tmp|/proc|/dev|/run anchors.
TX4="$TMP/t4.jsonl"
cat > "$TX4" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"C:\\Users\\bob\\AppData\\Local\\Temp\\claude\\scratch.js"}}]}}
EOF
D4=$(sb_extract_deterministic "$TX4" 1 1)
[ "$(echo "$D4" | jq -r '.files_touched | length')" = "0" ] || fail "D111: Windows AppData\\Local\\Temp path not excluded: $D4"
pass "D111: Windows AppData\\Local\\Temp scratch path excluded"

TX5="$TMP/t5.jsonl"
cat > "$TX5" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/var/folders/zz/abcdef0123/T/scratch.ts"}}]}}
EOF
D5=$(sb_extract_deterministic "$TX5" 1 1)
[ "$(echo "$D5" | jq -r '.files_touched | length')" = "0" ] || fail "D111: macOS \$TMPDIR (/var/folders/...) path not excluded: $D5"
pass "D111: macOS \$TMPDIR (/var/folders/...) scratch path excluded"

# Twin: sb_extract_archived_deterministic (out-of-band drainer) reads preprocessed text,
# not JSONL — same scratch-path exclusion must apply there.
ARCHIVED_TXT="$TMP/archived.txt"
cat > "$ARCHIVED_TXT" <<'EOF'
  [Edit] C:\Users\bob\AppData\Local\Temp\claude\scratch.js
  [Write] /var/folders/zz/abcdef0123/T/scratch.ts
  [Edit] src/real.ts
EOF
DA=$(sb_extract_archived_deterministic "$ARCHIVED_TXT")
[ "$(echo "$DA" | jq -r '.files_touched | length')" = "1" ] || fail "D111 (archived twin): expected only src/real.ts to survive: $DA"
[ -n "$DA" ] && echo "$DA" | jq -e '.files_touched | index("src/real.ts")' >/dev/null 2>&1 || fail "D111 (archived twin): src/real.ts missing: $DA"
pass "D111: archived-transcript twin excludes Windows AppData\\Local\\Temp and macOS \$TMPDIR forms too"

echo "ALL PASS"
