#!/usr/bin/env bash
# Behavioral tests for the /second-brain:maintain drain loop-control contract.
#
# The stop/redispatch decision currently lives ONLY as prose in
#   skills/maintain/SKILL.md   (Stage 2: loop, up to 30 iterations)
#   agents/raw-drainer.md      (Step 5: final "DRAINED: <n>  REMAINING: <m>" line)
# so there is no source file to import. This test pins that prose down as an
# executable reference implementation (sb_parse_report + sb_drain_loop) and drives
# it with SCRIPTED worker outputs, asserting the real control-flow EFFECT:
#   - dispatch count, the stop reason, and the fail-loud report text.
# If the prose contract changes, this reference impl must change with it, and the
# scripted-sequence assertions below will catch a mismatch.
#
# POSIX/bash-3.2/BSD-safe: no mapfile, no `local x=$(...)` return-masking,
# no GNU-only flags.
set -u
fail(){ echo "FAIL: $1"; exit 1; }
pass(){ echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Reference implementation of the documented contract (kept identical to prose).
# ---------------------------------------------------------------------------

# sb_parse_report <worker-output-text>
# Echoes "<n> <m>" when the literal report line `DRAINED: <n>  REMAINING: <m>`
# (agents/raw-drainer.md Step 5) is present and numeric; echoes nothing and
# returns 1 when no parseable line is found (the "died / no line" case).
sb_parse_report() {
  line=$(printf '%s\n' "$1" | grep -oE 'DRAINED:[[:space:]]*[0-9]+[[:space:]]+REMAINING:[[:space:]]*[0-9]+' | tail -1)
  [ -n "$line" ] || return 1
  n=$(printf '%s\n' "$line" | sed -E 's/.*DRAINED:[[:space:]]*([0-9]+).*/\1/')
  m=$(printf '%s\n' "$line" | sed -E 's/.*REMAINING:[[:space:]]*([0-9]+).*/\1/')
  printf '%s %s\n' "$n" "$m"
  return 0
}

# sb_drain_loop  — drives the loop over scripted worker outputs.
# Worker outputs are provided in the global array WORKER_OUT (one element per
# dispatch). Sets globals on return:
#   DISPATCHES  — how many worker dispatches happened
#   STOP_REASON — drained-zero | remaining-zero | cap | no-line | exhausted
#   REPORT      — human report text (fail-loud on cap / consecutive no-line)
# Contract (skills/maintain/SKILL.md Stage 2):
#   * stop when DRAINED (n) == 0  -> drained-zero
#   * stop when REMAINING (m) == 0 -> remaining-zero
#   * otherwise redispatch
#   * hard cap 30 iterations: if still REMAINING>0 -> stop + fail-loud (names count)
#   * no parseable line: dispatch once more; if the SECOND CONSECUTIVE dispatch
#     also has no line -> stop + report (don't loop blind)
sb_drain_loop() {
  DISPATCHES=0; STOP_REASON=""; REPORT=""
  consec_no_line=0
  last_m=""
  i=0
  while [ "$i" -lt 30 ]; do
    i=$((i + 1))
    idx=$((DISPATCHES))            # 0-based index into the scripted outputs
    out="${WORKER_OUT[$idx]:-}"
    DISPATCHES=$((DISPATCHES + 1))

    if parsed=$(sb_parse_report "$out"); then
      consec_no_line=0
      n=${parsed%% *}
      m=${parsed##* }
      last_m="$m"
      if [ "$n" -eq 0 ]; then STOP_REASON="drained-zero"; return 0; fi
      if [ "$m" -eq 0 ]; then STOP_REASON="remaining-zero"; return 0; fi
      # else: progress made, more remain -> loop again
    else
      consec_no_line=$((consec_no_line + 1))
      if [ "$consec_no_line" -ge 2 ]; then
        STOP_REASON="no-line"
        REPORT="STALL: two consecutive worker dispatches returned no parseable DRAINED/REMAINING line"
        return 0
      fi
      # first unparseable dispatch -> dispatch once more
    fi
  done

  # Reached the 30-iteration hard cap with REMAINING still > 0 -> fail loud.
  STOP_REASON="cap"
  REPORT="STALL: hit 30-iteration cap with REMAINING: ${last_m:-unknown} still > 0 — inspect with /second-brain:capture --list"
  return 0
}

# ---------------------------------------------------------------------------
# Test 1 — parser: every literal report-line shape -> the documented decision.
# ---------------------------------------------------------------------------
decide() { # echoes stop|redispatch|no-line for a single worker output
  if p=$(sb_parse_report "$1"); then
    nn=${p%% *}; mm=${p##* }
    if [ "$nn" -eq 0 ] || [ "$mm" -eq 0 ]; then echo stop; else echo redispatch; fi
  else
    echo no-line
  fi
}

[ "$(decide 'DRAINED: 0  REMAINING: 5')" = stop ]       || fail "DRAINED:0 REMAINING:5 should stop"
[ "$(decide 'DRAINED: 0  REMAINING: 0')" = stop ]       || fail "DRAINED:0 REMAINING:0 should stop"
[ "$(decide 'DRAINED: 3  REMAINING: 7')" = redispatch ] || fail "DRAINED:3 REMAINING:7 should redispatch"
[ "$(decide 'worker crashed, no report at all')" = no-line ] || fail "absent line should be no-line"
[ "$(decide 'DRAINED: x  REMAINING: y')" = no-line ]    || fail "malformed (non-numeric) line should be no-line"
# Report line embedded in a larger report (real workers prepend a summary).
[ "$(decide 'Created foo, updated bar.
DRAINED: 2  REMAINING: 4')" = redispatch ] || fail "embedded redispatch line not parsed"
[ "$(decide 'all done
DRAINED: 4  REMAINING: 0')" = stop ] || fail "embedded remaining-0 line should stop"
pass "parser: literal report-line shapes map to stop/redispatch/no-line per prose"

# ---------------------------------------------------------------------------
# Test 2 — happy path: ['5/9','4/5','0/5'] -> dispatch exactly 3 then stop.
# ---------------------------------------------------------------------------
WORKER_OUT=(
  'DRAINED: 5  REMAINING: 9'
  'DRAINED: 4  REMAINING: 5'
  'DRAINED: 0  REMAINING: 5'
)
sb_drain_loop
[ "$DISPATCHES" -eq 3 ]             || fail "happy path: expected 3 dispatches, got $DISPATCHES"
[ "$STOP_REASON" = drained-zero ]   || fail "happy path: expected stop reason drained-zero, got $STOP_REASON"
pass "loop: [5/9,4/5,0/5] -> dispatches exactly 3 then stops on DRAINED:0"

# ---------------------------------------------------------------------------
# Test 2b — REMAINING hits 0 mid-stream stops even with DRAINED>0.
# ---------------------------------------------------------------------------
WORKER_OUT=(
  'DRAINED: 5  REMAINING: 3'
  'DRAINED: 3  REMAINING: 0'
  'DRAINED: 9  REMAINING: 9'   # must NOT be reached
)
sb_drain_loop
[ "$DISPATCHES" -eq 2 ]             || fail "remaining-0: expected 2 dispatches, got $DISPATCHES"
[ "$STOP_REASON" = remaining-zero ] || fail "remaining-0: expected stop reason remaining-zero, got $STOP_REASON"
pass "loop: REMAINING:0 stops the loop even when DRAINED>0"

# ---------------------------------------------------------------------------
# Test 3 — never hits DRAINED:0 -> stops at exactly 30 with fail-loud report.
# ---------------------------------------------------------------------------
WORKER_OUT=()
k=0
while [ "$k" -lt 40 ]; do WORKER_OUT[$k]='DRAINED: 1  REMAINING: 8'; k=$((k + 1)); done
sb_drain_loop
[ "$DISPATCHES" -eq 30 ]   || fail "cap: expected exactly 30 dispatches, got $DISPATCHES"
[ "$STOP_REASON" = cap ]   || fail "cap: expected stop reason cap, got $STOP_REASON"
echo "$REPORT" | grep -q '30-iteration cap' || fail "cap: report must mention the 30-iteration cap, got: $REPORT"
echo "$REPORT" | grep -q 'REMAINING: 8'     || fail "cap: fail-loud report must name the remaining count, got: $REPORT"
pass "loop: never-DRAINED:0 stops at exactly 30 with fail-loud report naming REMAINING"

# ---------------------------------------------------------------------------
# Test 4 — one no-line dispatch -> dispatch once more (recovers if next parses).
# ---------------------------------------------------------------------------
WORKER_OUT=(
  'worker died — no report'
  'DRAINED: 0  REMAINING: 2'
)
sb_drain_loop
[ "$DISPATCHES" -eq 2 ]           || fail "single no-line: expected 2 dispatches, got $DISPATCHES"
[ "$STOP_REASON" = drained-zero ] || fail "single no-line: should recover then stop drained-zero, got $STOP_REASON"
pass "loop: a single no-line dispatch redispatches once more (then proceeds normally)"

# ---------------------------------------------------------------------------
# Test 5 — TWO consecutive no-line dispatches -> stop after the 2nd, report.
# ---------------------------------------------------------------------------
WORKER_OUT=(
  'worker died — no report'
  'still nothing parseable here'
  'DRAINED: 0  REMAINING: 0'   # must NOT be reached
)
sb_drain_loop
[ "$DISPATCHES" -eq 2 ]      || fail "double no-line: expected stop after 2nd dispatch, got $DISPATCHES"
[ "$STOP_REASON" = no-line ] || fail "double no-line: expected stop reason no-line, got $STOP_REASON"
echo "$REPORT" | grep -qi 'two consecutive' || fail "double no-line: report must flag two-consecutive stall, got: $REPORT"
pass "loop: two consecutive no-line dispatches stop after the 2nd (no blind loop)"

# ---------------------------------------------------------------------------
# Test 6 — no-line then a PARSEABLE line resets the consecutive counter.
# (proves the counter is *consecutive*, not cumulative)
# ---------------------------------------------------------------------------
WORKER_OUT=(
  'no report 1'
  'DRAINED: 2  REMAINING: 6'   # parseable -> resets counter, redispatch
  'no report 2'                # first no-line again (counter was reset)
  'DRAINED: 0  REMAINING: 6'   # stop
)
sb_drain_loop
[ "$DISPATCHES" -eq 4 ]           || fail "reset: expected 4 dispatches, got $DISPATCHES"
[ "$STOP_REASON" = drained-zero ] || fail "reset: expected drained-zero, got $STOP_REASON"
pass "loop: a parseable dispatch resets the consecutive-no-line counter"

echo; echo "ALL PASS"
