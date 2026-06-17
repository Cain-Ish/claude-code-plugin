#!/bin/bash
# C: the opt-in headless-LLM maintainer. We test the GATING + the kernel-containment STRUCTURE.
# The actual headless `claude -p` consolidation is operator-verified (it can't run from inside a
# Claude session — the recursive-claude OAuth lock).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/maintain-llm-drain.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }
# Run out-of-band: unset CLAUDECODE so the defense-in-depth refuse doesn't short-circuit the test.
unset CLAUDECODE 2>/dev/null || true

# --- structural: airtight containment is in the source, and it never runs claude unconfined ---
grep -q 'bwrap' "$SCRIPT"                         && pass "uses bwrap (kernel containment)"            || fail "no bwrap"
grep -q 'permission-mode bypassPermissions' "$SCRIPT" && pass "headless run is unattended (bypassPermissions)" || fail "no bypassPermissions"
grep -q -- '--bind "\$DREAM_DIR"' "$SCRIPT"       && pass "binds ONLY the dream dir writable"          || fail "dream-dir bind missing"
grep -q -- '--ro-bind / /' "$SCRIPT"              && pass "everything else read-only (live wiki safe)" || fail "ro-bind missing"
grep -q 'bwrap absent' "$SCRIPT"                  && pass "bwrap-absent → skip (never unconfined)"     || fail "no bwrap-absent guard"
# C1 (deep-review): ~/.claude must NOT be wholesale-writable (that would let the agent rewrite the
# plugin's own code / hooks). Only the credential FILE is bound writable; plugins/settings stay ro.
grep -q -- '--bind "\$HOME/.claude" "\$HOME/.claude"' "$SCRIPT" && fail "binds ALL of ~/.claude writable (plugin self-modification vector)" || pass "no wholesale ~/.claude writable bind"
grep -q -- '--ro-bind "\$HOME/.claude/.credentials.json"' "$SCRIPT" && pass "creds bound READ-ONLY (no DoS/overwrite)" || fail "creds not ro-bound"
grep -qE -- '[^o] --bind "\$HOME/.claude/.credentials' "$SCRIPT" && fail "creds bound writable (should be --ro-bind)" || pass "no writable creds bind"
# the ONLY executed claude invocation must be the bwrap-jailed one (the -- claude line); guard against
# a bare unconfined `claude -p` slipping in (the DRYRUN/echo + comments don't count as executed runs).
BARE=$(grep -nE '(^|[^-] )claude -p' "$SCRIPT" | grep -v 'printf\|echo\|#' | grep -v -- '-- claude -p' | wc -l | tr -d ' ')
[ "$BARE" = "0" ] && pass "no unconfined claude -p (only the bwrap-jailed exec)" || fail "found $BARE unconfined claude -p"

# --- functional gating ---
B=$(mktemp -d); export BRAIN_DIR="$B" KNOWLEDGE_DIR="$B/knowledge" HOME="$B"
mkdir -p "$KNOWLEDGE_DIR/wiki/concepts" "$B/transcripts" "$B/dreams"
printf -- '---\ntype: concepts\ntitle: X\n---\n# X\nbody\n' > "$KNOWLEDGE_DIR/wiki/concepts/x.md"
BIN="$B/bin"; mkdir -p "$BIN"; printf '#!/bin/bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
# Stub bwrap too: case 4 must reach the DRYRUN print on hosts WITHOUT real
# bubblewrap (CI runners) — the Pi has it installed, which masked this gap.
printf '#!/bin/bash\nexit 0\n' > "$BIN/bwrap"; chmod +x "$BIN/bwrap"
export PATH="$BIN:$PATH"   # stub claude+bwrap (DRYRUN exits before invoking them anyway)
ndreams(){ find "$B/dreams" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | wc -l | tr -d ' '; }

# 1. auto_maintain OFF (EXPLICIT — 0.30.0 made absent default to ON, so the off path
#    must now be opted out explicitly) → no run, no marker, no dream
printf '{"auto_maintain": false}\n' > "$B/config.json"
bash "$SCRIPT" >/dev/null 2>&1 || true
{ [ ! -f "$B/.last-llm-maintain" ] && [ "$(ndreams)" = "0" ]; } && pass "auto_maintain off → no run" || fail "ran while off"
rm -f "$B/config.json"

# 2. auto_maintain ON + fresh throttle marker → skip (no new dream)
printf '{"auto_maintain": true}\n' > "$B/config.json"
: > "$B/.last-llm-maintain"        # fresh → within the 7d window
bash "$SCRIPT" >/dev/null 2>&1 || true
[ "$(ndreams)" = "0" ] && pass "fresh throttle marker → skip" || fail "ran despite throttle"

