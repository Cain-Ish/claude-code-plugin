#!/bin/bash
# C: the opt-in headless-LLM maintainer. We test the GATING + the QUARANTINE structure and its
# run-all-timeout: 300   (9 full quarantine-lane runs by design; measured 153s alone on MSYS — spawn-bound lib.sh, see LC-11)
# runtime attestation with a mock `claude` that emits canned stream-json. A real headless run is
# operator-verified (it can't run from inside a Claude session — the recursive-claude OAuth lock).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/maintain-llm-drain.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }
# Run out-of-band: unset CLAUDECODE so the defense-in-depth refuse doesn't short-circuit the
# test; unset CLAUDE_SESSION_ID so self-transcript exclusion only fires when a case sets it.
unset CLAUDECODE CLAUDE_SESSION_ID 2>/dev/null || true

# --- structural: the quarantine flag set is in the source, and the old confinement gate is gone ---
grep -q -- '--tools ""' "$SCRIPT"                   && pass "zero-tool spawn (--tools \"\")"            || fail "--tools \"\" missing"
grep -q -- '--strict-mcp-config' "$SCRIPT"          && pass "MCP config locked (--strict-mcp-config)"   || fail "--strict-mcp-config missing"
grep -q -- '--setting-sources ""' "$SCRIPT"         && pass "no settings/hooks in the child (--setting-sources \"\")" || fail "--setting-sources \"\" missing"
grep -q -- '--no-session-persistence' "$SCRIPT"     && pass "no persisted self-transcript (--no-session-persistence)" || fail "--no-session-persistence missing"
grep -q -- '--output-format stream-json' "$SCRIPT"  && pass "attestable output (--output-format stream-json)" || fail "stream-json missing"
grep -q -- '--verbose' "$SCRIPT"                    && pass "stream-json in -p mode requires --verbose (CLI-enforced)" || fail "--verbose missing"
grep -q -- '--json-schema' "$SCRIPT"                && pass "validator-enforced output (--json-schema)"  || fail "--json-schema missing"
grep -q -- '--bare' "$SCRIPT"                       && fail "--bare present (kills subscription OAuth)"  || pass "no --bare (OAuth preserved)"
grep -q -- '--max-turns' "$SCRIPT"                  && fail "--max-turns present (removed from the CLI)" || pass "no --max-turns (timeout is the bound)"
grep -q 'bypassPermissions' "$SCRIPT"               && fail "bypassPermissions present (zero tools → nothing to permit)" || pass "no bypassPermissions anywhere"
grep -q -- '--disallowedTools' "$SCRIPT"            && fail "--disallowedTools present (denies the StructuredOutput delivery tool — live-verified)" || pass "no --disallowedTools (would null the schema output)"
grep -q 'ATTESTATION' "$SCRIPT"                     && pass "runtime attestation block present"          || fail "no attestation block"
grep -q 'mcp_servers' "$SCRIPT"                     && pass "attestation checks mcp_servers"             || fail "attestation ignores mcp_servers"
grep -q 'MIN_CLI="2.1.205"' "$SCRIPT"               && pass "CLI schema-enforcement floor pinned (2.1.205)" || fail "no CLI version floor"
# The executed spawn prefix (env guard + timeout expansion glued together) must appear on BOTH
# spawn sites — comments mentioning either token alone don't match.
[ "$(grep -cF 'SB_NESTED_SPAWN=1 ${TBIN:+' "$SCRIPT")" = "2" ] && pass "both spawn sites export SB_NESTED_SPAWN=1 under the timeout wrapper" || fail "spawn sites lack the SB_NESTED_SPAWN=1 + timeout prefix (want exactly 2)"
grep -q 'BWRAP_OK' "$SCRIPT"                         && pass "bwrap is additive (probed, never a gate)"   || fail "no additive bwrap probe"
grep -q 'bwrap absent —' "$SCRIPT"                   && fail "old bwrap-absent HARD GATE still present"   || pass "bwrap-absent hard gate removed"

