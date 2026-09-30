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

# --- Case E: no index file (fresh install) + deps absent -> STILL FIRES (review fix) ---
# T9/L1 group: (1) deps-absent used to be nested under `[ -f episodic-index.json ]`, so a
# totally fresh install (zero transcripts, deps broken by the SAME cache refresh) stayed
# silent even though the identical broken dep also drops wiki knowledge_search to bm25-only
# from the very first session — a real, present-tense degradation that has nothing to do with
# whether any episodic transcript has ever been captured. Un-nested: this must fire regardless.
BDE="$TMP/e"; mkdir -p "$BDE"   # no episodic-index.json
out=$(run BRAIN_DIR="$BDE" CLAUDE_PLUGIN_ROOT="$CRA")
echo "$out" | grep -q "not linked in this plugin cache" \
  || { echo "FAIL E: deps-absent banner did not fire on a fresh install with no index (the un-nest regression):"; echo "$out"; exit 1; }
echo "$out" | grep -q "bm25-only" \
  || { echo "FAIL E: fresh-install deps-absent banner does not cover wiki bm25-only:"; echo "$out"; exit 1; }
echo "PASS E: deps-absent fires on a fresh install with no episodic-index.json (un-nested)"

# --- Case E2: no index file + deps PRESENT -> genuinely healthy fresh install stays silent ---
CRE2="$TMP/cacheE2"; mkdir -p "$CRE2/mcp/node_modules/@huggingface/transformers"
BDE2="$TMP/e2"; mkdir -p "$BDE2"   # no episodic-index.json
: > "$BDE2/error-log.jsonl"
out=$(run BRAIN_DIR="$BDE2" CLAUDE_PLUGIN_ROOT="$CRE2")
echo "$out" | grep -qi "degraded" \
  && { echo "FAIL E2: nagged a genuinely healthy fresh install (no index, deps present, no import failures):"; echo "$out"; exit 1; }
echo "PASS E2: fresh install with healthy deps and no index stays silent"

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

# --- T9: POSIX-path (macOS/Linux) import-failure fixtures ---------------------------------
# Cases F/I/L above only ever exercise the Windows-backslash path shape embeddings.ts logs on
# that platform. The awk match in session-load.sh also has a forward-slash branch
# (`index($0, "/mcp/")` / `"/" root "/mcp/"`) that was never exercised by a fixture.
posixpath() {   # posixpath <version> <tail...> -> a POSIX plugin-cache path, as embeddings.ts
                # logs it on macOS/Linux.
  local out p
  out="/Users/u/.claude/plugins/cache/second-brain/second-brain/$1"
  shift; for p in "$@"; do out="$out/$p"; done; printf '%s' "$out"
}
import_msg_posix() {
  printf "transformers model load failed: Cannot find package '%s' imported from %s — run: bash \$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh" \
    "$(posixpath "$1" mcp node_modules @huggingface transformers index.js)" \
    "$(posixpath "$1" mcp dist tools context-serve-cli.bundle.js)"
}

# --- Case M: POSIX-path import failure naming THIS plugin version -> FIRE ---
BDM="$TMP/m"; mkdir -p "$BDM"; mkidx "$BDM/episodic-index.json" 5 0
errrow "$(iso_ago 3600)" embeddings "$(import_msg_posix 0.54.0)" > "$BDM/error-log.jsonl"
out=$(run BRAIN_DIR="$BDM" CLAUDE_PLUGIN_ROOT="$CRV")
echo "$out" | grep -q "fired=1 reason=import-failure" \
  || { echo "FAIL M: a POSIX-path import failure for THIS version did not fire:"; echo "$out"; exit 1; }
echo "PASS M: POSIX-path import failure fires for the matching plugin version"

# --- Case N: POSIX-path import failure naming a DIFFERENT plugin version -> stays silent ---
BDN="$TMP/n"; mkdir -p "$BDN"; mkidx "$BDN/episodic-index.json" 5 0
errrow "$(iso_ago 3600)" embeddings "$(import_msg_posix 0.53.0)" > "$BDN/error-log.jsonl"
out=$(run BRAIN_DIR="$BDN" CLAUDE_PLUGIN_ROOT="$CRV")
echo "$out" | grep -qiE "degraded|fired=1" \
  && { echo "FAIL N: a POSIX-path import failure for ANOTHER version fired:"; echo "$out"; exit 1; }
