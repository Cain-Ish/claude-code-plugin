#!/usr/bin/env bash
# R7 liveness/dormancy gate (deep-dive: several audit findings were ONE
# missing check): scripts/liveness-check.sh reports, per value artifact,
# whether the shipped thing is actually DEPLOYED and PRODUCING on this box —
# "shipped but not deployed" (marketplace vs installed_plugins.json),
# "indexer behind" (episodic index older than newest transcript), dangling
# embeddings symlink.
# Advisory by default (exit 0); --strict exits 1 when any non-OK line exists.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$REPO_ROOT/scripts/liveness-check.sh"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$SCRIPT" ] || fail "scripts/liveness-check.sh does not exist"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
export BRAIN_DIR="$SANDBOX/brain"
mkdir -p "$BRAIN_DIR/transcripts" "$HOME"

# Fixture: marketplace ships TWO plugins so the every-entry iteration is
# exercised (checking only .plugins[0] was a past bug class).
MP="$SANDBOX/marketplace.json"
cat > "$MP" <<'EOF'
{"plugins":[{"name":"second-brain","version":"0.24.46","source":"./"},{"name":"side-plugin","version":"0.2.0","source":"./side-plugin"}]}
EOF
# Fixture: installed state — second-brain current, side-plugin MISSING entirely
IPJ="$SANDBOX/installed_plugins.json"
cat > "$IPJ" <<'EOF'
{"version":2,"plugins":{"second-brain@second-brain":[{"scope":"user","version":"0.24.46","installPath":"/x"}]}}
EOF

run_lc() { SB_LIVENESS_MARKETPLACE="$MP" SB_LIVENESS_INSTALLED="$IPJ" bash "$SCRIPT" "$@" 2>&1; }

# --- (a) missing plugin → "shipped but not deployed"; advisory exit 0 -------
OUT=$(run_lc); rc=$?
[ "$rc" -eq 0 ] || fail "(a) advisory mode must exit 0 (got $rc)"
echo "$OUT" | grep -qi 'side-plugin' || fail "(a) missing side-plugin not reported: $OUT"
echo "$OUT" | grep -qi 'not deployed\|not installed' || fail "(a) expected a not-deployed line: $OUT"
pass "(a) shipped-but-not-deployed surfaces (advisory rc=0)"

# --- (b) version drift → reported; --strict exits 1 -------------------------
cat > "$IPJ" <<'EOF'
{"version":2,"plugins":{"second-brain@second-brain":[{"scope":"user","version":"0.24.40","installPath":"/x"}],"side-plugin@second-brain":[{"scope":"user","version":"0.2.0","installPath":"/y"}]}}
EOF
OUT=$(run_lc --strict); rc=$?
echo "$OUT" | grep -q '0.24.40' || fail "(b) installed-version drift not reported: $OUT"
echo "$OUT" | grep -q '0.24.46' || fail "(b) shipped version missing from drift line: $OUT"
[ "$rc" -ne 0 ] || fail "(b) version drift must fail --strict"
pass "(b) installed-vs-shipped version drift surfaces + fails --strict"

# --- (c) all current → OK lines; --strict exits 0 ---------------------------
cat > "$IPJ" <<'EOF'
{"version":2,"plugins":{"second-brain@second-brain":[{"scope":"user","version":"0.24.46","installPath":"/x"}],"side-plugin@second-brain":[{"scope":"user","version":"0.2.0","installPath":"/y"}]}}
EOF
# episodic index newer than transcripts
printf 's\n' > "$BRAIN_DIR/transcripts/t1.txt"
printf '{"version":1,"exchanges":[]}\n' > "$BRAIN_DIR/episodic-index.json"
OUT=$(run_lc --strict); rc=$?
[ "$rc" -eq 0 ] || fail "(c) all-healthy --strict should exit 0, got $rc: $OUT"
pass "(c) healthy box passes --strict"

# --- (d) indexer behind: transcript newer than index ------------------------
touch -t 202601010000 "$BRAIN_DIR/episodic-index.json"
printf 'new\n' > "$BRAIN_DIR/transcripts/t2.txt"
OUT=$(run_lc)
echo "$OUT" | grep -qi 'behind\|index' || fail "(d) indexer-behind not reported: $OUT"
pass "(d) episodic indexer-behind surfaces"

echo "ALL PASS"
