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

# --- (g) O2: a huge target / message must still produce exactly ONE well-formed row -------
# A native jq.exe cannot receive a command line over ~32 KB on Windows: a longer --arg value is
# DROPPED and jq writes nothing, so the row was silently lost (the `[ -n "$line" ] &&` guard
# swallowed the empty result). Both writers now cap the free-text args BEFORE they reach jq, with
# a visible marker, and report an empty row instead of dropping it.
BIG=$(head -c 40000 /dev/zero | tr '\0' 'A')
[ "${#BIG}" -eq 40000 ] || fail "(g) could not build the 40 KB fixture"
MARK_RE='[(][+][0-9]+ chars[)]$'
: > "$AUD"; : > "$ERR"
sb_log_audit "big-hook" deny "rule" "$BIG" "short reason" "sid"
[ "$(wc -l < "$AUD" | tr -d ' ')" -eq 1 ] || fail "(g) a 40 KB audit target did not produce exactly one row (got $(wc -l < "$AUD" | tr -d ' '))"
jq -e --arg re "$MARK_RE" '.hook == "big-hook" and (.target | length) <= 300 and (.target | test($re))' "$AUD" >/dev/null \
  || fail "(g) the capped audit target is missing, over 300 chars, or lacks the (+N chars) marker"
: > "$AUD"
sb_log_audit "big-hook" deny "rule" "t" "$BIG" "sid"
[ "$(wc -l < "$AUD" | tr -d ' ')" -eq 1 ] || fail "(g) a 40 KB audit reason did not produce exactly one row"
jq -e --arg re "$MARK_RE" '(.reason | length) <= 5000 and (.reason | test($re))' "$AUD" >/dev/null \
  || fail "(g) the capped audit reason is over 5000 chars or lacks the marker"
sb_log_error "big.sh" "$BIG" 1
[ "$(wc -l < "$ERR" | tr -d ' ')" -eq 1 ] || fail "(g) a 40 KB error message did not produce exactly one row (got $(wc -l < "$ERR" | tr -d ' '))"
jq -e --arg re "$MARK_RE" '.script == "big.sh" and (.message | length) <= 5000 and (.message | test($re))' "$ERR" >/dev/null \
  || fail "(g) the capped error message is over 5000 chars or lacks the marker"
: > "$AUD"
sb_log_audit "small-hook" allow "rule" "short-target" "short reason" "sid"
jq -e '.target == "short-target" and .reason == "short reason"' "$AUD" >/dev/null \
  || fail "(g) a short target/reason was altered by the cap"
pass "(g) 40 KB audit target, audit reason and error message each yield one capped, well-formed row"

# --- (h) O2: a row that still comes out EMPTY is reported, never dropped silently ---------
REAL_JQ_H=$(command -v jq)
SHIM_H="$SANDBOX/jqshim-h"; mkdir -p "$SHIM_H"
cat > "$SHIM_H/jq" <<SHEOF
#!/bin/bash
case "\$*" in
  *'session_id:\$sid'*) [ "\${SHIM_H_FAIL:-}" = audit ] && exit 3 ;;   # the audit row builder: write nothing
  *'exit_code:\$c'*)    [ "\${SHIM_H_FAIL:-}" = error ] && exit 3 ;;   # the error row builder: write nothing
esac
exec "$REAL_JQ_H" "\$@"
SHEOF
chmod +x "$SHIM_H/jq"
: > "$AUD"; : > "$ERR"
( PATH="$SHIM_H:$PATH"; SHIM_H_FAIL=audit; export SHIM_H_FAIL; sb_log_audit "shim-hook" deny "rule" "t" "r" "sid" )
grep -q 'audit row' "$ERR" || fail "(h) an empty audit row left no error row"
: > "$ERR"
( PATH="$SHIM_H:$PATH"; SHIM_H_FAIL=error; export SHIM_H_FAIL; sb_log_error "shim.sh" "lost message" 1 )
[ "$(wc -l < "$ERR" | tr -d ' ')" -eq 1 ] || fail "(h) an empty error row left no fallback row"
jq -e '.script == "lib.sh" and (.message | test("empty"))' "$ERR" >/dev/null \
  || fail "(h) the fallback row is not well-formed JSON saying the row came out empty: $(cat "$ERR")"
