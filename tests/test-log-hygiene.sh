#!/usr/bin/env bash
# R6b (HOOK-9): error-log hygiene.
# (1) gate=* breadcrumbs with exit_code 0 are TRACE, not errors — they belong
#     in audit-log.jsonl (the trajectory channel), not error-log.jsonl, where
#     they were 41% of lines and polluted every "tail the error log" diagnosis
#     plus verify.sh's check-5 freshness signal.
# (2) Both logs rotate at the size cap so unattended boxes never grow them
#     unboundedly (the Pi ran with a 9MB error-log before R6b).
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export BRAIN_DIR="$SANDBOX/brain"; mkdir -p "$BRAIN_DIR"

# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib.sh"

ERR="$BRAIN_DIR/error-log.jsonl"
AUD="$BRAIN_DIR/audit-log.jsonl"

# --- (a) gate= + exit_code 0 routes to audit-log, NOT error-log -------------
sb_log_error "stop-extract.sh" "gate=skip-tiny" 0
[ -s "$ERR" ] && fail "(a) gate=/ec0 breadcrumb landed in error-log.jsonl"
grep -q 'gate=skip-tiny' "$AUD" 2>/dev/null \
  || fail "(a) gate=/ec0 breadcrumb missing from audit-log.jsonl"
jq -e 'select(.message=="gate=skip-tiny") | .script=="stop-extract.sh"' "$AUD" >/dev/null 2>&1 \
  || fail "(a) audit-log trace line is not well-formed JSON with script+message"
pass "(a) gate=/ec0 breadcrumbs route to audit-log.jsonl"

# --- (b) a real error (ec!=0) still lands in error-log ----------------------
sb_log_error "x.sh" "real failure" 1
grep -q 'real failure' "$ERR" 2>/dev/null || fail "(b) real error missing from error-log"
pass "(b) real errors still land in error-log.jsonl"

# --- (c) gate=-prefixed but FAILING (ec!=0) stays an error ------------------
sb_log_error "x.sh" "gate=open but the write failed" 2
grep -q 'gate=open but the write failed' "$ERR" 2>/dev/null \
  || fail "(c) failing gate= line was mis-routed out of error-log"
pass "(c) only exit_code-0 gate= lines are treated as trace"

# --- (d) error-log rotates at the cap; newest lines survive -----------------
: > "$ERR"
i=0
while [ "$i" -lt 4000 ]; do
  printf '{"timestamp":"t","script":"seed","message":"filler-%s-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","exit_code":1}\n' "$i"
  i=$((i+1))
done >> "$ERR"
PRE=$(wc -c < "$ERR" | tr -d ' ')
[ "$PRE" -gt 524288 ] || fail "(d) setup: seed log only ${PRE}B (need >512KB)"
sb_log_error "x.sh" "post-rotation line" 1
POST=$(wc -c < "$ERR" | tr -d ' ')
[ "$POST" -lt "$PRE" ] || fail "(d) error-log did not rotate (${PRE}B -> ${POST}B)"
grep -q 'post-rotation line' "$ERR" || fail "(d) new line missing after rotation"
grep -q 'filler-3999' "$ERR" || fail "(d) rotation dropped the NEWEST old lines (must keep tail)"
grep -q '"filler-0-' "$ERR" && fail "(d) rotation kept the oldest lines (must drop head)"
pass "(d) error-log rotates at 512KB keeping the newest tail"

# --- (e) the trace path applies the AUDIT-LOG's OWN rotation policy ---------
# (5MiB/5000 lines, keep newest half — sb_rotate_audit_log), NOT the 512KB
# error-log cap: the audit-log is the guard-verdict evidence channel with a
# deliberately larger window; the 512KB cap would have truncated ~2MB of live
# verdict evidence on the first routed trace (R6b review finding).
: > "$AUD"
i=0
while [ "$i" -lt 6000 ]; do
  printf '{"ts":"t","hook":"seed","verdict":"allow","rule":"r%s","session_id":"s"}\n' "$i"
  i=$((i+1))
done >> "$AUD"
# 6000 short lines ≈ 400KB: BELOW the 512KB byte cap but ABOVE the 5000-line
# audit cap — only the audit policy rotates here, so survival of the right
# lines proves which policy ran.
sb_log_error "stop-extract.sh" "gate=post-rotation" 0
LINES=$(wc -l < "$AUD" | tr -d ' ')
[ "$LINES" -le 3002 ] || fail "(e) audit policy did not rotate (still $LINES lines)"
grep -q '"r5999"' "$AUD" || fail "(e) rotation dropped the newest audit lines"
grep -q '"r0"' "$AUD" && fail "(e) rotation kept the oldest audit lines"
grep -q 'gate=post-rotation' "$AUD" || fail "(e) new trace missing after rotation"
pass "(e) trace path rotates via the audit-log's own 5000-line policy"

# --- (f) D120: concurrent sb_log_audit appends land intact (no loss, no tears) ---
# On Windows the native jq.exe child writing DIRECTLY to the file via `jq -nc … >>`
# does not get an O_APPEND handle, so two concurrent writers race at the same offset
# and one record's head gets overwritten by another — sometimes leaving a malformed
# fragment line, sometimes (equal-length rows) a CLEAN overwrite with no visible
# corruption at all, just a silently lost row. Two workers x 150 real sb_log_audit
# calls each (matches the reproduction that found the bug) must all survive.
: > "$AUD"
_concurrent_writer() {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/lib.sh"
  local n j
  n="$1"
  for j in $(seq 1 150); do
    sb_log_audit "concurrent-writer-$n" ask "rule" "target-$n-$j" "reason $j" "sid"
  done
}
export -f _concurrent_writer
export REPO_ROOT
( _concurrent_writer A ) &
( _concurrent_writer B ) &
wait
CONC_LINES=$(wc -l < "$AUD" | tr -d ' ')
[ "$CONC_LINES" -eq 300 ] || fail "(f) concurrent sb_log_audit lost rows: got $CONC_LINES of 300"
node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
  let bad = 0;
  for (const l of lines) { try { JSON.parse(l.replace(/\r$/, "")); } catch (e) { bad++; } }
  if (bad > 0) { console.error("malformed=" + bad); process.exit(1); }
' "$AUD" || fail "(f) concurrent sb_log_audit produced torn/malformed JSON lines"
pass "(f) 300 concurrent sb_log_audit appends (2 workers x150) land intact, none lost or torn"

echo "ALL PASS"
