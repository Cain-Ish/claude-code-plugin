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
# Fixture marks the transcripts EXTRACTED (2026-08-20): the cap is now extracted-first, so the
# 100-file ceiling applies to files whose knowledge is already in the wiki. This is the steady
# state the cap was written for — the drainer keeping up. An all-un-mined archive is the
# drainer-stalled state and is deliberately allowed past the soft cap; subtests 6 and 7 cover
# that side (it stays bounded by the hard cap, and eviction is logged).
setup "prune-count"
for i in $(seq 1 105); do
  f="$BRAIN_DIR/transcripts/sess_$(printf '%03d' "$i")_proj_2026-05-01.txt"
  printf "test content %d\n" "$i" > "$f"
  printf '{"basename":"%s","ts":"2026-05-01T00:00:00Z","outcome":"ok"}\n' "$(basename "$f")" \
    >> "$BRAIN_DIR/.extraction-state.jsonl"
done
sb_prune_transcripts
COUNT=$(ls "$BRAIN_DIR/transcripts/" | wc -l | tr -d ' ')
[ "$COUNT" -le 100 ] || fail "pruning should enforce 100-file cap (got $COUNT)"
pass "prune: enforces 100-file cap"

# --- Subtest 4: pruning enforces 5MB cap
# Fixture marks the transcripts EXTRACTED (2026-08-20), for the same reason as subtests 3 and 5:
# byte eviction is now two-tier as well, so an all-un-mined archive is protected up to the HARD
# byte ceiling and this soft-cap assertion would no longer be exercised. Subtests 8 and 9 cover
# the un-mined side of the byte cap.
setup "prune-size"
for i in $(seq 1 10); do
  f="$BRAIN_DIR/transcripts/sess_$(printf '%03d' "$i")_proj_2026-05-01.txt"
  dd if=/dev/zero bs=1024 count=600 2>/dev/null | tr '\0' 'x' > "$f"
  printf '{"basename":"%s","ts":"2026-05-01T00:00:00Z","outcome":"ok"}\n' "$(basename "$f")" \
    >> "$BRAIN_DIR/.extraction-state.jsonl"
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
# Fixture marks every file EXTRACTED (2026-08-20): eviction is extracted-first, so the
# mtime-vs-lexical question this test exists for is now decided WITHIN the extracted class.
# An all-un-mined archive is not pruned at the soft cap at all — subtests 6/7 cover that side.
mark_done() {
  printf '{"basename":"%s","ts":"2026-07-02T00:00:00Z","outcome":"ok"}\n' "$(basename "$1")" \
    >> "$BRAIN_DIR/.extraction-state.jsonl"
}
for i in $(seq 1 100); do
  f="$D/00000000-newer-$(printf '%03d' "$i")_proj_2026-07-02.txt"
  printf 'recent %d\n' "$i" > "$f"; mark_done "$f"
done
OLD="$D/ffffffff-oldest_proj_2026-01-01.txt"
printf 'OLD — should prune first\n' > "$OLD"; mark_done "$OLD"
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


# --- Subtest 6: the cap evicts EXTRACTED transcripts before un-mined ones.
# Regression lock for the silent-data-loss bug (2026-08-20): the cap deleted strictly
# oldest-first, so on a machine where the drainer defers (pure OAuth + an always-on
# interactive session) every new session destroyed one never-extracted transcript.
# Measured live at 100/100 archived, 28 never extracted, oldest 27 days. The archive's
# contract ("the drainer mines the real knowledge later") cannot hold if the cap
# outruns the drainer. Adversarial shape: the un-mined file is the OLDEST, so a
# correct prune must skip it and take a newer, already-extracted one instead.
setup "prune-prefers-extracted"
D="$BRAIN_DIR/transcripts"
UNMINED="$D/aaaaaaaa-unmined_proj_2026-01-01.txt"
printf 'never extracted — must survive\n' > "$UNMINED"
touch -t 202601010000 "$UNMINED"  || fail "touch -t unavailable"
for i in $(seq 1 100); do
  f="$D/bbbbbbbb-done-$(printf '%03d' "$i")_proj_2026-07-02.txt"
  printf 'extracted %d\n' "$i" > "$f"
  printf '{"basename":"%s","ts":"2026-07-02T00:00:00Z","outcome":"ok"}\n' "$(basename "$f")" \
    >> "$BRAIN_DIR/.extraction-state.jsonl"
done
sb_prune_transcripts
[ -f "$UNMINED" ] || fail "cap evicted the UN-EXTRACTED transcript while extracted ones remained"
COUNT=$(ls "$D" | wc -l | tr -d ' ')
[ "$COUNT" -le 100 ] || fail "cap not enforced after extracted-first eviction (got $COUNT)"
pass "prune: evicts extracted transcripts before un-mined ones"