pass "(h) a row jq failed to build is reported as an error row, not dropped"

# --- (i) the other lib.sh sites that hand caller text to jq as an argument -------------------
# Same Windows limit as (g), emulated here on every OS: a jq shim that writes NOTHING and exits 3
# when its whole argv is over 30,000 bytes (what a native jq.exe does past ~32 KB). Each site must
# still produce its result from 40 KB of input — capped with a marker, or passed by --rawfile.
REAL_JQ_I=$(command -v jq)
SHIM_I="$SANDBOX/jqshim-i"; mkdir -p "$SHIM_I"
cat > "$SHIM_I/jq" <<SHEOF
#!/bin/bash
n=0; for a in "\$@"; do n=\$((n + \${#a})); done
[ "\$n" -gt 30000 ] && exit 3
exec "$REAL_JQ_I" "\$@"
SHEOF
chmod +x "$SHIM_I/jq"
BIG40=$(head -c 40000 /dev/zero | tr '\0' 'P')

# pin candidate: one capped row, not a silently empty one
PCF="$BRAIN_DIR/projects/pcslug/.pin-candidates.jsonl"; rm -f "$PCF"
( PATH="$SHIM_I:$PATH"; sb_append_pin_candidate pcslug "$BIG40" ) || fail "(i) sb_append_pin_candidate returned non-zero on a 40 KB text"
[ "$(wc -l < "$PCF" | tr -d ' ')" -eq 1 ] || fail "(i) a 40 KB pin candidate did not land as exactly one row"
jq -e --arg re "$MARK_RE" '(.text | length) <= 5000 and (.text | test($re))' "$PCF" >/dev/null \
  || fail "(i) the capped pin-candidate text is over 5000 chars or lacks the (+N chars) marker"

# sessions digest: a 40 KB goal/outcome still lands (the row keeps its first 200 chars)
rm -f "$BRAIN_DIR/sessions-digest.jsonl"
( PATH="$SHIM_I:$PATH"; sb_append_session_digest dgslug sid-1 "$BIG40" "$BIG40" )
jq -e '.slug == "dgslug" and (.goal | length) == 200 and (.outcome | length) == 200' "$BRAIN_DIR/sessions-digest.jsonl" >/dev/null \
  || fail "(i) a 40 KB goal/outcome lost the sessions-digest row: $(head -c 200 "$BRAIN_DIR/sessions-digest.jsonl" 2>&1)"

# local extractor call: a 40 KB system prompt goes in by --rawfile; curl is a stub returning an object
CURL_I="$SANDBOX/curlshim-i"; mkdir -p "$CURL_I"
cat > "$CURL_I/curl" <<'SHEOF'
#!/bin/bash
printf '%s' '{"choices":[{"message":{"content":"{\"decisions\":[\"ok\"]}"}}]}'
SHEOF
chmod +x "$CURL_I/curl"
printf 'some transcript text\n' > "$SANDBOX/local-in.txt"; OUT_I="$SANDBOX/local-out.json"; rm -f "$OUT_I"
( PATH="$CURL_I:$SHIM_I:$PATH"; sb_extractor_local_call "http://stub.invalid" "m" "$BIG40" "$SANDBOX/local-in.txt" "$OUT_I" 20 ) \
  || fail "(i) sb_extractor_local_call failed with a 40 KB system prompt (the jq --arg was dropped whole)"
jq -e '.decisions[0] == "ok"' "$OUT_I" >/dev/null || fail "(i) local call produced no output object"
pass "(i) a 40 KB pin candidate / session-digest goal / local-call system prompt each still produce their result under a 30 KB-argv jq"

echo "ALL PASS"
