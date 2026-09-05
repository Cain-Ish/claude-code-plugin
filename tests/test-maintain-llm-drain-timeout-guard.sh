#!/bin/bash
# pins: SB_DREAM_RUN_TIMEOUT — raises this unrelated timeout ceiling so it can't fire while this file tests the SPAWN-PATH timeout guard specifically
# pins: SB_MAINTAIN_LLM_DRYRUN — the flag itself is the subject of this subtest (dry-run path)
# pins: SB_MAINTAIN_LLM_FORCE — forces the lane to run regardless of its normal due gate, for a deterministic fixture run
# pins: SB_MAINTAIN_LLM_TIMEOUT — raises this unrelated timeout ceiling so it can't fire while isolating the SPAWN-PATH timeout guard under test
# maintain-llm-drain.sh hardening:
#   B1: refuse the quarantined summarizer when neither timeout nor gtimeout is on
#       PATH (a bare `${TBIN:+...}` form would run it UNBOUNDED).
#   B2: terminal-state discipline around the harness-owned completion: corrupt/missing
#       status.json at completion is minted to a PARSEABLE failed doc (counters retained);
#       a clean success completes; rc!=0 strikes with captured stderr.
#   Every lane here runs with bwrap GENUINELY ABSENT from PATH — the true-absence proof
#   that the jail is additive and gates nothing.
# ORACLE: a curated PATH that physically lacks timeout/gtimeout (and bwrap), a mock claude
# whose stream-json + rc WE control, and a run-reached sentinel — every assertion reads the
# on-disk status.json / error-log the SCRIPT wrote with an independent jq, never by re-reading
# the script's own logic.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/maintain-llm-drain.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }
unset CLAUDECODE CLAUDE_SESSION_ID 2>/dev/null || true
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export HOME="$SB" BRAIN_DIR="$SB/brain" KNOWLEDGE_DIR="$SB/knowledge"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SB/knowledge"
mkdir -p "$BRAIN_DIR/transcripts" "$KNOWLEDGE_DIR/wiki/concepts" "$BRAIN_DIR/dreams"
printf -- '---\ntitle: t\ntype: concepts\n---\n\n# t\nbody\n' > "$KNOWLEDGE_DIR/wiki/concepts/t.md"
printf 'tx\n' > "$BRAIN_DIR/transcripts/sess_x_2026-01-01.txt"
# auto_accept off so a completed dream never trips the real merge path.
printf '{"auto_maintain": true, "auto_accept": "off"}\n' > "$BRAIN_DIR/config.json"
FAILS="$BRAIN_DIR/.llm-maintain-fails"; QUAR="$BRAIN_DIR/.llm-maintain-quarantine"
MARK="$BRAIN_DIR/.last-llm-maintain"; SENT="$BRAIN_DIR/.run-reached"

# Mock claude: --version reports a pinned version (preflight); a -p run marks the sentinel,
# drains the prompt, emits canned stream-json (attestation-clean by default), and honors
# SB_TEST_CLAUDE_RC / SB_TEST_CLAUDE_STDERR / SB_TEST_TRUNCATE_STATUS. NO bwrap stub exists
# anywhere on the curated PATHs — bwrap is genuinely absent in every lane.
STUB="$SB/stub"; mkdir -p "$STUB"
cat > "$STUB/claude" <<'EOF'
#!/bin/bash
for a in "$@"; do
  [ "$a" = "--version" ] && { echo "${SB_TEST_CLAUDE_VERSION:-2.1.220} (Claude Code)"; exit 0; }
done
[ -n "${SB_TEST_RUN_SENTINEL:-}" ] && pwd > "$SB_TEST_RUN_SENTINEL"
cat > /dev/null
printf '{"type":"system","subtype":"init","tools":["StructuredOutput"],"mcp_servers":[]}\n'
if [ "${SB_TEST_NO_STRUCTURED:-0}" = "1" ]; then
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":null}\n'
else
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"facts":[{"kind":"learning","claim":"canned-fact"}]}}\n'
fi
if [ "${SB_TEST_TRUNCATE_STATUS:-0}" = "1" ]; then
  sf=$(ls "$BRAIN_DIR"/dreams/drm_*/status.json 2>/dev/null | head -1)
  [ -n "$sf" ] && printf '{"id":"x","status":"runn' > "$sf"
fi
if [ "${SB_TEST_DELETE_STATUS:-0}" = "1" ]; then
  sf=$(ls "$BRAIN_DIR"/dreams/drm_*/status.json 2>/dev/null | head -1)
  [ -n "$sf" ] && rm -f "$sf"
fi
[ -n "${SB_TEST_CLAUDE_STDERR:-}" ] && echo "$SB_TEST_CLAUDE_STDERR" >&2
exit "${SB_TEST_CLAUDE_RC:-0}"
EOF
chmod +x "$STUB/claude"

