#!/usr/bin/env bash
# R7 hook latency telemetry: scripts/hook-timer.sh wraps heavy hook commands
# (hooks.json: bash hook-timer.sh <budget_s> <script> [args…]) and appends
# {kind:"latency", hook, duration_ms, exit_code} to audit-log.jsonl — the R1
# ec=124 timeout class was only diagnosable by forensic log mining; this makes
# per-hook latency a first-class, queryable signal. The wrapper must be
# TRANSPARENT: child stdin/stdout/stderr and exit code pass through untouched,
# and a timer failure (unwritable audit log) must never break the child.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TIMER="$REPO_ROOT/scripts/hook-timer.sh"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$TIMER" ] || fail "scripts/hook-timer.sh does not exist"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export BRAIN_DIR="$SANDBOX/brain"; mkdir -p "$BRAIN_DIR"
AUD="$BRAIN_DIR/audit-log.jsonl"

# Child fixture: echoes stdin, writes stderr, exits with requested code.
CHILD="$SANDBOX/child.sh"
cat > "$CHILD" <<'EOF'
#!/bin/bash
IN=$(cat)
echo "child-stdout:$IN"
echo "child-stderr" >&2
exit "${CHILD_RC:-0}"
EOF
chmod +x "$CHILD"

# --- (a) transparency: stdin/stdout/stderr/rc pass through ------------------
OUT=$(printf 'payload-123' | bash "$TIMER" 60 "$CHILD" 2>"$SANDBOX/err"); rc=$?
[ "$rc" -eq 0 ] || fail "(a) rc not passed through (got $rc)"
[ "$OUT" = "child-stdout:payload-123" ] || fail "(a) stdout altered: $OUT"
grep -q 'child-stderr' "$SANDBOX/err" || fail "(a) stderr swallowed"
pass "(a) wrapper is transparent (stdin/stdout/stderr/rc)"

# --- (b) nonzero child rc passes through ------------------------------------
printf 'x' | CHILD_RC=3 bash "$TIMER" 60 "$CHILD" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] || fail "(b) child rc=3 not propagated (got $rc)"
pass "(b) nonzero exit code propagates"

# --- (c) latency line lands in audit-log with sane fields -------------------
LINE=$(grep '"kind":"latency"' "$AUD" | head -1)
[ -n "$LINE" ] || fail "(c) no latency line in audit-log: $(cat "$AUD" 2>/dev/null)"
[ -n "$LINE" ] && echo "$LINE" | jq -e '.hook == "child.sh" and (.duration_ms | type == "number") and .duration_ms >= 0 and .duration_ms < 60000' >/dev/null \
  || fail "(c) latency line malformed: $LINE"
pass "(c) latency line: hook + numeric duration_ms"

# --- (d) budget warning at >70% of the budget -------------------------------
SLOW="$SANDBOX/slow.sh"; printf '#!/bin/bash\nsleep 1\n' > "$SLOW"; chmod +x "$SLOW"
: > "$AUD"
printf '' | bash "$TIMER" 1 "$SLOW" >/dev/null 2>&1
grep -q '"budget_warn":true' "$AUD" \
  || fail "(d) 1s child against a 1s budget must set budget_warn: $(cat "$AUD")"
pass "(d) >70%-of-budget run flags budget_warn"

# --- (e) fast run does NOT warn ---------------------------------------------
: > "$AUD"
printf '' | bash "$TIMER" 60 "$CHILD" >/dev/null 2>&1
grep -q '"budget_warn":true' "$AUD" && fail "(e) fast child wrongly flagged"
pass "(e) fast run carries no budget_warn"

# --- (f) unwritable audit log never breaks the child ------------------------
OUT=$(printf 'p' | BRAIN_DIR=/nonexistent_dir_zz9 bash "$TIMER" 60 "$CHILD" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "child-stdout:p" ] || fail "(f) timer failure broke the child (rc=$rc out=$OUT)"
pass "(f) fail-open: unwritable audit log, child unaffected"

echo "ALL PASS"