# 3. no-pile-up: an existing completed-unarchived dream → skip (FORCE bypasses throttle)
mkdir -p "$B/dreams/drm_20260101T000000Z"
jq -nc '{id:"drm_20260101T000000Z",status:"completed",archived_at:null}' > "$B/dreams/drm_20260101T000000Z/status.json"
SB_MAINTAIN_LLM_FORCE=1 bash "$SCRIPT" >/dev/null 2>&1 || true
[ "$(ndreams)" = "1" ] && pass "unreviewed dream pending → skip (no stacking)" || fail "stacked a new dream"
rm -rf "$B/dreams/drm_20260101T000000Z"

# 4. proceeds: ON + FORCE + DRYRUN + no pile-up → snapshots a dream + reaches the contained run
seed_tx(){ printf 'session\n' > "$B/transcripts/sess_x_2026-01-0$1.txt"; }
seed_tx 1; seed_tx 2
OUT=$(SB_MAINTAIN_LLM_FORCE=1 SB_MAINTAIN_LLM_DRYRUN=1 bash "$SCRIPT" 2>&1 || true)
echo "$OUT" | grep -q 'DRYRUN dream=drm_' && pass "proceeds → stages a dream + reaches the contained run" || fail "did not reach the run (got: $(echo "$OUT" | head -c 160))"
echo "$OUT" | grep -q 'bypassPermissions' && pass "dry-run shows the contained command" || fail "dry-run missing the contained command"
# C3 (deep-review): the prompt must carry the dream-runner body (delimiter-derived) — a non-empty
# prompt proves the body slice didn't silently truncate to nothing.
PB=$(echo "$OUT" | sed -n 's/.*prompt_bytes=\([0-9]*\).*/\1/p'); [ "${PB:-0}" -gt 200 ] && pass "prompt carries the dream-runner body (${PB}B)" || fail "prompt empty/truncated (prompt_bytes=${PB:-?})"

# 5. Auto-accept gate (0.25.0). The DRYRUN path simulates a completed dream and
#    the auto-accept block has its own DRYRUN guard, so these assert the DECISION
#    without a real merge. Config is the only variable.
aa_run(){ printf '{"auto_maintain": true%s}\n' "$1" > "$B/config.json"; rm -rf "$B/dreams"; seed_tx 3; seed_tx 4
  SB_MAINTAIN_LLM_FORCE=1 SB_MAINTAIN_LLM_DRYRUN=1 bash "$SCRIPT" 2>&1 || true; }

# 5a — DEFAULT (no auto_accept key) → "safe" since 0.30.0 (on by default) → auto-accepts a
#       CLEAN (no-forget) dream. The manual-review default moved to an explicit opt-out (5a-off).
OUT=$(aa_run "")
echo "$OUT" | grep -qE 'DRYRUN auto-accept=safe dream=drm_.*forget=0' \
  && pass "5a: default (no auto_accept key) behaves as safe — auto-accepts a clean dream (0.30.0)" \
  || fail "5a: default did not behave as auto_accept=safe (got: $(echo "$OUT" | grep -i auto-accept | head -c 120))"
# 5a-off — EXPLICIT auto_accept:"off" → never auto-accepts (the manual-review opt-out)
OUT=$(aa_run ', "auto_accept": "off"')
echo "$OUT" | grep -q 'auto-accept' && fail "5a-off: explicit off auto-accepted (must not)" || pass "5a-off: explicit off leaves the dream for review"

# 5b — auto_accept:"all" → applies the dream (DRYRUN decision line, forget flag present)
OUT=$(aa_run ', "auto_accept": "all"')
echo "$OUT" | grep -qE 'DRYRUN auto-accept=all dream=drm_.*forget=0' \
  && pass "5b: auto_accept=all applies a completed dream" || fail "5b: auto_accept=all did not apply (got: $(echo "$OUT" | grep -i auto-accept | head -c 120))"

# 5c — auto_accept:"safe" with NO forget-manifest → applies (clean reversible dream)
OUT=$(aa_run ', "auto_accept": "safe"')
echo "$OUT" | grep -qE 'DRYRUN auto-accept=safe dream=drm_.*forget=0' \
  && pass "5c: auto_accept=safe applies a no-forget dream" || fail "5c: auto_accept=safe did not apply a clean dream"

# 5d — the pure decision function sb_auto_accept_decision tested directly against
#      real input→output pairs (NOT re-asserting the condition through the caller).
#      Source lib.sh in a subshell to get the function.
dec(){ bash -c "source '$ROOT/scripts/lib.sh' 2>/dev/null; sb_auto_accept_decision \"\$1\" \"\$2\" \"\$3\" \"\$4\"" _ "$@"; }
declare -a CASES=(
  "off|completed||0|skip:disabled"          # default → never accept
  "all|completed||0|accept"                 # all + clean
  "all|completed||1|accept"                 # all accepts a forget dream too (full autonomy)
  "safe|completed||0|accept"                # safe + no forget → accept
  "safe|completed||1|skip:safe-refuses-forget"  # safe + forget → REFUSE (the safety-critical case)
  "all|running||0|skip:not-completed"       # not done yet → never
  "all|completed|2026-01-01T00:00:00Z|0|skip:already-accepted"  # already archived → never
)
aa_fail=0
for c in "${CASES[@]}"; do
  IFS='|' read -r m s a f exp <<< "$c"
  got=$(dec "$m" "$s" "$a" "$f")
  [ "$got" = "$exp" ] || { echo "  FAIL 5d: ($m,$s,'$a',$f) → '$got' expected '$exp'"; aa_fail=1; }