# CLEANBIN: a directory with wrapper scripts for every tool maintain-llm-drain.sh
# (and lib.sh / dream-snapshot.sh) actually calls, but NOT timeout/gtimeout (and not
# bwrap).  On Windows/Git-Bash, creating symlinks to PE32+ executables from a temp dir
# fails with DLL-resolution errors, and walking the full PATH (including
# /c/Windows/system32) to build a symlink forest takes 30s+ and times out.  Using tiny
# wrapper scripts avoids both problems: they're plain text, resolve DLLs correctly (the
# shell resolves the exec'd binary from its real path), and we only need ~20 of them.
CLEANBIN="$SB/cleanbin"; mkdir -p "$CLEANBIN"
_make_wrapper() {
  local name="$1" real
  real=$(command -v "$name" 2>/dev/null) || return 0
  # Safety: never wrap the binaries we are deliberately removing from PATH
  case "$(basename "$real")" in timeout|gtimeout|timeout.exe|gtimeout.exe) return 0 ;; esac
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$CLEANBIN/$name"
  chmod +x "$CLEANBIN/$name"
}
for _t in bash sh jq stat date touch cat find wc head tail ls rm mkdir mv \
          awk sed tr grep sort cp realpath readlink basename dirname mktemp git \
          node; do   # node: the Stage B consolidate-writer is a hard harness dependency
  _make_wrapper "$_t"
done
unset _t
unset -f _make_wrapper
ORIG_PATH="$PATH"

reset(){ rm -rf "$BRAIN_DIR/dreams"; mkdir -p "$BRAIN_DIR/dreams"; rm -f "$FAILS" "$QUAR" "$MARK" "$SENT" "$BRAIN_DIR/error-log.jsonl"; }
run(){ env "$@" SB_MAINTAIN_LLM_FORCE=1 SB_TEST_RUN_SENTINEL="$SENT" PATH="$RUN_PATH" bash "$SCRIPT" >/dev/null 2>&1 || true; }
dsf(){ ls "$BRAIN_DIR"/dreams/drm_*/status.json 2>/dev/null | head -1; }

echo "=== B1: refuse to run unbounded when no timeout/gtimeout ==="
RUN_PATH="$STUB:$CLEANBIN"
if PATH="$RUN_PATH" command -v timeout >/dev/null 2>&1 || PATH="$RUN_PATH" command -v gtimeout >/dev/null 2>&1; then
  echo "  SKIP: could not remove timeout/gtimeout from PATH on this host"
else
  # B1a: no wall-clock binary → refuse, mark dream failed, never reach the quarantined run.
  reset
  run
  SF=$(dsf)
  [ -n "$SF" ] && pass "B1a: a dream was staged" || fail "B1a: no dream staged"
  [ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] && pass "B1a: dream marked failed (not left pending)" || fail "B1a: dream not failed ($(jq -r '.status' "$SF" 2>/dev/null))"
  jq -r '.error' "$SF" 2>/dev/null | grep -qiE 'unbounded|no timeout' && pass "B1a: error names the unbounded refusal" || fail "B1a: error missing"
  [ "$(jq -r '.ended_at' "$SF" 2>/dev/null)" != "null" ] && pass "B1a: ended_at set" || fail "B1a: ended_at null"
  grep -q 'refusing to run the quarantined summarizer UNBOUNDED' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null && pass "B1a: refusal logged" || fail "B1a: refusal not logged"
  [ ! -e "$SENT" ] && pass "B1a: the quarantined run was NEVER reached (no unbounded exec)" || fail "B1a: run sentinel present — summarizer ran unbounded"

  # B1b: a timeout stub present → guard dormant, run proceeds — with bwrap ABSENT from the
  # curated PATH, proving absence gates nothing (the run completes end-to-end).
  TOUT="$SB/tout"; mkdir -p "$TOUT"
  printf '#!/bin/bash\nshift; exec "$@"\n' > "$TOUT/timeout"; chmod +x "$TOUT/timeout"
  reset; RUN_PATH="$TOUT:$STUB:$CLEANBIN"
  PATH="$RUN_PATH" command -v bwrap >/dev/null 2>&1 && fail "B1b: bwrap unexpectedly on the curated PATH" || true
  run
  [ -e "$SENT" ] && pass "B1b: with timeout present the quarantined run IS reached" || fail "B1b: run not reached despite timeout"
  grep -q 'refusing to run the quarantined summarizer UNBOUNDED' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null && fail "B1b: refusal fired despite timeout present" || pass "B1b: no false refusal when timeout exists"
  [ "$(jq -r '.status' "$(dsf)" 2>/dev/null)" = "completed" ] && pass "B1b: bwrap-absent run completes (jail is additive, never a gate)" || fail "B1b: bwrap-absent run did not complete ($(jq -r '.status' "$(dsf)" 2>/dev/null))"

  # B1b-gtimeout: only gtimeout present (macOS branch of the || chain).
  rm -f "$TOUT/timeout"; printf '#!/bin/bash\nshift; exec "$@"\n' > "$TOUT/gtimeout"; chmod +x "$TOUT/gtimeout"
  reset; RUN_PATH="$TOUT:$STUB:$CLEANBIN"
  run
  [ -e "$SENT" ] && pass "B1b: gtimeout-only (macOS branch) also proceeds" || fail "B1b: gtimeout branch did not proceed"
