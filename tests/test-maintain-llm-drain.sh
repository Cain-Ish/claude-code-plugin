#!/bin/bash
# pins: SB_MAINTAIN_LLM_DRYRUN — the flag itself is the subject of this subtest (dry-run path)
# pins: SB_MAINTAIN_LLM_FORCE — forces the lane to run regardless of its normal due gate, for a deterministic fixture run
# pins: SB_MAINTAIN_LLM_TIMEOUT — lowers the timeout so the timeout-guard subtest actually times out within the test's runtime
# pins: SB_NESTED_SPAWN — never set here: the census reads the `SB_NESTED_SPAWN=1` grep pattern that
#   asserts both spawn sites export it (lib.sh's sb_is_headless_child reads the variable since R1#2)
# C: the opt-in headless-LLM maintainer. We test the GATING + the QUARANTINE structure and its
# run-all-timeout: 300   (9 full quarantine-lane runs by design, plus 2 short no-stacking runs (3b, 3c); measured 153s alone on MSYS before 3b/3c — spawn-bound lib.sh, see LC-11;
#   2026-10-07 after R3-B's 3b-pending/3d/3e/d2 runs, alone on MSYS: 91 s jq 1.8.1 / 97 s jq 1.7.1, 14.4 GB free, 391 processes;
#   2026-10-08 after R3-C's short no-jq run (3f), alone: 75 s jq 1.8.1 / 88 s jq 1.7.1)
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
# K1: the skip was a silent exit 0, and a dream that auto-accept refused stays unreviewed, so the
# lane stopped for good with no trace. It must name the blocking dream in the error log, count
# no strike (nothing failed), and re-stamp the throttle to the retry horizon so the row is
# written once per horizon instead of on every drain tick (the mark from case 2 is fresh).
# R3-B S12: the skip is routine, so its row is a gate= trace in the audit-log (exit_code 0), not an
# error-log line on every drain tick.
defer_row() {  # $1 = ERE the message must match after the gate= prefix; prints the audit-log row(s)
  jq -c --arg re "^gate=lane-defer .*$1" 'select(.script == "maintain-llm-drain" and .exit_code == 0 and ((.message // "") | test($re)))' \
    "$B/audit-log.jsonl" 2>/dev/null | tr -d '\r'
}
[ -n "$(defer_row 'drm_20260101T000000Z')" ] && ! grep -q 'drm_20260101T000000Z' "$B/error-log.jsonl" 2>/dev/null \
  && pass "no-stacking skip names the blocking dream in a gate=lane-defer audit row (not the error log)" \
  || fail "no-stacking skip: no gate=lane-defer audit row naming drm_20260101T000000Z (error-log: $(tail -1 "$B/error-log.jsonl" 2>/dev/null))"
[ ! -f "$B/.llm-maintain-fails" ] && pass "no-stacking skip counts no failure strike" || fail "no-stacking skip counted a strike ($(cat "$B/.llm-maintain-fails"))"
K1_AGE=$(( $(date +%s) - $(stat -c %Y "$B/.last-llm-maintain" 2>/dev/null || stat -f %m "$B/.last-llm-maintain") ))
[ "$K1_AGE" -gt 3600 ] && pass "no-stacking skip re-stamps the throttle to the retry horizon (mark age ${K1_AGE}s)" \
  || fail "no-stacking skip left the throttle mark at age ${K1_AGE}s (every drain tick would log again)"
rm -rf "$B/dreams/drm_20260101T000000Z"

