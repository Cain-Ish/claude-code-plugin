#!/bin/bash
# pins: SB_EXTRACT_STUB — stubs the extractor so the deterministic-maintain path runs hermetically
# pins: SB_INTERACTIVE_OVERRIDE — forces the interactive-session gate to the non-interactive branch under test
# pins: SB_MAINTAIN_FORCE — forces the maintenance tick to run regardless of its normal due-time gate
# B2 (SP-B): the deterministic out-of-band consolidation — validate+backfill+reindex,
# NO LLM, NO creds, self-throttled — plus the extract-drain `auto_improve` gate.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
MD="$ROOT/scripts/maintain-deterministic.sh"
DRAIN="$ROOT/scripts/extract-drain.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
# Run out-of-band: inside a Claude session CLAUDECODE=1 leaks in and the drainer
# (correctly) refuses, so the gate is never reached. Same as test-extract-drain.sh.
unset CLAUDECODE 2>/dev/null || true
HAS_NODE=0; command -v node >/dev/null 2>&1 && [ -f "$ROOT/mcp/dist/tools/knowledge-reindex.bundle.js" ] && HAS_NODE=1

# Content-free guard: must never shell out to an LLM.
grep -qE 'claude -p|sb_call_extractor|claude_-p' "$MD" && fail "maintain-deterministic invokes an LLM (must be content-free)" || pass "content-free (no LLM)"

# --- the script: marker + throttle ---
B=$(mktemp -d); export BRAIN_DIR="$B" KNOWLEDGE_DIR="$B/knowledge"
mkdir -p "$KNOWLEDGE_DIR/wiki/concepts"
printf -- '---\ntype: concepts\ntitle: X\n---\n# X\nbody body body\n' > "$KNOWLEDGE_DIR/wiki/concepts/x.md"

SB_MAINTAIN_FORCE=1 bash "$MD" >/dev/null 2>&1 || true
[ -f "$B/.last-maintain" ] && pass "forced run writes the .last-maintain marker" || fail "no marker after forced run"
if [ "$HAS_NODE" = 1 ]; then
  [ -f "$KNOWLEDGE_DIR/wiki/index.md" ] && pass "forced run reindexed (index.md built)" || fail "no index.md after forced run"
  rm -f "$KNOWLEDGE_DIR/wiki/index.md"
  bash "$MD" >/dev/null 2>&1 || true                    # no FORCE, marker fresh → throttled
  [ -f "$KNOWLEDGE_DIR/wiki/index.md" ] && fail "ran despite a fresh throttle marker" || pass "self-throttles when marker is fresh"
else
  echo "SKIP: node/reindex bundle absent — index.md assertions skipped"
fi

# --- the extract-drain `auto_improve` gate ---
mktx(){ mkdir -p "$1/transcripts"; : > "$1/transcripts/$2"; }
# auto OFF (EXPLICIT — 0.30.0 made absent default to ON) → maintain NOT run
G=$(mktemp -d); mktx "$G" "a_proj_2026-05-24.txt"; mkdir -p "$G/knowledge/wiki"
printf '{"auto_improve": false}\n' > "$G/config.json"
( export BRAIN_DIR="$G" KNOWLEDGE_DIR="$G/knowledge" SB_INTERACTIVE_OVERRIDE=inactive SB_EXTRACT_STUB=1
  bash "$DRAIN" >/dev/null 2>&1 ) || true
[ -f "$G/.last-maintain" ] && fail "deterministic maintain ran with auto_improve OFF" || pass "auto_improve off → no out-of-band maintain"
rm -f "$G/config.json"
# auto ON → maintain runs (marker appears)
printf '{"auto_improve": true}\n' > "$G/config.json"; mktx "$G" "b_proj_2026-05-24.txt"
( export BRAIN_DIR="$G" KNOWLEDGE_DIR="$G/knowledge" SB_INTERACTIVE_OVERRIDE=inactive SB_EXTRACT_STUB=1 SB_MAINTAIN_FORCE=1
  bash "$DRAIN" >/dev/null 2>&1 ) || true
[ -f "$G/.last-maintain" ] && pass "auto_improve on → out-of-band maintain runs" || fail "maintain did not run with auto_improve on"

rm -rf "$B" "$G"; echo; echo "ALL PASS"
