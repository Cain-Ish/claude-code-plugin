#!/usr/bin/env bash
# pins: SB_EMBED_PENDING_BANNER — kill-switch test: asserts =off suppresses the embed-pending banner
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
  p && /^# 0c\./ {exit}
  p {print}
' "$SOURCE")
[ -n "$BLOCK" ] || { echo "FAIL: could not extract block 0b from session-load.sh"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# sb_log_error is stubbed to stdout so the gate=banner emission row is assertable.
cat > "$TMP/runner.sh" <<'EOF'
sb_append() { printf '[%s]\n%s\n' "$2" "$1"; }
sb_log_error() { printf 'LOG %s ec=%s\n' "$2" "${3:-1}"; }
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
echo "$out" | grep -q "not linked in this plugin cache" \
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

# --- B4 residual (2026-09-28): the package dir EXISTS but will not import --------------
# 171 of 183 embeddings errors were "Cannot find package '…transformers\index.js'" with the
# dir present, so the `[ ! -d … ]` trigger stayed silent. A recent (24h) import-failure row
# in error-log.jsonl for THIS plugin version now fires the same banner, which also names the
# wiki knowledge_search bm25-only degradation, and every emission logs gate=banner.
iso_ago() {   # iso_ago <seconds> -> UTC ISO-8601 that many seconds ago (GNU or BSD date)
  local s=$(( $(date +%s) - $1 ))
  date -u -d "@$s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$s" +%Y-%m-%dT%H:%M:%SZ
}
BS=$(printf '\134')   # one backslash, built at runtime so this file carries no escape text
# winpath <version> <tail...> -> a Windows plugin-cache path, as embeddings.ts logs it.
winpath() {
  local out p
  out="C:${BS}Users${BS}u${BS}.claude${BS}plugins${BS}cache${BS}second-brain${BS}second-brain${BS}$1"
  shift; for p in "$@"; do out="$out$BS$p"; done; printf '%s' "$out"
}
# errrow <ts> <script> <message> -> one JSON error-log line (jq escapes the backslashes).
errrow() { jq -nc --arg t "$1" --arg s "$2" --arg m "$3" '{timestamp:$t, script:$s, message:$m, exit_code:0}' | tr -d '\r'; }
import_msg() {
  printf "transformers model load failed: Cannot find package '%s' imported from %s — run: bash \$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh" \
    "$(winpath "$1" mcp node_modules @huggingface transformers index.js)" \
    "$(winpath "$1" mcp dist tools context-serve-cli.bundle.js)"
}
# The installed plugin root is a version dir with the package dir PRESENT (trigger 1 silent).
CRV="$TMP/cache/second-brain/second-brain/0.54.0"
mkdir -p "$CRV/mcp/node_modules/@huggingface/transformers"

# --- Case F: dir present + recent import failure for THIS version -> FIRE ---
BDF="$TMP/f"; mkdir -p "$BDF"; mkidx "$BDF/episodic-index.json" 5 0
errrow "$(iso_ago 3600)" embeddings "$(import_msg 0.54.0)" > "$BDF/error-log.jsonl"
out=$(run BRAIN_DIR="$BDF" CLAUDE_PLUGIN_ROOT="$CRV")
echo "$out" | grep -qi "degraded" \
  || { echo "FAIL F: dir present + recent import failure did not fire:"; echo "$out"; exit 1; }
echo "$out" | grep -q "failed to load" \
  || { echo "FAIL F: banner does not name the import failure:"; echo "$out"; exit 1; }
echo "$out" | grep -q "bm25-only" \
  || { echo "FAIL F: banner does not cover wiki bm25-only search:"; echo "$out"; exit 1; }
echo "$out" | grep -q "gate=banner name=episodic-embed-pending-banner fired=1 reason=import-failure" \
  || { echo "FAIL F: banner emission was not logged (gate=banner … fired=1):"; echo "$out"; exit 1; }
echo "PASS F: package dir present but import failing (recent row) fires + logs gate=banner"

# --- Case G: same failure but 30h old -> NO banner (healed since) ---
BDG="$TMP/g"; mkdir -p "$BDG"; mkidx "$BDG/episodic-index.json" 5 0
errrow "$(iso_ago 108000)" embeddings "$(import_msg 0.54.0)" > "$BDG/error-log.jsonl"
out=$(run BRAIN_DIR="$BDG" CLAUDE_PLUGIN_ROOT="$CRV")
echo "$out" | grep -qi "degraded" \
  && { echo "FAIL G: fired on an import failure older than 24h:"; echo "$out"; exit 1; }
echo "PASS G: import failure older than 24h does not fire"

# --- Case H: healthy (dir present, no rows, nothing pending) -> silent, no fired=1 row ---
BDH="$TMP/h"; mkdir -p "$BDH"; mkidx "$BDH/episodic-index.json" 5 0
: > "$BDH/error-log.jsonl"
out=$(run BRAIN_DIR="$BDH" CLAUDE_PLUGIN_ROOT="$CRV")
echo "$out" | grep -qiE "degraded|fired=1" \
  && { echo "FAIL H: healthy install produced a banner or a fired=1 row:"; echo "$out"; exit 1; }
echo "PASS H: healthy install stays silent"

# --- Case I: recent failure logged by an OLDER plugin version -> NO banner ---
# (2026-09-28: 0.53.0 failed at 14:17, 0.54.0 installed healthy at 16:18.)
BDI="$TMP/i"; mkdir -p "$BDI"; mkidx "$BDI/episodic-index.json" 5 0
errrow "$(iso_ago 3600)" embeddings "$(import_msg 0.53.0)" > "$BDI/error-log.jsonl"
out=$(run BRAIN_DIR="$BDI" CLAUDE_PLUGIN_ROOT="$CRV")
echo "$out" | grep -qi "degraded" \
  && { echo "FAIL I: fired on another plugin version's import failure:"; echo "$out"; exit 1; }
echo "PASS I: another version's import failure does not fire"

# --- Case J: persona-context's version-less "bm25-only" relink row, dir present -> NO banner ---
# That row names no plugin root; its only true positive (THIS root's dir missing) is trigger
# (1). Counting it would nag a healthy upgraded install for 24h.
BDJ="$TMP/j"; mkdir -p "$BDJ"; mkidx "$BDJ/episodic-index.json" 5 0
errrow "$(iso_ago 600)" persona-context.sh "vector-deps relink failed after cache refresh — embeddings bm25-only until fixed" \
  > "$BDJ/error-log.jsonl"
out=$(run BRAIN_DIR="$BDJ" CLAUDE_PLUGIN_ROOT="$CRV")
echo "$out" | grep -qiE "degraded|fired=1" \
  && { echo "FAIL J: a version-less relink row fired on a healthy root:"; echo "$out"; exit 1; }
echo "PASS J: version-less bm25-only relink row does not fire on a healthy root"

# --- Case L: import failure logged from a DEV checkout's mcp/ while running the cache root ---
BDL="$TMP/l"; mkdir -p "$BDL"; mkidx "$BDL/episodic-index.json" 5 0
errrow "$(iso_ago 600)" embeddings \
  "transformers model load failed: Cannot find package '@huggingface/transformers' imported from C:${BS}dev${BS}claude-code-plugin${BS}mcp${BS}dist${BS}server.bundle.js" \
  > "$BDL/error-log.jsonl"
out=$(run BRAIN_DIR="$BDL" CLAUDE_PLUGIN_ROOT="$CRV")
echo "$out" | grep -qiE "degraded|fired=1" \
  && { echo "FAIL L: a dev checkout's import failure fired for the cache root:"; echo "$out"; exit 1; }
mkdir -p "$TMP/claude-code-plugin/mcp/node_modules/@huggingface/transformers"   # dir present
out=$(run BRAIN_DIR="$BDL" CLAUDE_PLUGIN_ROOT="$TMP/claude-code-plugin")
echo "$out" | grep -q "fired=1 reason=import-failure" \
  || { echo "FAIL L: the dev checkout's own import failure did not fire for that root:"; echo "$out"; exit 1; }
echo "PASS L: import failures count only for the plugin root that logged them"

# --- Case K: deps absent (trigger 1) also names wiki bm25-only and logs its emission ---
out=$(run BRAIN_DIR="$BD" CLAUDE_PLUGIN_ROOT="$CRA")
echo "$out" | grep -q "bm25-only" \
  || { echo "FAIL K: deps-absent banner does not cover wiki bm25-only:"; echo "$out"; exit 1; }
echo "$out" | grep -q "gate=banner name=episodic-embed-pending-banner fired=1 reason=deps-absent" \
  || { echo "FAIL K: deps-absent emission not logged:"; echo "$out"; exit 1; }
echo "PASS K: deps-absent banner covers wiki bm25-only and logs gate=banner"

echo "ALL PASS"
