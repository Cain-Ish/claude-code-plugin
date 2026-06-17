#!/usr/bin/env bash
# verify.sh check 5b — dream staleness now uses the unified sb_dream_is_stale
# policy (status.json mtime > SB_DREAM_RUN_TIMEOUT, pending|running), replacing
# the old running-only calendar-day check.
# ORACLE: craft dreams/drm_*/status.json at known mtimes (a filesystem fact) and
# assert verify.sh's emitted FAIL line for that dream — never a re-read of the impl.
set -u
unset CLAUDECODE 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
VERIFY="$REPO_ROOT/scripts/verify.sh"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

backdate(){ local f="$1" ago="$2" t; t=$(( $(date +%s) - ago ));
  touch -d "@$t" "$f" 2>/dev/null \
    || touch -t "$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null)" "$f" 2>/dev/null \
    || { echo "  FAIL: cannot backdate mtime"; exit 1; }; }

# Run verify.sh in a throwaway $HOME with a single crafted dream; echo all output.
# verify.sh accumulates FAILS and prints them, so other (seeded-absent) checks
# failing does not stop check 5b from running — we grep only for the dream line.
run_verify(){  # $1=id $2=status $3=ago_sec $4=started_at ('' = omit)
  local id="$1" st="$2" ago="$3" started="${4:-}" SB d
  SB=$(mktemp -d); export HOME="$SB"
  d="$SB/.second-brain/dreams/$id"; mkdir -p "$d"
  if [ -n "$started" ]; then
    jq -nc --arg id "$id" --arg st "$st" --arg s "$started" '{id:$id,status:$st,started_at:$s}' > "$d/status.json"
  else
    jq -nc --arg id "$id" --arg st "$st" '{id:$id,status:$st}' > "$d/status.json"
  fi
  [ "$ago" -gt 0 ] && backdate "$d/status.json" "$ago"
  bash "$VERIFY" 2>&1 || true
  rm -rf "$SB"
}

OLD=25200   # 7h > 6h default
echo "=== verify.sh dream-staleness (unified policy) ==="

# running + stale → flagged
O=$(run_verify drm_rs running "$OLD" "2026-06-10T00:00:00Z")
printf '%s' "$O" | grep -q "drm_rs running but stale" && pass "running+stale flagged" || fail "running+stale not flagged"

# running + fresh → NOT flagged (heartbeating runner is healthy)
O=$(run_verify drm_rf running 0 "2026-06-17T00:00:00Z")
printf '%s' "$O" | grep -q "drm_rf .*stale" && fail "running+fresh wrongly flagged" || pass "running+fresh not flagged"

# pending + stale → flagged (NEW: policy now widens to pending)
O=$(run_verify drm_ps pending "$OLD" "")
printf '%s' "$O" | grep -q "drm_ps pending but stale" && pass "pending+stale flagged (new behavior)" || fail "pending+stale not flagged"

# running + stale + no started_at → flagged WITHOUT leaking 'started null'
O=$(run_verify drm_rn running "$OLD" "")
if printf '%s' "$O" | grep -q "drm_rn running but stale"; then
  printf '%s' "$O" | grep -q "started null" && fail "leaks 'started null'" || pass "stale w/o started_at: flagged, no 'started null' suffix"
else fail "running+stale (no started_at) not flagged"; fi

# completed + unarchived → flagged 'not reviewed' (orthogonal branch unchanged)
O=$(run_verify drm_cu completed 0 "")
printf '%s' "$O" | grep -q "drm_cu completed but not reviewed" && pass "completed+unarchived flagged" || fail "completed+unarchived not flagged"

# fresh pending → NOT flagged (regression-lock against over-flagging)
O=$(run_verify drm_pf pending 0 "")
printf '%s' "$O" | grep -q "drm_pf .*stale" && fail "fresh pending wrongly flagged" || pass "fresh pending not flagged"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