echo "PASS N: POSIX-path import failure for another version does not fire"

# --- fired=0 skipped=byte-budget: sb_append refusing the banner must still log loudly --------
run_failappend() {
  local rf="$TMP/runner-failappend.sh"
  cat > "$rf" <<'RUNEOF'
sb_append() { return 1; }
sb_log_error() { printf 'LOG %s ec=%s\n' "$2" "${3:-1}"; }
RUNEOF
  printf '%s\n' "$BLOCK" >> "$rf"
  env -i HOME="$HOME" PATH="$PATH" "$@" bash "$rf"
}
# --- Case O: sb_append fails (byte-budget exhausted) -> fired=0 ... skipped=byte-budget, logged ---
out=$(run_failappend BRAIN_DIR="$BD" CLAUDE_PLUGIN_ROOT="$CRA")
echo "$out" | grep -q "gate=banner name=episodic-embed-pending-banner fired=0 reason=deps-absent skipped=byte-budget" \
  || { echo "FAIL O: a failing sb_append (byte-budget) did not log fired=0 ... skipped=byte-budget:"; echo "$out"; exit 1; }
echo "PASS O: sb_append refusal (byte-budget) logs fired=0 skipped=byte-budget"

# --- silent-failure fix: an awk failure counting import rows must LOG, not silently read 0 --
run_awkfail() {
  local shim="$TMP/awkfail-shim"; mkdir -p "$shim"
  cat > "$shim/awk" <<'AWKSHIMEOF'
#!/bin/bash
echo "awk shim: forced failure" >&2
exit 2
AWKSHIMEOF
  chmod +x "$shim/awk"
  env -i HOME="$HOME" PATH="$shim:$PATH" "$@" bash "$TMP/runner.sh"
}
# --- Case P: the import-failure awk process fails -> logged loudly, banner stays silent -----
BDP="$TMP/p"; mkdir -p "$BDP"; mkidx "$BDP/episodic-index.json" 5 0
errrow "$(iso_ago 3600)" embeddings "$(import_msg 0.54.0)" > "$BDP/error-log.jsonl"
out=$(run_awkfail BRAIN_DIR="$BDP" CLAUDE_PLUGIN_ROOT="$CRV")
echo "$out" | grep -q "import-failure awk failed" \
  || { echo "FAIL P: an awk failure counting import failures was not logged:"; echo "$out"; exit 1; }
echo "$out" | grep -qi "degraded" \
  && { echo "FAIL P: an awk failure silently produced a banner instead of staying silent+logged:"; echo "$out"; exit 1; }
echo "PASS P: an awk failure while counting import failures is logged loudly (not silently 0)"

# --- L1 (review): `grep -q $'\r'` is a Git-Bash text-mode no-op (GNU grep 3.0 opens the file
# already CR-stripped, so the pattern never sees the byte) -- every CR sniff in session-load.sh
# must use `-U` (BSD and GNU both accept it). Static scan locks the fix so a future edit can't
# reintroduce the unsafe form; behavioral check proves -U actually sees the CR this box's plain
# `grep -q` misses.
CR_PAT='grep -q $'\''\r'\'''
if grep -Fq "$CR_PAT" "$SOURCE"; then
  echo "FAIL L1-static: session-load.sh still has an un-U'd CR sniff ($CR_PAT):"
  grep -Fn "$CR_PAT" "$SOURCE"
  exit 1
fi
echo "PASS L1-static: no un-U'd grep -q \$'\r' CR sniff remains in session-load.sh"

CRLF_FIXTURE="$TMP/crlf-fixture.txt"
printf 'a\r\nb\r\n' > "$CRLF_FIXTURE"
if LC_ALL=C grep -q $'\r' "$CRLF_FIXTURE" >/dev/null 2>&1; then
  echo "NOTE L1-behavioral: this box's plain grep -q already sees the CR directly -- -U is still required for a Git-Bash grep build that DOES text-translate, per review."
else
  echo "PASS L1-behavioral: confirmed -- plain grep -q (no -U) misses the CR on this box's Git-Bash (the exact regression -U fixes)"
