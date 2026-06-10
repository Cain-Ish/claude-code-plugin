#!/bin/bash
# tests/test-lib-extract-budget.sh — R1.2 input cap: sb_extract_transcript must
# feed the extractor at most SB_EXTRACT_MAX_BYTES of archive body, keeping the
# NEWEST exchanges (tail). Uncapped multi-MB archives could never finish before
# the timeout and burned full retry cycles toward quarantine (HOOK-4).
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
cat > "$PROBE_IN"
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

[ -f "$PROBE_IN" ] || fail "extractor never invoked"
BYTES=$(wc -c < "$PROBE_IN" | tr -d ' ')
# stdin = PROJECT.md scaffold + separator + capped body (200000) — generous slack:
[ "$BYTES" -lt 230000 ] || fail "extractor stdin is $BYTES bytes — cap not applied"
grep -q 'TAIL-SENTINEL' "$PROBE_IN" || fail "newest content (tail) missing from capped input"
grep -q 'HEAD-SENTINEL' "$PROBE_IN" && fail "oldest content survived the cap (should be tail-capped)"
echo "PASS: extractor input capped to newest ~200KB"
echo "ALL PASS"