# --- shared doubles -----------------------------------------------------------
# Mock claude: --version reports a pinned CLI version; a -p run records its cwd, optionally
# sleeps/corrupts state, drains the prompt (optionally capturing it), then emits canned
# stream-json (init attestation event + non-JSON noise + result). Knobs via SB_TEST_*.
write_claude_mock() {  # $1 = target path
  cat > "$1" <<'EOF'
#!/bin/bash
for a in "$@"; do
  [ "$a" = "--version" ] && { echo "${SB_TEST_CLAUDE_VERSION:-2.1.220} (Claude Code)"; exit 0; }
done
[ -n "${SB_TEST_RUN_SENTINEL:-}" ] && pwd > "$SB_TEST_RUN_SENTINEL"
[ -n "${SB_TEST_CLAUDE_SLEEP:-}" ] && sleep "$SB_TEST_CLAUDE_SLEEP"
cat > "${SB_TEST_PROMPT_COPY:-/dev/null}"
if [ "${SB_TEST_NO_INIT:-0}" != "1" ]; then
  printf '{"type":"system","subtype":"init","tools":%s,"mcp_servers":%s}\n' \
    "${SB_TEST_ATTEST_TOOLS:-[\"StructuredOutput\"]}" "${SB_TEST_ATTEST_MCP:-[]}"
fi
printf '{"type":"rate_limit_event"}\n'
printf 'not-json noise line\n'
if [ "${SB_TEST_NO_STRUCTURED:-0}" = "1" ]; then
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":null}\n'
else
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"facts":[{"kind":"learning","claim":"canned-fact"}]}}\n'
fi
if [ "${SB_TEST_TRUNCATE_STATUS:-0}" = "1" ]; then
  sf=$(ls "$BRAIN_DIR"/dreams/drm_*/status.json 2>/dev/null | head -1)
  [ -n "$sf" ] && printf '{"id":"x","status":"runn' > "$sf"