# 3b. K3: an attended dream still RUNNING or PENDING (fresh status.json) made dream-snapshot.sh
#     refuse, and that refusal counted as a failure strike: three ticks during one long attended
#     run quarantined the lane as class "other", which never clears itself. It is a transient
#     block: logged with the dream id, deferred to the retry horizon (the mark is re-stamped so
#     the row is written once per horizon), no strike. R3-B Q-L7: both arms, and the re-stamp.
mark_age_b() { echo $(( $(date +%s) - $(stat -c %Y "$B/.last-llm-maintain" 2>/dev/null || stat -f %m "$B/.last-llm-maintain") )); }
for k3 in running:drm_20260102T000000Z pending:drm_20260102T000001Z; do
  k3st=${k3%%:*}; k3id=${k3#*:}
  rm -f "$B/error-log.jsonl" "$B/audit-log.jsonl" "$B/.llm-maintain-fails" "$B/.llm-maintain-fail-class"; : > "$B/.last-llm-maintain"
  mkdir -p "$B/dreams/$k3id"
  jq -nc --arg id "$k3id" --arg st "$k3st" '{id:$id,status:$st,archived_at:null}' > "$B/dreams/$k3id/status.json"
  SB_MAINTAIN_LLM_FORCE=1 bash "$SCRIPT" >/dev/null 2>&1 || true
  [ "$(ndreams)" = "1" ] && pass "$k3st attended dream → skip (no stacking)" || fail "stacked a dream next to a $k3st one"
  [ ! -f "$B/.llm-maintain-fails" ] && pass "$k3st attended dream counts no failure strike" \
    || fail "$k3st attended dream counted a strike ($(cat "$B/.llm-maintain-fails"); class $(cat "$B/.llm-maintain-fail-class" 2>/dev/null))"
  [ -n "$(defer_row "$k3id is $k3st")" ] \
    && pass "$k3st attended dream: the skip names it in a gate=lane-defer audit row" \
    || fail "$k3st attended dream: no gate=lane-defer row naming $k3id (audit: $(tail -1 "$B/audit-log.jsonl" 2>/dev/null); error: $(tail -1 "$B/error-log.jsonl" 2>/dev/null))"
  K3_AGE=$(mark_age_b)
  [ "$K3_AGE" -gt 3600 ] && pass "$k3st attended dream: the throttle is re-stamped to the retry horizon (mark age ${K3_AGE}s)" \
    || fail "$k3st attended dream: throttle mark left at age ${K3_AGE}s (every drain tick would log again)"
  rm -rf "$B/dreams/$k3id"
done
# 3c. A STALE running dream (status.json untouched past SB_DREAM_RUN_TIMEOUT, 6 h) is a crashed
#     run, not an attended one: the lane must not block on it. dream-snapshot.sh reclaims it to
#     failed and stages the new dream.
mkdir -p "$B/dreams/drm_20260103T000000Z"
jq -nc '{id:"drm_20260103T000000Z",status:"running",archived_at:null}' > "$B/dreams/drm_20260103T000000Z/status.json"
K3_T=$(( $(date +%s) - 25200 ))
touch -d "@$K3_T" "$B/dreams/drm_20260103T000000Z/status.json" 2>/dev/null \
  || touch -t "$(date -r "$K3_T" +%Y%m%d%H%M.%S)" "$B/dreams/drm_20260103T000000Z/status.json"
SB_MAINTAIN_LLM_FORCE=1 SB_MAINTAIN_LLM_DRYRUN=1 bash "$SCRIPT" >/dev/null 2>&1 || true
K3_ST=$(jq -r '.status' "$B/dreams/drm_20260103T000000Z/status.json" 2>/dev/null | tr -d '\r')
[ "$K3_ST" = "failed" ] && [ "$(ndreams)" = "2" ] \
  && pass "stale running dream is not a block: the snapshot reclaims it and stages a new dream" \
  || fail "stale running dream: status=$K3_ST dreams=$(ndreams) (expected failed + a new dream)"
rm -rf "$B"/dreams/drm_*

# 3d. R3-B C5: K3's pre-check sees only a dream that existed before this tick. One created between
#     it and the snapshot (an attended /dream started meanwhile) makes dream-snapshot.sh refuse with
#     "is already pending", and that refusal still counted as a failure strike. The bwrap probe,
#     which runs between the pre-check and the snapshot, stands in for that concurrent dream_create.
C5BIN="$B/bin-c5"; mkdir -p "$C5BIN"
cat > "$C5BIN/bwrap" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = /bin/true ]; then
    mkdir -p "$B/dreams/drm_20260104T000000Z"
    printf '{"id":"drm_20260104T000000Z","status":"pending","archived_at":null}\n' > "$B/dreams/drm_20260104T000000Z/status.json"
    exit 0
  fi
