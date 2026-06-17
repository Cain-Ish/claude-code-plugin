#!/bin/bash
# Phase 1 task 2 — maintain-llm-drain.sh hardening:
#   B1: refuse the bypassPermissions agent when neither timeout nor gtimeout is on
#       PATH (the old `${TBIN:+...}` form ran it UNBOUNDED).
#   B2: self-heal a dream the "successful" spawn left non-completed (silent death).
# ORACLE: a curated PATH that physically lacks timeout/gtimeout, a stubbed bwrap
# whose rc + status-advancing behavior WE control, and a run-reached sentinel —
# every assertion reads the on-disk status.json / error-log the SCRIPT wrote with
# an independent jq, never by re-reading the script's own logic.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/maintain-llm-drain.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }
unset CLAUDECODE 2>/dev/null || true
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export HOME="$SB" BRAIN_DIR="$SB/brain" KNOWLEDGE_DIR="$SB/knowledge"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SB/knowledge"
mkdir -p "$BRAIN_DIR/transcripts" "$KNOWLEDGE_DIR/wiki/concepts" "$BRAIN_DIR/dreams"
printf -- '---\ntitle: t\ntype: concepts\n---\n\n# t\nbody\n' > "$KNOWLEDGE_DIR/wiki/concepts/t.md"
printf 'tx\n' > "$BRAIN_DIR/transcripts/sess_x_2026-01-01.txt"
# auto_accept off so a (self-)completed dream never trips the real merge path.
printf '{"auto_maintain": true, "auto_accept": "off"}\n' > "$BRAIN_DIR/config.json"
FAILS="$BRAIN_DIR/.llm-maintain-fails"; QUAR="$BRAIN_DIR/.llm-maintain-quarantine"
MARK="$BRAIN_DIR/.last-llm-maintain"; SENT="$BRAIN_DIR/.run-reached"

# Stub bwrap: probe (arg /bin/true) honors SB_TEST_PROBE_RC; the real run (arg
# 'claude') marks the run-reached sentinel, optionally advances the staged dream
# to completed (a genuine agent would), and honors SB_TEST_RUN_RC/STDERR.
STUB="$SB/stub"; mkdir -p "$STUB"
cat > "$STUB/bwrap" <<'EOF'
#!/bin/bash
is_run=0; dream_dir=""; prev=""
for a in "$@"; do
  if [ "$a" = "/bin/true" ]; then exit "${SB_TEST_PROBE_RC:-0}"; fi
  [ "$a" = "claude" ] && is_run=1
  [ "$prev" = "--bind" ] && [ -z "$dream_dir" ] && dream_dir="$a"
  prev="$a"
done
[ "$is_run" = 1 ] && [ -n "${SB_TEST_RUN_SENTINEL:-}" ] && touch "$SB_TEST_RUN_SENTINEL"
if [ "$is_run" = 1 ] && [ "${SB_TEST_RUN_RC:-0}" = 0 ] && [ "${SB_TEST_RUN_NOADVANCE:-0}" != 1 ] \
   && [ -n "$dream_dir" ] && [ -f "$dream_dir/status.json" ]; then
  jq '.status="completed"' "$dream_dir/status.json" > "$dream_dir/status.json.t" 2>/dev/null \
    && mv "$dream_dir/status.json.t" "$dream_dir/status.json" 2>/dev/null
fi
# A broken/injected agent may delete status.json before dying (still rc 0).
[ "$is_run" = 1 ] && [ "${SB_TEST_RUN_DELETE_STATUS:-0}" = 1 ] && [ -n "$dream_dir" ] && rm -f "$dream_dir/status.json"
[ -n "${SB_TEST_RUN_STDERR:-}" ] && echo "$SB_TEST_RUN_STDERR" >&2
exit "${SB_TEST_RUN_RC:-0}"
EOF
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"
chmod +x "$STUB/bwrap" "$STUB/claude"

# CLEANBIN: symlink every tool on the CURRENT PATH except timeout/gtimeout, so the
# script keeps all its coreutils but can't find a wall-clock binary.
CLEANBIN="$SB/cleanbin"; mkdir -p "$CLEANBIN"
IFS=: read -ra PDIRS <<< "$PATH"
for d in "${PDIRS[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    case "$b" in timeout|gtimeout) continue ;; esac
    [ -e "$CLEANBIN/$b" ] || ln -s "$f" "$CLEANBIN/$b" 2>/dev/null
  done
done
ORIG_PATH="$PATH"

reset(){ rm -rf "$BRAIN_DIR/dreams"; mkdir -p "$BRAIN_DIR/dreams"; rm -f "$FAILS" "$QUAR" "$MARK" "$SENT" "$BRAIN_DIR/error-log.jsonl"; }
run(){ env "$@" SB_MAINTAIN_LLM_FORCE=1 SB_TEST_RUN_SENTINEL="$SENT" PATH="$RUN_PATH" bash "$SCRIPT" >/dev/null 2>&1 || true; }
dsf(){ ls "$BRAIN_DIR"/dreams/drm_*/status.json 2>/dev/null | head -1; }

echo "=== B1: refuse to run unbounded when no timeout/gtimeout ==="
RUN_PATH="$STUB:$CLEANBIN"
if PATH="$RUN_PATH" command -v timeout >/dev/null 2>&1 || PATH="$RUN_PATH" command -v gtimeout >/dev/null 2>&1; then
  echo "  SKIP: could not remove timeout/gtimeout from PATH on this host"
