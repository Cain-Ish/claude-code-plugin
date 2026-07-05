#!/bin/bash
# Tests for transcript archive functions in lib.sh.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

setup() {
  local name="$1"
  rm -rf "$TMP/$name"
  mkdir -p "$TMP/$name/.second-brain/transcripts"
  export HOME="$TMP/$name"
  export BRAIN_DIR="$HOME/.second-brain"
  source "$REPO_ROOT/scripts/lib.sh"
}

# Create a fake JSONL transcript with tool_use entries
make_transcript() {
  local path="$1" lines="${2:-10}"
  for i in $(seq 1 "$lines"); do
    if [ $((i % 3)) -eq 0 ]; then
      printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"test.ts"}}]}}\n'
    elif [ $((i % 2)) -eq 0 ]; then
      printf '{"type":"assistant","message":{"content":[{"type":"text","text":"response %d"}]}}\n' "$i"
    else
      printf '{"type":"user","message":{"content":"question %d"}}\n' "$i"
    fi
  done > "$path"
}

# --- Subtest 1: basic archive creates file with metadata header
setup "basic"
TRANSCRIPT="$TMP/basic/transcript.jsonl"
make_transcript "$TRANSCRIPT" 20
sb_archive_transcript "$TRANSCRIPT" "test-proj" "sess_001" 1 20 5
ARCHIVE=$(ls "$BRAIN_DIR/transcripts/" 2>/dev/null | head -1)
[ -n "$ARCHIVE" ] || fail "archive file not created"
grep -q "session_id: sess_001" "$BRAIN_DIR/transcripts/$ARCHIVE" || fail "metadata header missing session_id"
grep -q "project_slug: test-proj" "$BRAIN_DIR/transcripts/$ARCHIVE" || fail "metadata header missing slug"
grep -q "tool_count: 5" "$BRAIN_DIR/transcripts/$ARCHIVE" || fail "metadata header missing tool_count"
grep -q "USER:\|ASSISTANT:" "$BRAIN_DIR/transcripts/$ARCHIVE" || fail "preprocessed content missing"
pass "basic archive: creates file with header and content"

# --- Subtest 2: dedup — same session_id doesn't create duplicate, appends instead
setup "dedup"
TRANSCRIPT="$TMP/dedup/transcript.jsonl"
make_transcript "$TRANSCRIPT" 30
sb_archive_transcript "$TRANSCRIPT" "test-proj" "sess_002" 1 15 3
COUNT_BEFORE=$(ls "$BRAIN_DIR/transcripts/" | wc -l | tr -d ' ')
sb_archive_transcript "$TRANSCRIPT" "test-proj" "sess_002" 16 30 2
COUNT_AFTER=$(ls "$BRAIN_DIR/transcripts/" | wc -l | tr -d ' ')
[ "$COUNT_BEFORE" -eq "$COUNT_AFTER" ] || fail "second call created duplicate file ($COUNT_BEFORE -> $COUNT_AFTER)"
# Content should be appended (file larger after second call)
ARCHIVE=$(ls "$BRAIN_DIR/transcripts/" | head -1)
LINE_COUNT=$(wc -l < "$BRAIN_DIR/transcripts/$ARCHIVE" | tr -d ' ')
[ "$LINE_COUNT" -gt 10 ] || fail "second call should have appended content (got $LINE_COUNT lines)"
pass "dedup: same session appends, no duplicate file"

# --- Subtest 3: pruning enforces 100-file cap
setup "prune-count"
for i in $(seq 1 105); do
  printf "test content %d\n" "$i" > "$BRAIN_DIR/transcripts/sess_$(printf '%03d' "$i")_proj_2026-05-01.txt"
done
sb_prune_transcripts
COUNT=$(ls "$BRAIN_DIR/transcripts/" | wc -l | tr -d ' ')
[ "$COUNT" -le 100 ] || fail "pruning should enforce 100-file cap (got $COUNT)"
pass "prune: enforces 100-file cap"

# --- Subtest 4: pruning enforces 5MB cap
setup "prune-size"
for i in $(seq 1 10); do
  dd if=/dev/zero bs=1024 count=600 2>/dev/null | tr '\0' 'x' > "$BRAIN_DIR/transcripts/sess_$(printf '%03d' "$i")_proj_2026-05-01.txt"
done
BEFORE_SIZE=$(du -sk "$BRAIN_DIR/transcripts" | cut -f1)
sb_prune_transcripts
AFTER_SIZE=$(find "$BRAIN_DIR/transcripts" -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
[ "$AFTER_SIZE" -le 5242880 ] || fail "pruning should enforce 5MB cap (got $AFTER_SIZE bytes)"
pass "prune: enforces 5MB cap"

# --- Subtest 5: prune drops the MTIME-oldest, not the filename-lexical-oldest.
# Regression lock for the UUID-leading-filename bug: archives are named
# "${uuid}_${slug}_${date}.txt", so a lexical sort is age-random and could evict
# a freshly-archived, not-yet-drained transcript. Build the adversarial case:
# the genuinely-oldest file sorts LAST by filename (ffff… prefix), and 100 newer
# files sort FIRST (0000… prefixes). A correct (mtime) prune drops the ffff… one.
setup "prune-mtime-order"
D="$BRAIN_DIR/transcripts"
for i in $(seq 1 100); do
  printf 'recent %d\n' "$i" > "$D/00000000-newer-$(printf '%03d' "$i")_proj_2026-07-02.txt"
done
OLD="$D/ffffffff-oldest_proj_2026-01-01.txt"
printf 'OLD — should prune first\n' > "$OLD"
# Make OLD genuinely the oldest by mtime (POSIX `touch -t CCYYMMDDhhmm`, GNU+BSD).
touch -t 202601010000 "$OLD" 2>/dev/null || fail "touch -t unavailable — cannot set mtime for test"
sb_prune_transcripts
[ ! -f "$OLD" ] \
  || fail "prune dropped by FILENAME order: the mtime-oldest (ffff… prefix) survived"
[ -f "$D/00000000-newer-001_proj_2026-07-02.txt" ] \
  || fail "prune wrongly dropped a newer file (0000… prefix) before the mtime-oldest"
REMAIN=$(ls "$D" | wc -l | tr -d ' ')
[ "$REMAIN" -le 100 ] || fail "prune did not reach the 100-file cap (got $REMAIN)"
pass "prune: drops mtime-oldest, not filename-lexical-oldest (UUID-leading bug)"

echo "ALL PASS"
