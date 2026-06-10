#!/usr/bin/env bash
# tests/test-session-load-relink.sh — R2.4 (MCP-DEPS-1): when transformers are
# missing from the plugin cache but the shared vector-deps tree is intact,
# SessionStart re-links AUTOMATICALLY (pure local symlink — no download, no
# consent needed) and banners "auto-relinked" once, instead of asking the user
# to run a command. When the relink-only path can't apply (installer exit 3),
# the manual fix-it banner remains. Mirrors test-session-load-embed-banner.sh:
# extract block 0b, run standalone with an sb_append stub.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$SCRIPT_DIR/scripts/session-load.sh"

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

mkidx() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
p, nf, ne = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ex = [{"embedding": [0.1, 0.2, 0.3]} for _ in range(nf)] + [{"embedding": []} for _ in range(ne)]
json.dump({"exchanges": ex}, open(p, "w"))
PY
}

run() { env -i HOME="$HOME" PATH="$PATH" "$@" bash "$TMP/runner.sh"; }

# Fake plugin root: deps ABSENT (no mcp/node_modules/@huggingface/transformers),
# with a stub installer that records its args and exits per SB_TEST_RELINK_RC.
PR="$TMP/plugin-root"; mkdir -p "$PR/bin" "$PR/mcp"
CALLED="$TMP/relink-called"
cat > "$PR/bin/install-vector-deps.sh" <<EOF
#!/bin/bash
printf '%s' "\${1:-}" > "$CALLED"
exit "\${SB_TEST_RELINK_RC:-0}"
EOF
chmod +x "$PR/bin/install-vector-deps.sh"

BD="$TMP/brain"; mkdir -p "$BD"; mkidx "$BD/episodic-index.json" 5 0

# --- Case 1: relink succeeds -> auto-relinked banner, NOT the manual banner ---
out=$(run BRAIN_DIR="$BD" CLAUDE_PLUGIN_ROOT="$PR" SB_TEST_RELINK_RC=0)
[ -f "$CALLED" ] || { echo "FAIL 1: install-vector-deps.sh was not invoked"; exit 1; }
[ "$(cat "$CALLED")" = "--relink-only" ] || { echo "FAIL 1: expected --relink-only arg, got '$(cat "$CALLED")'"; exit 1; }
echo "$out" | grep -q "auto-relinked" || { echo "FAIL 1: missing auto-relinked banner:"; echo "$out"; exit 1; }
echo "$out" | grep -q "vector search degraded" && { echo "FAIL 1: manual banner still shown after successful relink:"; echo "$out"; exit 1; }
echo "PASS 1: successful relink banners auto-relinked, suppresses the manual banner"

# --- Case 2: relink-only not applicable (exit 3) -> manual banner remains ---
rm -f "$CALLED"
out=$(run BRAIN_DIR="$BD" CLAUDE_PLUGIN_ROOT="$PR" SB_TEST_RELINK_RC=3)
[ -f "$CALLED" ] || { echo "FAIL 2: installer not even attempted"; exit 1; }
echo "$out" | grep -q "vector search degraded" || { echo "FAIL 2: manual banner missing on relink failure:"; echo "$out"; exit 1; }
echo "$out" | grep -q "auto-relinked" && { echo "FAIL 2: auto-relinked banner shown despite rc=3:"; echo "$out"; exit 1; }
echo "PASS 2: failed relink falls back to the manual fix-it banner"

# --- Case 3: successful relink + >10 pending empties -> still ONLY the relinked
# banner this session (backfill rides the next session-end indexer run) ---
BDC="$TMP/brain-pending"; mkdir -p "$BDC"; mkidx "$BDC/episodic-index.json" 3 12
out=$(run BRAIN_DIR="$BDC" CLAUDE_PLUGIN_ROOT="$PR" SB_TEST_RELINK_RC=0)
echo "$out" | grep -q "auto-relinked" || { echo "FAIL 3: relinked banner missing:"; echo "$out"; exit 1; }
echo "$out" | grep -q "vector search degraded" && { echo "FAIL 3: pending-count banner fired in the same session as a successful relink:"; echo "$out"; exit 1; }
echo "PASS 3: relink session shows one banner, not a second pending nag"

echo "ALL PASS"
