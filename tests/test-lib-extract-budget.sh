#!/bin/bash
# tests/test-lib-extract-budget.sh — R1.2 input cap: sb_extract_transcript must
# feed the extractor at most SB_EXTRACT_MAX_BYTES of archive body per call.
# Uncapped multi-MB archives could never finish before the timeout and burned
# full retry cycles toward quarantine (HOOK-4).
# R2 (0.56.0): the cap is met by CHUNKING FORWARD, not by a tail cap — the old
# `tail -c` silently dropped the oldest part of every big archive. Every line
# reaches the extractor, oldest chunk first.
set -u
unset CLAUDECODE 2>/dev/null || true
unset ANTHROPIC_API_KEY 2>/dev/null || true
unset SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"
export BRAIN_DIR="$SANDBOX/brain"; mkdir -p "$BRAIN_DIR/transcripts"
fail() { echo "FAIL: $1"; exit 1; }

export PROBE_IN="$SANDBOX/stdin-capture"
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/claude" <<'EOF'
#!/bin/bash
n=$(( $(cat "$PROBE_IN.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$PROBE_IN.n"
cat > "$PROBE_IN.$n"
echo '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
EOF
chmod +x "$SANDBOX/bin/claude"
export PATH="$SANDBOX/bin:$PATH"

# 300KB body: HEAD-SENTINEL early, TAIL-SENTINEL at the end.
TX="$BRAIN_DIR/transcripts/big_proj_2026-06-10.txt"
{
  printf -- '--- session-meta ---\nsession_id: big\nproject_slug: proj\ndate: 2026-06-10\ntool_count: 5\nline_count: 9\n---\n\n'
  echo "HEAD-SENTINEL"
  i=0; while [ $i -lt 3000 ]; do printf 'ASSISTANT:\n  [Edit] src/file%05d.ts — padding line of roughly one hundred bytes to inflate the archive body\n' "$i"; i=$((i+1)); done
  echo "TAIL-SENTINEL"
} > "$TX"

( source "$REPO_ROOT/scripts/lib.sh"
  sb_extract_transcript "$TX" proj >/dev/null 2>&1 )

N=$(cat "$PROBE_IN.n" 2>/dev/null || echo 0)
[ "$N" -ge 2 ] || fail "a ~300KB body at a 200000-byte cap must take >= 2 extractor calls (got $N)"
i=1
while [ "$i" -le "$N" ]; do
  BYTES=$(wc -c < "$PROBE_IN.$i" | tr -d ' ')
  # stdin = PROJECT.md scaffold + separator + one capped chunk (200000) — generous slack:
  [ "$BYTES" -lt 230000 ] || fail "extractor call $i stdin is $BYTES bytes — cap not applied"
  i=$((i + 1))
done
echo "PASS: every extractor call is capped to ~200KB ($N calls)"
grep -q 'HEAD-SENTINEL' "$PROBE_IN.1" || fail "the first call must carry the OLDEST content (chunked forward)"
grep -q 'TAIL-SENTINEL' "$PROBE_IN.1" && fail "the first call already carries the newest content (not chunked forward)"
grep -q 'TAIL-SENTINEL' "$PROBE_IN.$N" || fail "the last call must carry the newest content"
echo "PASS: chunked forward — oldest content first, nothing dropped"
echo "ALL PASS"
