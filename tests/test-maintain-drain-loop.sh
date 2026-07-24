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

# sb_parse_blame <worker-output-text>
# Echoes the blame class when a `BLAME: <class>` line (agents/raw-drainer.md
# Step 0/Step 5) is present; echoes nothing otherwise. The maintain prose
# requires this to be scanned in EVERY branch — including no-line stalls —
# so a packet refusal's classification is never lost.
sb_parse_blame() {
  printf '%s\n' "$1" | grep -oE 'BLAME:[[:space:]]*(caller-under-supplied|child-under-delivered)' \
    | tail -1 | sed -E 's/BLAME:[[:space:]]*//'
}

# sb_drain_loop  — drives the loop over scripted worker outputs.
# Worker outputs are provided in the global array WORKER_OUT (one element per
# dispatch); POSTFLIGHT_OUT holds the scripted touch-set postflight result for
# the same index ("" = clean, non-empty = offending legacy-wiki paths).
# Sets globals on return:
#   DISPATCHES  — how many worker dispatches happened
#   STOP_REASON — drained-zero | remaining-zero | cap | no-line | no-shrink | postflight-abort
#   REPORT      — human report text (fail-loud on cap / stall / postflight)
#   BLAME       — blame class carried from the last worker output that had one
# Contract (skills/maintain/SKILL.md Stage 2):
#   * after EVERY batch, the touch-set postflight: any *.md newer than the stamp
#     under the legacy wiki -> HARD ABORT (postflight-abort), report names the
#     paths and records BLAME: child-under-delivered
#   * stop when DRAINED (n) == 0  -> drained-zero
#   * stop when REMAINING (m) == 0 -> remaining-zero
#   * otherwise redispatch
#   * no-shrink stall: across SUCCESSFUL batches (parseable, DRAINED>0) REMAINING
#     must STRICTLY DECREASE; the first non-decreasing successful batch arms a
#     counter, the SECOND CONSECUTIVE one stops (no-shrink) with the stuck count
#     named; a decreasing batch resets the counter
#   * hard cap 30 iterations: if still REMAINING>0 -> stop + fail-loud (names count)
#   * no parseable line: dispatch once more; if the SECOND CONSECUTIVE dispatch
#     also has no line -> stop + report (don't loop blind); the BLAME scan runs
#     in this branch too (a Step-0 packet refusal may carry REMAINING: unknown)
sb_drain_loop() {
  DISPATCHES=0; STOP_REASON=""; REPORT=""; BLAME=""
  consec_no_line=0
  last_m=""
  prev_success_m=""   # REMAINING from the last SUCCESSFUL (DRAINED>0) batch
  no_shrink=0         # consecutive successful batches where REMAINING failed to decrease
  i=0
  while [ "$i" -lt 30 ]; do
    i=$((i + 1))
    idx=$((DISPATCHES))            # 0-based index into the scripted outputs
    out="${WORKER_OUT[$idx]:-}"
    pf="${POSTFLIGHT_OUT[$idx]:-}"
    DISPATCHES=$((DISPATCHES + 1))

    b=$(sb_parse_blame "$out"); [ -n "$b" ] && BLAME="$b"

    # Touch-set postflight runs after EVERY batch, before the report decision.
    if [ -n "$pf" ]; then
      STOP_REASON="postflight-abort"
      BLAME="child-under-delivered"
      REPORT="ABORT: legacy-wiki write detected after batch $DISPATCHES: $pf — BLAME: child-under-delivered"
      return 0
    fi

    if parsed=$(sb_parse_report "$out"); then
      consec_no_line=0
      n=${parsed%% *}
      m=${parsed##* }
      last_m="$m"
      if [ "$n" -eq 0 ]; then STOP_REASON="drained-zero"; return 0; fi
      if [ "$m" -eq 0 ]; then STOP_REASON="remaining-zero"; return 0; fi
      # Successful batch (DRAINED>0, REMAINING>0): REMAINING must strictly
      # decrease. First non-decrease arms the counter; second consecutive stops.
      if [ -n "$prev_success_m" ] && [ "$m" -ge "$prev_success_m" ]; then
        no_shrink=$((no_shrink + 1))
        if [ "$no_shrink" -ge 2 ]; then
          STOP_REASON="no-shrink"
          REPORT="STALL: REMAINING stuck at $m across two consecutive successful batches — drained without shrinking; inspect with /second-brain:capture --list"
          return 0
        fi
      else
        no_shrink=0
      fi
      prev_success_m="$m"
      # else: progress made, more remain -> loop again
    else
      consec_no_line=$((consec_no_line + 1))
      if [ "$consec_no_line" -ge 2 ]; then
        STOP_REASON="no-line"
        REPORT="STALL: two consecutive worker dispatches returned no parseable DRAINED/REMAINING line${BLAME:+ — BLAME: $BLAME}"
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
# (REMAINING strictly decreases each batch so the no-shrink stall never arms —
# this fixture isolates the cap.)
# ---------------------------------------------------------------------------
WORKER_OUT=()
k=0
while [ "$k" -lt 40 ]; do WORKER_OUT[$k]="DRAINED: 1  REMAINING: $((100 - k))"; k=$((k + 1)); done
sb_drain_loop
[ "$DISPATCHES" -eq 30 ]   || fail "cap: expected exactly 30 dispatches, got $DISPATCHES"
[ "$STOP_REASON" = cap ]   || fail "cap: expected stop reason cap, got $STOP_REASON"
echo "$REPORT" | grep -q '30-iteration cap' || fail "cap: report must mention the 30-iteration cap, got: $REPORT"
echo "$REPORT" | grep -q 'REMAINING: 71'    || fail "cap: fail-loud report must name the remaining count, got: $REPORT"
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

# ---------------------------------------------------------------------------
# Test 7 — touch-set postflight hit on batch 2 -> HARD ABORT, names the path,
# records BLAME: child-under-delivered. (skills/maintain/SKILL.md Stage 2 step 2)
# ---------------------------------------------------------------------------
WORKER_OUT=(
  'DRAINED: 3  REMAINING: 9'
  'DRAINED: 2  REMAINING: 7'
  'DRAINED: 0  REMAINING: 7'   # must NOT be reached
)
POSTFLIGHT_OUT=(
  ''
  '/home/u/.second-brain/wiki/learnings/leaked.md'
  ''
)
sb_drain_loop
[ "$DISPATCHES" -eq 2 ]               || fail "postflight: expected abort after 2nd dispatch, got $DISPATCHES"
[ "$STOP_REASON" = postflight-abort ] || fail "postflight: expected postflight-abort, got $STOP_REASON"
[ "$BLAME" = child-under-delivered ]  || fail "postflight: expected BLAME child-under-delivered, got '$BLAME'"
echo "$REPORT" | grep -q 'leaked.md'  || fail "postflight: report must name the offending path, got: $REPORT"
pass "loop: legacy-wiki write after a batch hard-aborts with BLAME: child-under-delivered"

# ---------------------------------------------------------------------------
# Test 8 — Step-0 packet refusal with a numeric REMAINING: parses as a normal
# drained-zero stop AND the BLAME classification is captured, not lost.
# ---------------------------------------------------------------------------
WORKER_OUT=(
  'packet missing absolute wiki destination
DRAINED: 0  REMAINING: 4
BLAME: caller-under-supplied'
)
POSTFLIGHT_OUT=('')
sb_drain_loop
[ "$DISPATCHES" -eq 1 ]                || fail "refusal: expected 1 dispatch, got $DISPATCHES"
[ "$STOP_REASON" = drained-zero ]      || fail "refusal: expected drained-zero, got $STOP_REASON"
[ "$BLAME" = caller-under-supplied ]   || fail "refusal: BLAME must be captured, got '$BLAME'"
pass "loop: packet refusal (numeric REMAINING) stops drained-zero with BLAME captured"

# ---------------------------------------------------------------------------
# Test 9 — Step-0 refusal with 'REMAINING: unknown' (unparseable) twice ->
# no-line stall, and the stall report still carries the BLAME class.
# ---------------------------------------------------------------------------
WORKER_OUT=(
  'packet defective
DRAINED: 0  REMAINING: unknown
BLAME: caller-under-supplied'
  'packet defective again
DRAINED: 0  REMAINING: unknown
BLAME: caller-under-supplied'
)
POSTFLIGHT_OUT=('' '')
sb_drain_loop
[ "$DISPATCHES" -eq 2 ]              || fail "unknown-refusal: expected 2 dispatches, got $DISPATCHES"
[ "$STOP_REASON" = no-line ]         || fail "unknown-refusal: expected no-line stall, got $STOP_REASON"
[ "$BLAME" = caller-under-supplied ] || fail "unknown-refusal: BLAME must survive the no-line branch, got '$BLAME'"
echo "$REPORT" | grep -q 'caller-under-supplied' || fail "unknown-refusal: stall report must carry BLAME, got: $REPORT"
pass "loop: unparseable refusal stalls after 2 dispatches with BLAME carried into the report"

# ---------------------------------------------------------------------------
# Test 10 — no-shrink stall: ['2/5','1/5','1/5'] -> the 2nd batch (first
# non-decrease) ARMS the counter, the 3rd (second consecutive) STOPS.
# Exactly 3 dispatches; report names the stuck count.
# ---------------------------------------------------------------------------
WORKER_OUT=(
  'DRAINED: 2  REMAINING: 5'
  'DRAINED: 1  REMAINING: 5'   # first non-decrease -> arms
  'DRAINED: 1  REMAINING: 5'   # second consecutive -> stops
  'DRAINED: 1  REMAINING: 5'   # must NOT be reached
)
POSTFLIGHT_OUT=('' '' '' '')
sb_drain_loop
[ "$DISPATCHES" -eq 3 ]        || fail "no-shrink: expected stop after 3rd dispatch, got $DISPATCHES"
[ "$STOP_REASON" = no-shrink ] || fail "no-shrink: expected stop reason no-shrink, got $STOP_REASON"
echo "$REPORT" | grep -q 'stuck at 5' || fail "no-shrink: report must name the stuck count, got: $REPORT"
pass "loop: [2/5,1/5,1/5] -> first repeat arms, second consecutive stops no-shrink naming 5"

# ---------------------------------------------------------------------------
# Test 11 — recovery: REMAINING resumes decreasing after one non-decrease ->
# counter resets, loop continues to a normal drained-zero stop.
# ---------------------------------------------------------------------------
WORKER_OUT=(
  'DRAINED: 2  REMAINING: 8'
  'DRAINED: 1  REMAINING: 8'   # first non-decrease -> arms
  'DRAINED: 3  REMAINING: 5'   # decreases -> counter resets
  'DRAINED: 1  REMAINING: 5'   # first non-decrease again (counter was reset)
  'DRAINED: 0  REMAINING: 5'   # normal drained-zero stop
)
POSTFLIGHT_OUT=('' '' '' '' '')
sb_drain_loop
[ "$DISPATCHES" -eq 5 ]           || fail "no-shrink reset: expected 5 dispatches, got $DISPATCHES"
[ "$STOP_REASON" = drained-zero ] || fail "no-shrink reset: expected drained-zero, got $STOP_REASON"
pass "loop: a decreasing batch resets the no-shrink counter (recovers to drained-zero)"

echo; echo "ALL PASS"