# --- Subtest 7: un-mined backlog is still BOUNDED — past the hard ceiling it is
# evicted, and loudly (fail-loud: knowledge destroyed before it was read must never
# be a silent no-op). Small caps keep the fixture fast.
setup "prune-unmined-hard-cap"
D="$BRAIN_DIR/transcripts"
for i in $(seq 1 12); do
  printf 'unmined %d\n' "$i" > "$D/cccccccc-unmined-$(printf '%03d' "$i")_proj_2026-07-02.txt"
done
SB_TRANSCRIPT_CAP=2 SB_TRANSCRIPT_HARD_CAP=5 sb_prune_transcripts
COUNT=$(ls "$D" | wc -l | tr -d ' ')
[ "$COUNT" -le 5 ] || fail "un-mined backlog exceeded the hard cap (got $COUNT, expected <= 5)"
[ "$COUNT" -gt 2 ] || fail "un-mined evicted down to the SOFT cap — hard ceiling not honoured (got $COUNT)"
grep -q "UN-EXTRACTED" "$BRAIN_DIR/error-log.jsonl"  \
  || fail "evicting un-mined transcripts was SILENT — no error-log entry"
pass "prune: un-mined stays bounded by the hard cap, and eviction is logged loudly"

# --- Subtest 8: the BYTE cap also evicts extracted before un-mined.
# The count cap got subtests 6/7 because a real incident demanded them; review found the byte
# cap had the same design with NO lock, and transcripts are large enough that the byte ceiling
# is normally the one that fires first — so protecting only the count path was protection in
# name. Adversarial shape: the un-mined file is oldest AND large, so a naive oldest-first byte
# eviction takes it; a correct one takes the extracted files instead.
setup "prune-bytes-prefers-extracted"
D="$BRAIN_DIR/transcripts"
UNMINED="$D/aaaaaaaa-unmined_proj_2026-01-01.txt"
dd if=/dev/zero bs=1024 count=600  | tr '\0' 'x' > "$UNMINED"
touch -t 202601010000 "$UNMINED"  || fail "touch -t unavailable"
for i in $(seq 1 9); do
  f="$D/bbbbbbbb-done-$(printf '%03d' "$i")_proj_2026-07-02.txt"
  dd if=/dev/zero bs=1024 count=600  | tr '\0' 'x' > "$f"
  printf '{"basename":"%s","ts":"2026-07-02T00:00:00Z","outcome":"ok"}\n' "$(basename "$f")" \
    >> "$BRAIN_DIR/.extraction-state.jsonl"
done
sb_prune_transcripts
[ -f "$UNMINED" ] || fail "byte cap evicted the UN-EXTRACTED transcript while extracted ones remained"
AFTER=$(find "$D" -type f -exec cat {} +  | wc -c | tr -d ' ')
[ "$AFTER" -le 5242880 ] || fail "byte cap not enforced via extracted eviction (got $AFTER)"
pass "prune: byte cap evicts extracted before un-mined"

# --- Subtest 9: un-mined bytes are still BOUNDED by the hard ceiling, and evicting them is loud.
setup "prune-bytes-hard-ceiling"
D="$BRAIN_DIR/transcripts"
for i in $(seq 1 6); do
  dd if=/dev/zero bs=1024 count=600  | tr '\0' 'x' > "$D/cccccccc-unmined-$(printf '%03d' "$i")_proj_2026-07-02.txt"
done
# 6 x 600KB = ~3.6MB. Soft ceiling 1MB, hard 2MB: un-mined must survive the soft cap but be
# trimmed to the hard one — never below it, and never silently.
SB_TRANSCRIPT_MAX_BYTES=1048576 SB_TRANSCRIPT_MAX_BYTES_HARD=2097152 sb_prune_transcripts
AFTER=$(find "$D" -type f -exec cat {} +  | wc -c | tr -d ' ')
[ "$AFTER" -le 2097152 ] || fail "un-mined bytes exceeded the hard ceiling (got $AFTER)"
[ "$AFTER" -gt 1048576 ] || fail "un-mined trimmed to the SOFT byte cap — hard ceiling not honoured (got $AFTER)"
grep -q "UN-EXTRACTED" "$BRAIN_DIR/error-log.jsonl"  \
  || fail "byte-cap eviction of un-mined transcripts was SILENT — no error-log entry"
pass "prune: un-mined bytes bounded by the hard ceiling, eviction logged loudly"

echo "ALL PASS"
