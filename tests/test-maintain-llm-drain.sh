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
grep -q 'credentials.json' "$SCRIPT"              && pass "only the OAuth credential file is writable" || fail "creds-only bind missing"
# the ONLY executed claude invocation must be the bwrap-jailed one (the -- claude line); guard against
# a bare unconfined `claude -p` slipping in (the DRYRUN/echo + comments don't count as executed runs).
BARE=$(grep -nE '(^|[^-] )claude -p' "$SCRIPT" | grep -v 'printf\|echo\|#' | grep -v -- '-- claude -p' | wc -l | tr -d ' ')
[ "$BARE" = "0" ] && pass "no unconfined claude -p (only the bwrap-jailed exec)" || fail "found $BARE unconfined claude -p"

# --- functional gating ---
B=$(mktemp -d); export BRAIN_DIR="$B" KNOWLEDGE_DIR="$B/knowledge" HOME="$B"
mkdir -p "$KNOWLEDGE_DIR/wiki/concepts" "$B/transcripts" "$B/dreams"
printf -- '---\ntype: concepts\ntitle: X\n---\n# X\nbody\n' > "$KNOWLEDGE_DIR/wiki/concepts/x.md"
BIN="$B/bin"; mkdir -p "$BIN"; printf '#!/bin/bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"   # stub claude (DRYRUN exits before invoking it anyway)
ndreams(){ find "$B/dreams" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | wc -l | tr -d ' '; }

# 1. auto_maintain OFF (no config) → no run, no marker, no dream
bash "$SCRIPT" >/dev/null 2>&1 || true
{ [ ! -f "$B/.last-llm-maintain" ] && [ "$(ndreams)" = "0" ]; } && pass "auto_maintain off → no run" || fail "ran while off"

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

rm -rf "$B"; echo; echo "ALL PASS"