fi
[ -n "${SB_TEST_CLAUDE_STDERR:-}" ] && echo "$SB_TEST_CLAUDE_STDERR" >&2
exit "${SB_TEST_CLAUDE_RC:-0}"
EOF
  chmod +x "$1"
}
# Transparent bwrap double: the probe (/bin/true) honors SB_TEST_PROBE_RC; a real run records
# that the additive jail wrapped it, then execs the command after `--` (the mock claude on PATH).
# Shadowing any REAL bwrap keeps the suite deterministic on Linux CI.
write_bwrap_stub() {  # $1 = target path
  cat > "$1" <<'EOF'
#!/bin/bash
seen=0; args=()
for a in "$@"; do
  [ "$a" = "/bin/true" ] && exit "${SB_TEST_PROBE_RC:-0}"
  if [ "$seen" = "1" ]; then args[${#args[@]}]="$a"; fi
  [ "$a" = "--" ] && seen=1
done
[ "${#args[@]}" -gt 0 ] || exit 0
[ -n "${SB_TEST_BWRAP_SENTINEL:-}" ] && : > "$SB_TEST_BWRAP_SENTINEL"
exec "${args[@]}"
EOF
  chmod +x "$1"
}

# --- functional gating ---
B=$(mktemp -d); export BRAIN_DIR="$B" KNOWLEDGE_DIR="$B/knowledge" HOME="$B"
mkdir -p "$KNOWLEDGE_DIR/wiki/concepts" "$B/transcripts" "$B/dreams"
printf -- '---\ntype: concepts\ntitle: X\n---\n# X\nbody\n' > "$KNOWLEDGE_DIR/wiki/concepts/x.md"
BIN="$B/bin"; mkdir -p "$BIN"
write_claude_mock "$BIN/claude"
write_bwrap_stub "$BIN/bwrap"
export PATH="$BIN:$PATH"
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

# 4. proceeds: ON + FORCE + DRYRUN + no pile-up → snapshots a dream + reaches the quarantined
#    spawn (WITH the additive jail: the bwrap stub's probe passes → jail=bwrap)
seed_tx(){ printf 'session\n' > "$B/transcripts/sess_x_2026-01-0$1.txt"; }
seed_tx 1; seed_tx 2
OUT=$(SB_MAINTAIN_LLM_FORCE=1 SB_MAINTAIN_LLM_DRYRUN=1 bash "$SCRIPT" 2>&1 || true)
echo "$OUT" | grep -q 'DRYRUN dream=drm_' && pass "proceeds → stages a dream + reaches the quarantined spawn" || fail "did not reach the run (got: $(echo "$OUT" | head -c 160))"
echo "$OUT" | grep -q -- '--tools ""' && pass "dry-run shows the zero-tool quarantine command" || fail "dry-run missing the quarantine command"
echo "$OUT" | grep -q 'bypassPermissions' && fail "dry-run still shows bypassPermissions" || pass "dry-run carries no bypassPermissions"
echo "$OUT" | grep -q 'jail=bwrap' && pass "additive jail engaged when the bwrap probe passes" || fail "jail not engaged (got: $(echo "$OUT" | grep DRYRUN | head -c 160))"
echo "$OUT" | grep -q 'DRYRUN stage-b:.*consolidate-writer' && pass "dry-run names the Stage B writer (two-stage split visible)" || fail "dry-run missing the stage-b line"
echo "$OUT" | grep -q 'stage-b:.*netless=' && pass "stage-b line states the netless mode honestly" || fail "stage-b line missing netless= marker"
grep -q 'candidate_facts.json_schema' "$SCRIPT" && pass "Stage A schema sourced from kb-schema.json (single source)" || fail "inline schema copy resurfaced in the harness"
# The inlined-transcript prompt must be non-trivial — proves the DATA assembly didn't
# silently truncate to nothing.
PB=$(echo "$OUT" | sed -n 's/.*prompt_bytes=\([0-9]*\).*/\1/p'); [ "${PB:-0}" -gt 200 ] && pass "prompt carries the inlined transcripts (${PB}B)" || fail "prompt empty/truncated (prompt_bytes=${PB:-?})"
echo "$OUT" | grep -q 'tx=2 excluded_self=0' && pass "both transcripts inlined, none excluded" || fail "transcript counts wrong (got: $(echo "$OUT" | grep DRYRUN | head -c 160))"

# 4b. self-transcript exclusion: the spawning session's own transcript (CLAUDE_SESSION_ID
#     filename prefix) is never fed to the summarizer.
rm -rf "$B/dreams"; seed_tx 1; seed_tx 2
printf 'self session\n' > "$B/transcripts/selfsess_x_2026-01-03.txt"
OUT=$(CLAUDE_SESSION_ID=selfsess SB_MAINTAIN_LLM_FORCE=1 SB_MAINTAIN_LLM_DRYRUN=1 bash "$SCRIPT" 2>&1 || true)
echo "$OUT" | grep -q 'tx=2 excluded_self=1' && pass "4b: own-session transcript excluded from the summarizer input" || fail "4b: self-transcript not excluded (got: $(echo "$OUT" | grep DRYRUN | head -c 160))"
rm -f "$B/transcripts/selfsess_x_2026-01-03.txt"

# 4c. bwrap probe FAILS → proceeds WITHOUT the jail (additive, never a gate), logged loud.
rm -rf "$B/dreams"; rm -f "$B/error-log.jsonl"; seed_tx 1; seed_tx 2
OUT=$(SB_TEST_PROBE_RC=1 SB_MAINTAIN_LLM_FORCE=1 SB_MAINTAIN_LLM_DRYRUN=1 bash "$SCRIPT" 2>&1 || true)
echo "$OUT" | grep -q 'jail=none' && pass "4c: broken bwrap → proceeds unjailed (quarantine is the boundary)" || fail "4c: broken bwrap gated the run (got: $(echo "$OUT" | grep DRYRUN | head -c 160))"
grep -q 'WITHOUT the additive jail' "$B/error-log.jsonl" 2>/dev/null && pass "4c: degraded jail logged loud" || fail "4c: degraded jail not logged"

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

rm -rf "$B"; echo; echo "ALL PASS (gating + quarantine structure + auto-accept)"

# ═══ Failure-aware lifecycle + runtime attestation (mock stream-json runs) ════
# The maintainer must fail LOUDLY and recover sanely: version preflight before staging,
# 24h retry horizon instead of a burned weekly slot, 3-strike quarantine, terminal failed
# dreams with captured stderr, ATTESTATION violations discarding the output, success clearing
# the counters and landing candidate-facts.json.

B2=$(mktemp -d); trap 'rm -rf "$B2"' EXIT
export HOME="$B2" BRAIN_DIR="$B2/brain" KNOWLEDGE_DIR="$B2/knowledge"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$B2/knowledge"
mkdir -p "$BRAIN_DIR/transcripts" "$KNOWLEDGE_DIR/wiki/concepts"
printf -- '---\ntitle: t\ntype: concepts\n---\n\n# t\nbody\n' > "$KNOWLEDGE_DIR/wiki/concepts/t.md"
printf 'OTHERTOKEN transcript body\n' > "$BRAIN_DIR/transcripts/sess_x_2026-01-01.txt"
# auto_accept:off so a completed run never trips the real merge path — this block tests the
# failure-aware lifecycle + attestation, not accept.
printf '{"auto_maintain": true, "auto_accept": "off"}\n' > "$BRAIN_DIR/config.json"
MARK="$BRAIN_DIR/.last-llm-maintain"
FAILS="$BRAIN_DIR/.llm-maintain-fails"
QUAR="$BRAIN_DIR/.llm-maintain-quarantine"
SENT="$B2/.run-cwd"; BWSENT="$B2/.bwrap-wrapped"; PCOPY="$B2/.prompt-copy"

BIN2="$B2/bin"; mkdir -p "$BIN2"
write_claude_mock "$BIN2/claude"
write_bwrap_stub "$BIN2/bwrap"
export PATH="$BIN2:$PATH"

run_drain() { env "$@" SB_TEST_RUN_SENTINEL="$SENT" SB_TEST_BWRAP_SENTINEL="$BWSENT" bash "$SCRIPT" >/dev/null 2>&1 || true; }
mark_age() { echo $(( $(date +%s) - $(stat -c %Y "$MARK" 2>/dev/null || stat -f %m "$MARK") )); }
dsf(){ ls "$BRAIN_DIR"/dreams/drm_*/status.json 2>/dev/null | head -1; }
reset(){ rm -rf "$BRAIN_DIR/dreams"; mkdir -p "$BRAIN_DIR/dreams"; rm -f "$FAILS" "$QUAR" "$MARK" "$SENT" "$BWSENT" "$PCOPY" "$BRAIN_DIR/error-log.jsonl"; }

# --- (a) CLI below the schema-enforcement floor → no dream, error logged,
#         ~24h retry re-stamp, fails=1 (the version pin is the cheap preflight) ---
reset
run_drain SB_TEST_CLAUDE_VERSION=2.1.100
[ "$(find "$BRAIN_DIR/dreams" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  || fail "(a) old CLI still staged a dream"
grep -q 'schema-enforcement floor' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  || fail "(a) version refusal not logged"
[ "$(cat "$FAILS" 2>/dev/null)" = "1" ] || fail "(a) fails counter not 1 (got '$(cat "$FAILS" 2>/dev/null)')"
[ -f "$MARK" ] || fail "(a) throttle mark missing after failure"
AGE=$(mark_age)
[ "$AGE" -gt 500000 ] && [ "$AGE" -lt 540000 ] \
  || fail "(a) throttle not re-stamped to the retry horizon (age=${AGE}s, want ~518400)"
pass "(a) CLI 2.1.100 < 2.1.205: no dream, logged, 24h retry horizon, fails=1"

# --- (a2) unparseable version → same refusal (fail-closed on the floor check) ---
rm -f "$MARK"
run_drain SB_TEST_CLAUDE_VERSION=garbage
grep -q 'unparseable' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  && pass "(a2) unparseable CLI version refused fail-closed" || fail "(a2) unparseable version not refused"

# --- (b) 3 strikes → quarantine; further runs stay down while the cause persists ---
rm -f "$FAILS" "$QUAR" "$MARK" "$BRAIN_DIR/error-log.jsonl"
run_drain SB_TEST_CLAUDE_VERSION=2.1.100
rm -f "$MARK"; run_drain SB_TEST_CLAUDE_VERSION=2.1.100
rm -f "$MARK"; run_drain SB_TEST_CLAUDE_VERSION=2.1.100
[ -f "$QUAR" ] || fail "(b) no quarantine file after 3 consecutive failures"
grep -q 'schema-enforcement floor' "$QUAR" || fail "(b) quarantine lacks the error summary"
N_BEFORE=$(grep -c 'schema-enforcement floor' "$BRAIN_DIR/error-log.jsonl")
rm -f "$MARK"; run_drain SB_TEST_CLAUDE_VERSION=2.1.100   # quarantined + cause persists → stay down silently
N_AFTER=$(grep -c 'schema-enforcement floor' "$BRAIN_DIR/error-log.jsonl")
[ "$N_BEFORE" = "$N_AFTER" ] || fail "(b) quarantined run still logged a new failure"
[ -f "$QUAR" ] || fail "(b) quarantine cleared while the cause persists"
pass "(b) 3-strike quarantine; quarantined runs stay down while the CLI is old"

# The remaining cases spawn the mock for real → need a wall-clock binary (the harness
# refuses to run unbounded without one — locked by the timeout-guard suite).
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  echo "SKIP: host has no timeout/gtimeout for the spawn-path cases"; echo "ALL PASS"; exit 0
fi

# --- (b2) SELF-CLEARING: once the CLI is upgraded (preflight passes), the next drain
#          clears the quarantine and proceeds to a full successful run ---
rm -f "$MARK"
run_drain
[ ! -f "$QUAR" ] || fail "(b2) quarantine did not self-clear after the CLI was fixed"
[ ! -f "$FAILS" ] || fail "(b2) fails counter not cleared on self-heal + success"
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "completed" ] || fail "(b2) run after self-clear did not complete (got $(jq -r '.status' "$SF" 2>/dev/null))"
pass "(b2) quarantine self-clears when the preflight passes again"

# --- (c) preflight ok, spawn exits non-zero → dream →failed with stderr, strike ---
reset
run_drain SB_TEST_CLAUDE_RC=1 SB_TEST_CLAUDE_STDERR="boom: auth exploded"
SF=$(dsf)
[ -n "$SF" ] || fail "(c) no dream staged on the run-failure path"
[ "$(jq -r '.status' "$SF")" = "failed" ] || fail "(c) status not failed (got $(jq -r '.status' "$SF"))"
jq -r '.error' "$SF" | grep -q 'boom' || fail "(c) stderr not captured into status.error"
[ "$(jq -r '.ended_at' "$SF")" != "null" ] || fail "(c) ended_at not set"
grep -q 'boom' "$BRAIN_DIR/error-log.jsonl" || fail "(c) stderr tail not in error-log"
[ "$(cat "$FAILS" 2>/dev/null)" = "1" ] || fail "(c) fails counter not incremented"
pass "(c) spawn failure: →failed with captured stderr, logged, strike counted"

# --- (d) SUCCESS: attestation passes, structured output lands in candidate-facts.json,
#         counters cleared, throttle fresh, cwd was the fresh scratch dir, the additive
#         jail wrapped the spawn, and the self-transcript never reached the prompt ---
reset
printf 'SELFTOKEN self session body\n' > "$BRAIN_DIR/transcripts/selfsess_x_2026-01-02.txt"
run_drain CLAUDE_SESSION_ID=selfsess SB_TEST_PROMPT_COPY="$PCOPY"
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "completed" ] || fail "(d) success did not complete (got $(jq -r '.status' "$SF" 2>/dev/null))"
CF="$(dirname "$SF")/candidate-facts.json"
[ -f "$CF" ] || fail "(d) candidate-facts.json missing"
[ "$(jq -r '.facts[0].claim' "$CF" 2>/dev/null)" = "canned-fact" ] || fail "(d) structured output not captured (got $(head -c 120 "$CF"))"
[ "$(jq -r '.outputs.candidate_facts' "$SF" 2>/dev/null)" = "1" ] || fail "(d) candidate_facts count not recorded"
[ ! -f "$FAILS" ] || fail "(d) fails counter not cleared on success"
[ ! -f "$QUAR" ] || fail "(d) quarantine not cleared on success"
AGE=$(mark_age)
[ "$AGE" -lt 120 ] || fail "(d) throttle mark not fresh after success (age=${AGE}s)"
grep -q 'scratch/summarizer\.' "$SENT" 2>/dev/null || fail "(d) summarizer cwd was not the fresh scratch dir (got '$(cat "$SENT" 2>/dev/null)')"
[ -f "$BWSENT" ] || fail "(d) additive bwrap jail did not wrap the spawn"
grep -q 'OTHERTOKEN' "$PCOPY" || fail "(d) real transcript missing from the summarizer prompt"
grep -q 'SELFTOKEN' "$PCOPY" && fail "(d) SELF transcript leaked into the summarizer prompt" || true
grep -q 'BEGIN UNTRUSTED TRANSCRIPT DATA' "$PCOPY" || fail "(d) untrusted-DATA framing missing from the prompt"
pass "(d) success: attested run → candidate-facts.json, counters cleared, scratch cwd, jailed, self-transcript excluded"
rm -f "$BRAIN_DIR/transcripts/selfsess_x_2026-01-02.txt"

# --- (e) ATTESTATION FAIL: a real tool in the init event → output DISCARDED, dream failed,
#         loud log, strike. The security-boundary case: NEVER fail open. ---
reset
run_drain SB_TEST_ATTEST_TOOLS='["StructuredOutput","Bash"]'
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] || fail "(e) attestation violation did not fail the dream (got $(jq -r '.status' "$SF" 2>/dev/null))"
grep -q 'QUARANTINE ATTESTATION FAILED' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null || fail "(e) attestation failure not logged loud"
[ ! -f "$(dirname "$SF")/candidate-facts.json" ] || fail "(e) output NOT discarded despite failed attestation"
[ "$(cat "$FAILS" 2>/dev/null)" = "1" ] || fail "(e) attestation failure did not count a strike"
pass "(e) non-empty tools → attestation fails loud, output discarded, strike"