done
[ "$aa_fail" = "0" ] && pass "5d: sb_auto_accept_decision correct across all 7 input cases (incl. safe-refuses-forget)" || fail "5d: decision-table mismatch"

rm -rf "$B"; echo; echo "ALL PASS (gating + containment + auto-accept)"

# ═══ R4 (SCRIPTS-01/02/03): failure-aware lifecycle ═══════════════════════════
# The maintainer must fail LOUDLY and recover sanely: probe-before-staging,
# 24h retry horizon instead of a burned weekly slot, 3-strike quarantine,
# pending→failed with captured stderr, success clears the counters.

# --- Static: systemd reconciliation (Task 2) ---
grep -q '^RestrictNamespaces=true' "$ROOT/systemd/sb-extract-drain-oauth.service" \
  && fail "oauth unit still sets RestrictNamespaces=true (bwrap structurally impossible)"
grep -q '^RestrictNamespaces=true' "$ROOT/systemd/sb-extract-drain.service" \
  || fail "API-key unit lost RestrictNamespaces=true (should keep it)"
pass "systemd: oauth unit allows namespaces; API-key unit keeps the restriction"

B2=$(mktemp -d); trap 'rm -rf "$B2"' EXIT
export HOME="$B2" BRAIN_DIR="$B2/brain" KNOWLEDGE_DIR="$B2/knowledge"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$B2/knowledge"
mkdir -p "$BRAIN_DIR/transcripts" "$KNOWLEDGE_DIR/wiki/concepts"
printf -- '---\ntitle: t\ntype: concepts\n---\n\n# t\nbody\n' > "$KNOWLEDGE_DIR/wiki/concepts/t.md"
printf 'tx\n' > "$BRAIN_DIR/transcripts/sess_x_2026-01-01.txt"
# auto_accept:off so the now-completed (advancing-stub) success runs don't trip the
# real auto-accept/merge path — this block tests the failure-aware lifecycle, not accept.
printf '{"auto_maintain": true, "auto_accept": "off"}\n' > "$BRAIN_DIR/config.json"
MARK="$BRAIN_DIR/.last-llm-maintain"
FAILS="$BRAIN_DIR/.llm-maintain-fails"
QUAR="$BRAIN_DIR/.llm-maintain-quarantine"

BIN2="$B2/bin"; mkdir -p "$BIN2"
cat > "$BIN2/bwrap" <<'EOF'
#!/bin/bash
# Probe call ends in /bin/true; the real run carries 'claude' in its args.
is_run=0; dream_dir=""; prev=""
for a in "$@"; do
  if [ "$a" = "/bin/true" ]; then exit "${SB_TEST_PROBE_RC:-0}"; fi
  [ "$a" = "claude" ] && is_run=1
  [ "$prev" = "--bind" ] && [ -z "$dream_dir" ] && dream_dir="$a"
  prev="$a"
done
# A genuine agent advances the dream to completed before exiting. The stub mirrors
# that on a successful real run (so the success-path counter-clear is exercised)
# UNLESS the test forces a silent death (SB_TEST_RUN_NOADVANCE=1) or a non-zero rc.
if [ "$is_run" = "1" ] && [ "${SB_TEST_RUN_RC:-0}" = "0" ] && [ "${SB_TEST_RUN_NOADVANCE:-0}" != "1" ] \
   && [ -n "$dream_dir" ] && [ -f "$dream_dir/status.json" ]; then
  jq '.status="completed"' "$dream_dir/status.json" > "$dream_dir/status.json.t" 2>/dev/null \
    && mv "$dream_dir/status.json.t" "$dream_dir/status.json" 2>/dev/null
fi
[ -n "${SB_TEST_RUN_STDERR:-}" ] && echo "$SB_TEST_RUN_STDERR" >&2
exit "${SB_TEST_RUN_RC:-0}"
EOF
printf '#!/bin/bash\nexit 0\n' > "$BIN2/claude"
chmod +x "$BIN2/bwrap" "$BIN2/claude"
export PATH="$BIN2:$PATH"

run_drain() { env "$@" bash "$SCRIPT" >/dev/null 2>&1 || true; }
mark_age() { echo $(( $(date +%s) - $(stat -c %Y "$MARK" 2>/dev/null || stat -f %m "$MARK") )); }