fi
LC_ALL=C grep -qU $'\r' "$CRLF_FIXTURE" \
  || { echo "FAIL L1-behavioral: grep -qU failed to detect a real CR byte in a CRLF fixture"; exit 1; }
echo "PASS L1-behavioral: grep -qU correctly detects a real CRLF fixture"

# --- G7b: the jq-missing banner (block 0c2, between 0c and 0d) --------------------------------
# Every PreToolUse guard parses its rules and the tool payload with jq and falls back to weaker
# checks without it -- silently, so a box that lost jq runs a thinner safety layer and nothing
# says so. Same harness as above: extract the block, stub sb_append/sb_log_error, and simulate
# "no jq" with a PATH that holds nothing (the block only runs `command -v jq`; bash is invoked by
# absolute path). Lives in this file, not its own, because a new test file costs one surface-budget
# slot (.claude-plugin/surface-budget.json) for what is another banner-block case.
JQBLOCK=$(awk '
  /^# 0c2\./ {p=1}
  p && /^# 0d\./ {exit}
  p {print}
' "$SOURCE")
[ -n "$JQBLOCK" ] || { echo "FAIL G7b: could not extract block 0c2 (the jq-missing banner) from session-load.sh"; exit 1; }
mkdir -p "$TMP/nopath"
cat > "$TMP/jq-runner.sh" <<'EOF'
sb_append() { printf '[%s]\n%s\n' "$2" "$1"; }
sb_log_error() { printf 'LOG %s ec=%s\n' "$2" "${3:-1}"; }
EOF
printf '%s\n' "$JQBLOCK" >> "$TMP/jq-runner.sh"
BASH_BIN=$(command -v bash)
command -v jq >/dev/null 2>&1 || { echo "FAIL G7b: this test needs jq on PATH for its own 'jq present' case"; exit 1; }

out=$(env -i HOME="$HOME" PATH="$TMP/nopath" "$BASH_BIN" "$TMP/jq-runner.sh")
n=$(printf '%s\n' "$out" | grep -c '^\[jq-missing-banner\]$' || true)
[ "$n" = "1" ] || { echo "FAIL G7b-A: expected exactly one jq-missing banner, got $n:"; echo "$out"; exit 1; }
echo "$out" | grep -q 'jq' && echo "$out" | grep -q 'PreToolUse' && echo "$out" | grep -qi 'weaker' \
  || { echo "FAIL G7b-A: banner must name jq, the PreToolUse guards and the weaker fallback:"; echo "$out"; exit 1; }
echo "$out" | grep -q 'LOG gate=banner name=jq-missing-banner fired=1 .*ec=0' \
  || { echo "FAIL G7b-A: the emission must leave a gate=banner fired=1 audit row:"; echo "$out"; exit 1; }
lines=$(printf '%s\n' "$out" | awk '/^\[jq-missing-banner\]$/ {f=1; next} /^LOG / {f=0} f && NF {c++} END {print c+0}')
[ "$lines" = "1" ] || { echo "FAIL G7b-A: the banner must be ONE short line, got $lines non-empty lines:"; echo "$out"; exit 1; }
echo "PASS G7b-A: no jq on PATH -> one visible banner + a gate=banner audit row"

out=$(env -i HOME="$HOME" PATH="$PATH" "$BASH_BIN" "$TMP/jq-runner.sh")
[ -z "$out" ] || { echo "FAIL G7b-B: banner fired although jq is on PATH:"; echo "$out"; exit 1; }
echo "PASS G7b-B: jq on PATH -> silent"

cat > "$TMP/jq-runner-full.sh" <<'EOF'
sb_append() { return 1; }
sb_log_error() { printf 'LOG %s ec=%s\n' "$2" "${3:-1}"; }
EOF
printf '%s\n' "$JQBLOCK" >> "$TMP/jq-runner-full.sh"
out=$(env -i HOME="$HOME" PATH="$TMP/nopath" "$BASH_BIN" "$TMP/jq-runner-full.sh")
echo "$out" | grep -q 'fired=0 .*skipped=byte-budget' \
  || { echo "FAIL G7b-C: a budget-refused banner must log fired=0 skipped=byte-budget:"; echo "$out"; exit 1; }
echo "PASS G7b-C: budget-refused banner is logged (fired=0), never silent"

echo "ALL PASS"
