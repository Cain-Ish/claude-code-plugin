#!/usr/bin/env bash
# Verify the SessionStart episodic-embeddings degradation banner (block 0b in
# scripts/session-load.sh). The key regression this guards: vector deps go
# missing on EVERY plugin-cache refresh (cache ships dist/ but not node_modules/),
# and the old index-state-only check stayed silent until 11+ new exchanges rotted.
# Block 0b now ALSO fires on deps-absent immediately — gated on an index already
# existing so fresh installs aren't nagged, and suppressible.
#
# Strategy mirrors test-session-load-auth-banner.sh: extract just block 0b into a
# standalone runner with an sb_append stub, and drive it under controlled env.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$SCRIPT_DIR/scripts/session-load.sh"

# Extract block 0b: from the "# 0b." marker up to (not including) "# 1.".
BLOCK=$(awk '
  /^# 0b\./ {p=1}
  p && /^# 1\./ {exit}
  p {print}
' "$SOURCE")
[ -n "$BLOCK" ] || { echo "FAIL: could not extract block 0b from session-load.sh"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/runner.sh" <<'EOF'
sb_append() { printf '[%s]\n%s\n' "$2" "$1"; }
EOF
printf '%s\n' "$BLOCK" >> "$TMP/runner.sh"

# mkidx <path> <n_full> <n_empty> — write an episodic index fixture.
mkidx() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
p, nf, ne = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ex = [{"embedding": [0.1, 0.2, 0.3]} for _ in range(nf)] + [{"embedding": []} for _ in range(ne)]
json.dump({"exchanges": ex}, open(p, "w"))
PY
}

run() { env -i HOME="$HOME" PATH="$PATH" "$@" bash "$TMP/runner.sh"; }

# --- Case A: deps ABSENT, index has only full embeddings (pending=0) -> FIRE ---
# This is the bug: a refreshed cache drops node_modules while the old index still
# has embeddings, so the legacy pending-count check would stay silent.
BD="$TMP/a"; mkdir -p "$BD"; mkidx "$BD/episodic-index.json" 5 0
CRA="$TMP/cacheA"; mkdir -p "$CRA/mcp"   # NO node_modules/@huggingface/transformers
out=$(run BRAIN_DIR="$BD" CLAUDE_PLUGIN_ROOT="$CRA")
echo "$out" | grep -q "not installed in this plugin cache" \
  || { echo "FAIL A: deps-absent banner did not fire (the regression being fixed):"; echo "$out"; exit 1; }
echo "PASS A: deps-absent fires immediately despite a full-embedding index"

# --- Case B: deps PRESENT, pending=0 -> NO banner ---
CRB="$TMP/cacheB"; mkdir -p "$CRB/mcp/node_modules/@huggingface/transformers"
out=$(run BRAIN_DIR="$BD" CLAUDE_PLUGIN_ROOT="$CRB")
echo "$out" | grep -qi "degraded" \
  && { echo "FAIL B: banner fired with deps present and nothing pending:"; echo "$out"; exit 1; }
echo "PASS B: silent when deps present and nothing pending"

# --- Case C: deps PRESENT, >10 pending empties -> FIRE (legacy trigger kept) ---
BDC="$TMP/c"; mkdir -p "$BDC"; mkidx "$BDC/episodic-index.json" 3 12
out=$(run BRAIN_DIR="$BDC" CLAUDE_PLUGIN_ROOT="$CRB")
echo "$out" | grep -q "have no embedding" \
  || { echo "FAIL C: pending-count banner did not fire:"; echo "$out"; exit 1; }
echo "PASS C: pending>10 fires (legacy behavior preserved)"

# --- Case D: deps ABSENT but suppressed via env ---
out=$(run BRAIN_DIR="$BD" CLAUDE_PLUGIN_ROOT="$CRA" SB_EMBED_PENDING_BANNER=off)
echo "$out" | grep -qi "degraded" \
  && { echo "FAIL D: SB_EMBED_PENDING_BANNER=off did not suppress:"; echo "$out"; exit 1; }
echo "PASS D: suppressible via SB_EMBED_PENDING_BANNER=off"

# --- Case E: no index file (fresh install) + deps absent -> NOT nagged ---
BDE="$TMP/e"; mkdir -p "$BDE"   # no episodic-index.json
out=$(run BRAIN_DIR="$BDE" CLAUDE_PLUGIN_ROOT="$CRA")
echo "$out" | grep -qi "degraded" \
  && { echo "FAIL E: nagged a fresh install with no index:"; echo "$out"; exit 1; }
echo "PASS E: fresh install (no index) not nagged"

echo "ALL PASS"