done
exit 0
EOF
chmod +x "$C5BIN/bwrap"
rm -f "$B/error-log.jsonl" "$B/audit-log.jsonl" "$B/.llm-maintain-fails" "$B/.llm-maintain-fail-class"; : > "$B/.last-llm-maintain"
PATH="$C5BIN:$PATH" SB_MAINTAIN_LLM_FORCE=1 SB_MAINTAIN_LLM_DRYRUN=1 bash "$SCRIPT" >/dev/null 2>&1 || true
[ "$(ndreams)" = "1" ] && [ -f "$B/dreams/drm_20260104T000000Z/status.json" ] \
  && pass "C5: a dream created after the pre-check → the snapshot refuses, nothing stacked" \
  || fail "C5: dreams=$(ndreams) after the concurrent pending dream (expected only drm_20260104T000000Z)"
[ ! -f "$B/.llm-maintain-fails" ] && pass "C5: the snapshot's 'already pending' refusal counts no failure strike" \
  || fail "C5: the snapshot's 'already pending' refusal counted a strike ($(cat "$B/.llm-maintain-fails"); class $(cat "$B/.llm-maintain-fail-class" 2>/dev/null))"
[ -n "$(defer_row 'drm_20260104T000000Z is already pending')" ] \
  && pass "C5: the refusal is a gate=lane-defer audit row naming the dream" \
  || fail "C5: no gate=lane-defer row naming drm_20260104T000000Z (audit: $(tail -1 "$B/audit-log.jsonl" 2>/dev/null); error: $(tail -1 "$B/error-log.jsonl" 2>/dev/null))"
C5_AGE=$(mark_age_b)
[ "$C5_AGE" -gt 3600 ] && pass "C5: the throttle is re-stamped to the retry horizon (mark age ${C5_AGE}s)" \
  || fail "C5: throttle mark left at age ${C5_AGE}s"
rm -rf "$B"/dreams/drm_*

# 3e. R3-B S13: a status.json jq cannot read gave the no-stacking check an empty status, so the lane
#     stacked a new dream next to it with no trace. It is an anomaly for a human: one exit_code-1
#     row naming the dream, no new dream, no strike, the throttle re-stamped.
mkdir -p "$B/dreams/drm_20260105T000000Z"; printf '{"id":"drm_2026' > "$B/dreams/drm_20260105T000000Z/status.json"
rm -f "$B/error-log.jsonl" "$B/audit-log.jsonl" "$B/.llm-maintain-fails" "$B/.llm-maintain-fail-class"; : > "$B/.last-llm-maintain"
SB_MAINTAIN_LLM_FORCE=1 SB_MAINTAIN_LLM_DRYRUN=1 bash "$SCRIPT" >/dev/null 2>&1 || true
[ "$(ndreams)" = "1" ] && pass "S13: an unreadable status.json → nothing stacked next to it" \
  || fail "S13: dreams=$(ndreams) next to an unreadable status.json (stacked a new dream)"
jq -c 'select(.script == "maintain-llm-drain" and .exit_code == 1 and ((.message // "") | test("drm_20260105T000000Z.*unreadable")))' \
  "$B/error-log.jsonl" 2>/dev/null | tr -d '\r' | grep -q . \
  && pass "S13: one exit_code-1 error-log row names the unreadable dream" \
  || fail "S13: no exit_code-1 row naming drm_20260105T000000Z (error-log: $(tail -1 "$B/error-log.jsonl" 2>/dev/null))"
[ ! -f "$B/.llm-maintain-fails" ] && [ "$(mark_age_b)" -gt 3600 ] \
  && pass "S13: no failure strike, throttle re-stamped to the retry horizon" \
  || fail "S13: strike=$(cat "$B/.llm-maintain-fails" 2>/dev/null || echo none) mark age=$(mark_age_b)s"
rm -rf "$B"/dreams/drm_*

