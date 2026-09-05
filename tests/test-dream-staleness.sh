#!/usr/bin/env bash
# pins: SB_DREAM_RUN_TIMEOUT — lowers the staleness timeout so a fixture dream goes stale within this test's own short runtime, deterministically
# sb_dream_is_stale — the single staleness policy that replaces four disagreeing
# definitions (dream-snapshot 6h-mtime / dream-autostage 24h-created_at /
# verify calendar-day / maintain-llm-drain none).
# ORACLE: a status.json whose `status` field and on-disk mtime we set ourselves
# — a filesystem fact — not a re-read of any script's own staleness claim.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SB=$(mktemp -d)
export HOME="$SB/home"; mkdir -p "$HOME"
export BRAIN_DIR="$SB/brain"; mkdir -p "$BRAIN_DIR"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib.sh"

fail() { echo "FAIL: $1"; rm -rf "$SB"; exit 1; }
pass() { echo "PASS: $1"; }

# Write status.json with a given status and backdate its mtime to N seconds ago.
mk() {  # $1=status  $2=seconds_ago  -> echoes the file path
  local st="$1" ago="$2" t
  local f="$SB/${st}_${ago}.json"
  printf '{"id":"drm_x","status":"%s"}\n' "$st" > "$f"
  t=$(( $(date +%s) - ago ))
  touch -d "@$t" "$f" 2>/dev/null \
    || touch -t "$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null)" "$f" 2>/dev/null \
    || fail "could not backdate mtime (need GNU or BSD touch)"
  echo "$f"
}

# Default policy timeout is 21600s (6h). old = 7h ago, fresh = 60s ago.
OLD=25200; FRESH=60

# pending|running aging past the timeout → stale; everything else → not stale.
sb_dream_is_stale "$(mk pending  "$FRESH")" && fail "pending+fresh judged stale"  || pass "pending+fresh → fresh"
sb_dream_is_stale "$(mk pending  "$OLD")"   && pass "pending+old → stale"          || fail "pending+old not stale"
sb_dream_is_stale "$(mk running  "$OLD")"   && pass "running+old → stale"          || fail "running+old not stale"
sb_dream_is_stale "$(mk running  "$FRESH")" && fail "running+fresh judged stale"   || pass "running+fresh → fresh"
sb_dream_is_stale "$(mk completed "$OLD")"  && fail "completed judged stale"       || pass "completed → never stale"
sb_dream_is_stale "$(mk failed   "$OLD")"   && fail "failed judged stale"          || pass "failed → never stale"
sb_dream_is_stale "$(mk canceled "$OLD")"   && fail "canceled judged stale"        || pass "canceled → never stale"
sb_dream_is_stale "$SB/nope.json"           && fail "missing file judged stale"    || pass "missing → not stale"

# SB_DREAM_RUN_TIMEOUT is honored: a 1s timeout makes a 60s-old pending stale.
( export SB_DREAM_RUN_TIMEOUT=1; sb_dream_is_stale "$(mk pending "$FRESH")" ) \
  && pass "SB_DREAM_RUN_TIMEOUT override honored" \
  || fail "SB_DREAM_RUN_TIMEOUT override not honored"

# A non-numeric timeout must fall back to the 21600 default, not disable the check.
( export SB_DREAM_RUN_TIMEOUT=garbage; sb_dream_is_stale "$(mk pending "$OLD")" ) \
  && pass "garbage timeout falls back to default (old pending still stale)" \
  || fail "garbage SB_DREAM_RUN_TIMEOUT broke the check"

rm -rf "$SB"
echo "ALL PASS: dream staleness policy"