# --- (e2) ATTESTATION FAIL: an MCP server in the init event ---
reset
run_drain SB_TEST_ATTEST_MCP='[{"name":"kb","status":"connected"}]'
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] || fail "(e2) mcp attestation violation did not fail the dream"
grep -q 'QUARANTINE ATTESTATION FAILED' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null || fail "(e2) not logged"
[ ! -f "$(dirname "$SF")/candidate-facts.json" ] || fail "(e2) output not discarded"
pass "(e2) non-empty mcp_servers → attestation fails loud"

# --- (e3) ATTESTATION FAIL: no init event at all (quarantine cannot be PROVEN) ---
reset
run_drain SB_TEST_NO_INIT=1
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] || fail "(e3) missing init event did not fail the dream"
grep -q 'QUARANTINE ATTESTATION FAILED' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null || fail "(e3) not logged"
pass "(e3) missing init event → attestation fails closed"

# --- (f) success WITHOUT structured_output → failure (schema enforcement is the contract) ---
reset
run_drain SB_TEST_NO_STRUCTURED=1
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] || fail "(f) missing structured_output did not fail the dream"
grep -q 'schema-enforced output missing' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null || fail "(f) not logged"
[ "$(cat "$FAILS" 2>/dev/null)" = "1" ] || fail "(f) no strike for missing structured_output"
pass "(f) success without structured_output = failure (spec floor)"

# --- (g) wall-clock timeout kill: the spawn is killed at SB_MAINTAIN_LLM_TIMEOUT and the
#         dream ends terminal-failed naming the timeout ---
reset
run_drain SB_TEST_CLAUDE_SLEEP=5 SB_MAINTAIN_LLM_TIMEOUT=1
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] || fail "(g) timed-out run not failed (got $(jq -r '.status' "$SF" 2>/dev/null))"
jq -r '.error' "$SF" 2>/dev/null | grep -q 'timeout' || fail "(g) error does not name the timeout (got $(jq -r '.error' "$SF" 2>/dev/null | head -c 120))"
[ "$(cat "$FAILS" 2>/dev/null)" = "1" ] || fail "(g) timeout kill did not count a strike"
pass "(g) wall-clock timeout kills the spawn; dream terminal-failed naming the timeout"

echo "ALL PASS"