# 3f. R3-C P-F7: on a host with no jq, S13's check read a well-formed status.json as unreadable and
#     blamed the dream. jq missing is the host's state: one exit_code-1 row naming jq, no
#     "unreadable" row, nothing stacked, no strike, the throttle re-stamped. The jq-less host is
#     simulated as in test-subagent-capture.sh 3e: an exported `command` denies `command -v jq` (it
#     intercepts only that lookup), and a jq on PATH that exits 127 stands in for the absent binary.
mkdir -p "$B/dreams/drm_20260106T000000Z"
jq -nc '{id:"drm_20260106T000000Z",status:"completed",archived_at:"2026-01-06T00:00:00Z"}' > "$B/dreams/drm_20260106T000000Z/status.json"
NOJQ_BIN="$B/bin-nojq"; mkdir -p "$NOJQ_BIN"
printf '#!/bin/bash\necho "jq: command not found" >&2\nexit 127\n' > "$NOJQ_BIN/jq"; chmod +x "$NOJQ_BIN/jq"
rm -f "$B/error-log.jsonl" "$B/audit-log.jsonl" "$B/.llm-maintain-fails" "$B/.llm-maintain-fail-class"; : > "$B/.last-llm-maintain"
( command() { if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then return 1; fi; builtin command "$@"; }
  export -f command
  PATH="$NOJQ_BIN:$PATH" SB_MAINTAIN_LLM_FORCE=1 SB_MAINTAIN_LLM_DRYRUN=1 bash "$SCRIPT" ) >/dev/null 2>&1 || true
[ "$(ndreams)" = "1" ] && pass "P-F7: no jq → nothing stacked" || fail "P-F7: dreams=$(ndreams) with no jq (stacked a new dream)"
grep -q 'unreadable status.json' "$B/error-log.jsonl" 2>/dev/null \
  && fail "P-F7: no jq was reported as an unreadable status.json ($(grep 'unreadable' "$B/error-log.jsonl" | head -1))"
jq -c 'select(.script == "maintain-llm-drain" and .exit_code == 1 and ((.message // "") | test("jq not found")))' \
  "$B/error-log.jsonl" 2>/dev/null | tr -d '\r' | grep -q . \
  && pass "P-F7: one exit_code-1 row says jq is missing" \
  || fail "P-F7: no exit_code-1 row naming the missing jq (error-log: $(tail -1 "$B/error-log.jsonl" 2>/dev/null))"
[ ! -f "$B/.llm-maintain-fails" ] && [ "$(mark_age_b)" -gt 3600 ] \
  && pass "P-F7: no failure strike, throttle re-stamped to the retry horizon" \
  || fail "P-F7: strike=$(cat "$B/.llm-maintain-fails" 2>/dev/null || echo none) mark age=$(mark_age_b)s"
rm -rf "$B"/dreams/drm_* "$NOJQ_BIN"

# The source transcripts dir must still exist here: seed_tx's write is unchecked, so a case above
# that removed it would turn case 4 into a run with no transcripts that fails for another reason.
[ -d "$B/transcripts" ] || fail "case 4 precondition: $B/transcripts is gone before seeding"

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

# --- (d2) R3-B S5: an auto-accept that dream-accept refuses. The lane ran dream-accept with stdout
#          and stderr discarded, so its row said only "refused/failed" with exit_code 0 and the
#          reason was lost. A tar that fails makes dream-accept refuse (it never applies without
#          its pre-accept backup); the row must carry dream-accept's error line, exit_code 1.
reset
TARSHIM="$B2/bin-tar"; mkdir -p "$TARSHIM"
printf '#!%s\necho "tar: simulated: No space left on device" >&2\nexit 2\n' "$BASH" > "$TARSHIM/tar"; chmod +x "$TARSHIM/tar"
printf '{"auto_maintain": true, "auto_accept": "safe"}\n' > "$BRAIN_DIR/config.json"
run_drain PATH="$TARSHIM:$PATH"
printf '{"auto_maintain": true, "auto_accept": "off"}\n' > "$BRAIN_DIR/config.json"
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "completed" ] || fail "(d2) precondition: the run did not complete (got $(jq -r '.status' "$SF" 2>/dev/null))"
AA_A=$(jq -r '.archived_at // ""' "$SF" 2>/dev/null | tr -d '\r')
{ [ -z "$AA_A" ] || [ "$AA_A" = "null" ]; } || fail "(d2) the refused dream was archived ($AA_A)"
AAROW=$(jq -c 'select(.script == "maintain-llm-drain" and .exit_code == 1 and ((.message // "") | test("refused/failed.*could not back up the live wiki.*simulated")))' \
  "$BRAIN_DIR/error-log.jsonl" 2>/dev/null | tr -d '\r')
[ -n "$AAROW" ] && pass "(d2) a refused auto-accept logs dream-accept's own error line, exit_code 1" \
  || fail "(d2) refused auto-accept row lacks the reason or exit_code 1 (rows: $(grep 'auto_accept' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null | tail -2))"

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