else
  # B1a: no wall-clock binary → refuse, mark dream failed, never reach the jailed run.
  reset
  run SB_TEST_PROBE_RC=0
  SF=$(dsf)
  [ -n "$SF" ] && pass "B1a: a dream was staged" || fail "B1a: no dream staged"
  [ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] && pass "B1a: dream marked failed (not left pending)" || fail "B1a: dream not failed ($(jq -r '.status' "$SF" 2>/dev/null))"
  jq -r '.error' "$SF" 2>/dev/null | grep -qiE 'unbounded|no timeout' && pass "B1a: error names the unbounded refusal" || fail "B1a: error missing"
  [ "$(jq -r '.ended_at' "$SF" 2>/dev/null)" != "null" ] && pass "B1a: ended_at set" || fail "B1a: ended_at null"
  grep -q 'refusing to run the bypassPermissions agent UNBOUNDED' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null && pass "B1a: refusal logged" || fail "B1a: refusal not logged"
  [ ! -e "$SENT" ] && pass "B1a: the jailed run was NEVER reached (no unbounded exec)" || fail "B1a: run sentinel present — agent ran unbounded"

  # B1b: a timeout stub present → guard dormant, run proceeds.
  TOUT="$SB/tout"; mkdir -p "$TOUT"
  printf '#!/bin/bash\nshift; exec "$@"\n' > "$TOUT/timeout"; chmod +x "$TOUT/timeout"
  reset; RUN_PATH="$TOUT:$STUB:$CLEANBIN"
  run SB_TEST_PROBE_RC=0 SB_TEST_RUN_RC=0
  [ -e "$SENT" ] && pass "B1b: with timeout present the jailed run IS reached" || fail "B1b: run not reached despite timeout"
  grep -q 'refusing to run the bypassPermissions agent UNBOUNDED' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null && fail "B1b: refusal fired despite timeout present" || pass "B1b: no false refusal when timeout exists"

  # B1b-gtimeout: only gtimeout present (macOS branch of the || chain).
  rm -f "$TOUT/timeout"; printf '#!/bin/bash\nshift; exec "$@"\n' > "$TOUT/gtimeout"; chmod +x "$TOUT/gtimeout"
  reset; RUN_PATH="$TOUT:$STUB:$CLEANBIN"
  run SB_TEST_PROBE_RC=0 SB_TEST_RUN_RC=0
  [ -e "$SENT" ] && pass "B1b: gtimeout-only (macOS branch) also proceeds" || fail "B1b: gtimeout branch did not proceed"
fi

echo "=== B2: self-heal a silent death (rc 0 but dream never completed) ==="
RUN_PATH="$STUB:$ORIG_PATH"   # real timeout present → reach the spawn
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || { echo "  SKIP: host has no timeout/gtimeout for the B2 spawn path"; echo; echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; }

# B2a: spawn exits 0 but does NOT advance status → forced pending→failed, SOFT (no strike).
reset
run SB_TEST_PROBE_RC=0 SB_TEST_RUN_RC=0 SB_TEST_RUN_NOADVANCE=1
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] && pass "B2a: silent death healed to failed" || fail "B2a: not healed ($(jq -r '.status' "$SF" 2>/dev/null))"
jq -r '.error' "$SF" 2>/dev/null | grep -q 'never reached completed' && pass "B2a: error explains the silent death" || fail "B2a: error missing"
[ "$(jq -r '.ended_at' "$SF" 2>/dev/null)" != "null" ] && pass "B2a: ended_at set" || fail "B2a: ended_at null"
grep -q 'never reached completed' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null && pass "B2a: silent death logged" || fail "B2a: not logged"
[ ! -f "$FAILS" ] && pass "B2a: soft recovery — no failure strike counted" || fail "B2a: a strike was counted (got $(cat "$FAILS" 2>/dev/null))"

# B2b: genuine completion (advancing stub) → heal must NOT clobber status=completed.
reset
run SB_TEST_PROBE_RC=0 SB_TEST_RUN_RC=0
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "completed" ] && pass "B2b: real completion preserved (heal did not fire)" || fail "B2b: completed clobbered ($(jq -r '.status' "$SF" 2>/dev/null))"

# B2c: hard failure (rc!=0) path unchanged — strikes + captures stderr.
reset
run SB_TEST_PROBE_RC=0 SB_TEST_RUN_RC=1 SB_TEST_RUN_STDERR="boom: auth exploded"
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] && pass "B2c: rc!=0 still →failed" || fail "B2c: rc!=0 not failed"
jq -r '.error' "$SF" 2>/dev/null | grep -q 'boom' && pass "B2c: rc!=0 captures stderr" || fail "B2c: stderr not captured"
[ "$(cat "$FAILS" 2>/dev/null)" = "1" ] && pass "B2c: rc!=0 counts a strike (hard failure)" || fail "B2c: strike not counted (got $(cat "$FAILS" 2>/dev/null))"

# B2d: a "successful" spawn (rc 0) that DELETES status.json (broken/injected agent) must NOT
# read as success — the failure counter is RETAINED, not cleared (review fix: missing status.json
# is a silent death, not a completion).
reset
printf '2' > "$FAILS"   # pre-seed a strike (below the 3-strike quarantine threshold)
run SB_TEST_PROBE_RC=0 SB_TEST_RUN_RC=0 SB_TEST_RUN_DELETE_STATUS=1
[ "$(cat "$FAILS" 2>/dev/null)" = "2" ] && pass "B2d: missing status.json (rc=0) retains the strike counter" || fail "B2d: counter wrongly cleared on missing status.json (got '$(cat "$FAILS" 2>/dev/null)')"
grep -q 'never reached completed' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null && pass "B2d: missing status.json logged as silent death" || fail "B2d: not logged"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