# --- (a) probe fails → no dream, error logged, ~24h retry re-stamp, fails=1 ---
run_drain SB_TEST_PROBE_RC=1
[ "$(find "$BRAIN_DIR/dreams" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  || fail "(a) probe failure still staged a dream"
grep -q 'bwrap preflight failed' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  || fail "(a) probe failure not logged"
[ "$(cat "$FAILS" 2>/dev/null)" = "1" ] || fail "(a) fails counter not 1 (got '$(cat "$FAILS" 2>/dev/null)')"
[ -f "$MARK" ] || fail "(a) throttle mark missing after failure"
AGE=$(mark_age)
[ "$AGE" -gt 500000 ] && [ "$AGE" -lt 540000 ] \
  || fail "(a) throttle not re-stamped to the retry horizon (age=${AGE}s, want ~518400)"
pass "(a) probe failure: no dream, logged, 24h retry horizon, fails=1"

# --- (b) 3 strikes → quarantine; further runs skip the probe entirely ---
# The 24h re-stamp from (a) correctly throttles immediate retries — clear the
# mark to simulate the next day's drain cycles (strikes 2 and 3).
rm -f "$MARK"; run_drain SB_TEST_PROBE_RC=1
rm -f "$MARK"; run_drain SB_TEST_PROBE_RC=1
[ -f "$QUAR" ] || fail "(b) no quarantine file after 3 consecutive failures"
grep -q 'bwrap preflight failed' "$QUAR" || fail "(b) quarantine lacks the error summary"
N_BEFORE=$(grep -c 'bwrap preflight failed' "$BRAIN_DIR/error-log.jsonl")
rm -f "$MARK"; run_drain SB_TEST_PROBE_RC=1   # quarantined + cause persists → stay down silently
N_AFTER=$(grep -c 'bwrap preflight failed' "$BRAIN_DIR/error-log.jsonl")
[ "$N_BEFORE" = "$N_AFTER" ] || fail "(b) quarantined run still logged a new failure"
[ -f "$QUAR" ] || fail "(b) quarantine cleared while the cause persists"
pass "(b) 3-strike quarantine; quarantined runs stay down while the cause persists"

# --- (b2) SELF-CLEARING: once the cause is fixed (probe passes), the next drain
# clears the quarantine and proceeds (deep-review: the old gate was a dead-end —
# the success-path clear was unreachable while quarantined).
rm -f "$MARK"
run_drain SB_TEST_PROBE_RC=0 SB_TEST_RUN_RC=0
[ ! -f "$QUAR" ] || fail "(b2) quarantine did not self-clear after the cause was fixed"
[ ! -f "$FAILS" ] || fail "(b2) fails counter not cleared on self-heal"
pass "(b2) quarantine self-clears when the preflight passes again"

# --- (c) probe ok, headless run fails → dream pending→failed with stderr ---
rm -f "$QUAR" "$FAILS" "$MARK"
rm -rf "$BRAIN_DIR/dreams"   # (b2)'s stub run left a pending dream that would block staging
run_drain SB_TEST_PROBE_RC=0 SB_TEST_RUN_RC=1 SB_TEST_RUN_STDERR="boom: auth exploded"
SF=$(ls "$BRAIN_DIR"/dreams/drm_*/status.json 2>/dev/null | head -1)
[ -n "$SF" ] || fail "(c) no dream staged on the run-failure path"
[ "$(jq -r '.status' "$SF")" = "failed" ] || fail "(c) status not failed (got $(jq -r '.status' "$SF"))"
jq -r '.error' "$SF" | grep -q 'boom' || fail "(c) stderr not captured into status.error"
[ "$(jq -r '.ended_at' "$SF")" != "null" ] || fail "(c) ended_at not set"
grep -q 'boom' "$BRAIN_DIR/error-log.jsonl" || fail "(c) stderr tail not in error-log"
[ "$(cat "$FAILS" 2>/dev/null)" = "1" ] || fail "(c) fails counter not incremented"
pass "(c) headless failure: pending→failed with captured stderr, logged"

# --- (d) success → counters cleared, throttle stamped fresh ---
rm -rf "$BRAIN_DIR/dreams"
rm -f "$MARK"   # (c)'s 24h re-stamp would throttle this run (correct in prod)
run_drain SB_TEST_PROBE_RC=0 SB_TEST_RUN_RC=0
[ ! -f "$FAILS" ] || fail "(d) fails counter not cleared on success"
[ ! -f "$QUAR" ] || fail "(d) quarantine not cleared on success"
AGE=$(mark_age)
[ "$AGE" -lt 120 ] || fail "(d) throttle mark not fresh after success (age=${AGE}s)"
pass "(d) success clears counters; throttle stamped fresh"

echo "ALL PASS"