fi

echo "=== B2: terminal-state discipline around harness-owned completion ==="
# Real wall-clock binary, mock claude, curated core tools — bwrap still genuinely absent.
REALT=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
[ -n "$REALT" ] || { echo "  SKIP: host has no timeout/gtimeout for the B2 spawn path"; echo; echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; }
TOUTREAL="$SB/toutreal"; mkdir -p "$TOUTREAL"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REALT" > "$TOUTREAL/timeout"; chmod +x "$TOUTREAL/timeout"
RUN_PATH="$TOUTREAL:$STUB:$CLEANBIN"

# B2a: clean success → harness completes the dream and lands candidate-facts.json.
reset
run
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "completed" ] && pass "B2a: clean run → harness-owned completion" || fail "B2a: not completed ($(jq -r '.status' "$SF" 2>/dev/null))"
[ -f "$(dirname "$SF")/candidate-facts.json" ] && pass "B2a: candidate-facts.json landed" || fail "B2a: candidate-facts.json missing"

# B2b: corrupt status.json at completion (external interference — a tool-less child cannot
# touch it) → minted to a PARSEABLE terminal failed doc; counters retained, not cleared.
reset
printf '2' > "$FAILS"   # pre-seed strikes (below the 3-strike quarantine threshold)
run SB_TEST_TRUNCATE_STATUS=1
SF=$(dsf)
{ [ -n "$SF" ] && jq -e . "$SF" >/dev/null 2>&1; } && pass "B2b: corrupt status.json minted to valid JSON (not left unparseable)" || fail "B2b: status.json left unparseable"
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] && pass "B2b: corrupt status healed to terminal failed" || fail "B2b: not healed ($(jq -r '.status' "$SF" 2>/dev/null))"
[ "$(cat "$FAILS" 2>/dev/null)" = "2" ] && pass "B2b: interference retains the strike counter (not a success)" || fail "B2b: counter wrongly changed (got '$(cat "$FAILS" 2>/dev/null)')"

# B2c: DELETED status.json at completion → same minting discipline, counters retained.
reset
printf '2' > "$FAILS"
run SB_TEST_DELETE_STATUS=1
SF=$(dsf)
{ [ -n "$SF" ] && jq -e . "$SF" >/dev/null 2>&1; } && pass "B2c: missing status.json re-minted as valid JSON" || fail "B2c: no parseable status.json after deletion"
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] && pass "B2c: deletion healed to terminal failed" || fail "B2c: not failed ($(jq -r '.status' "$SF" 2>/dev/null))"
[ "$(cat "$FAILS" 2>/dev/null)" = "2" ] && pass "B2c: deletion retains the strike counter" || fail "B2c: counter wrongly changed (got '$(cat "$FAILS" 2>/dev/null)')"

# B2d: hard failure (rc!=0) — strikes + captures stderr.
reset
run SB_TEST_CLAUDE_RC=1 SB_TEST_CLAUDE_STDERR="boom: auth exploded"
SF=$(dsf)
[ "$(jq -r '.status' "$SF" 2>/dev/null)" = "failed" ] && pass "B2d: rc!=0 →failed" || fail "B2d: rc!=0 not failed"
jq -r '.error' "$SF" 2>/dev/null | grep -q 'boom' && pass "B2d: rc!=0 captures stderr" || fail "B2d: stderr not captured"
[ "$(cat "$FAILS" 2>/dev/null)" = "1" ] && pass "B2d: rc!=0 counts a strike (hard failure)" || fail "B2d: strike not counted (got $(cat "$FAILS" 2>/dev/null))"

# CLAMP: an operator override of SB_MAINTAIN_LLM_TIMEOUT >= SB_DREAM_RUN_TIMEOUT must be clamped
# below the staleness horizon, so a live headless dream can never age past 6h and get wrongly
# reclaimed + double-spawned (the cap — not a machine heartbeat — is the staleness guarantee).
reset
run SB_MAINTAIN_LLM_DRYRUN=1 SB_MAINTAIN_LLM_TIMEOUT=99999 SB_DREAM_RUN_TIMEOUT=21600
grep -q 'clamping to' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null && pass "clamp: SB_MAINTAIN_LLM_TIMEOUT >= horizon is clamped below it" || fail "clamp: oversized maintain timeout not clamped"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
