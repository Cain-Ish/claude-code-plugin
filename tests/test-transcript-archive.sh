#!/bin/bash
# pins: SB_TRANSCRIPT_CAP — lowers the soft cap to a small fixture-sized value so pruning triggers deterministically
# pins: SB_TRANSCRIPT_HARD_CAP — lowers the hard cap to a small fixture-sized value so pruning triggers deterministically
# pins: SB_TRANSCRIPT_MAX_BYTES — lowers the soft byte cap to a small fixture-sized value so pruning triggers deterministically
# pins: SB_TRANSCRIPT_MAX_BYTES_HARD — lowers the hard byte cap to a small fixture-sized value so pruning triggers deterministically
# Tests for transcript archive functions in lib.sh.
# run-all-timeout: 300   (0.56.0 R2 locks the raised default caps with full-size fixtures: 405
#   and 1205 files, 27.5 MB; measured 109 s alone on a loaded MSYS box, of which the pre-existing
#   65,590-byte heredoc-window case is ~34 s — past the 120 s default under any extra load)
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

# --- Subtest 3: pruning enforces the 400-file DEFAULT cap (R2#6, 0.56.0: was 100)
# Fixture marks the transcripts EXTRACTED (2026-08-20): the cap is now extracted-first, so the
# soft ceiling applies to files whose knowledge is already in the wiki. This is the steady
# state the cap was written for — the drainer keeping up. An all-un-mined archive is the
# drainer-stalled state and is deliberately allowed past the soft cap; subtests 6 and 7 cover
# that side (it stays bounded by the hard cap, and eviction is logged). No cap override: this
# locks the default. Builtins only in the fixture loop (printf -v, ${f##*/}): 405 spawns of
# basename/$(printf) cost ~20 s on MSYS.
setup "prune-count"
i=1; while [ "$i" -le 405 ]; do
  printf -v n '%03d' "$i"; f="$BRAIN_DIR/transcripts/sess_${n}_proj_2026-05-01.txt"
  printf "test content %d\n" "$i" > "$f"
  printf '{"basename":"%s","ts":"2026-05-01T00:00:00Z","outcome":"ok"}\n' "${f##*/}" \
    >> "$BRAIN_DIR/.extraction-state.jsonl"
  i=$((i + 1))
done
sb_prune_transcripts
COUNT=$(ls "$BRAIN_DIR/transcripts/" | wc -l | tr -d ' ')
[ "$COUNT" -eq 400 ] || fail "pruning should enforce the 400-file default cap, evicting extracted files down to it (got $COUNT)"
pass "prune: enforces the 400-file default cap"

# --- Subtest 4: pruning enforces the 25 MB DEFAULT byte cap (R2#6, 0.56.0: was 5 MB)
# Fixture marks the transcripts EXTRACTED (2026-08-20), for the same reason as subtests 3 and 5:
# byte eviction is now two-tier as well, so an all-un-mined archive is protected up to the HARD
# byte ceiling and this soft-cap assertion would no longer be exercised. Subtests 8 and 9 cover
# the un-mined side of the byte cap. 11 x 2.5 MB = 27.5 MB: the default must trim to <= 25 MB
# and NOT down to the old 5 MB line.
setup "prune-size"
dd if=/dev/zero bs=1024 count=2560 2>/dev/null | tr '\0' 'x' > "$TMP/prune-size/blob"
i=1; while [ "$i" -le 11 ]; do
  printf -v n '%03d' "$i"; f="$BRAIN_DIR/transcripts/sess_${n}_proj_2026-05-01.txt"
  cat "$TMP/prune-size/blob" > "$f"
  printf '{"basename":"%s","ts":"2026-05-01T00:00:00Z","outcome":"ok"}\n' "${f##*/}" \
    >> "$BRAIN_DIR/.extraction-state.jsonl"
  i=$((i + 1))
done
sb_prune_transcripts
AFTER_SIZE=$(find "$BRAIN_DIR/transcripts" -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
[ "$AFTER_SIZE" -le 26214400 ] || fail "pruning should enforce the 25 MB default byte cap (got $AFTER_SIZE bytes)"
[ "$AFTER_SIZE" -gt 5242880 ] || fail "pruning trimmed to the OLD 5 MB line, not the 25 MB default (got $AFTER_SIZE bytes)"
pass "prune: enforces the 25 MB default byte cap"

# --- Subtest 4b: the un-mined HARD count ceiling defaults to 3x the soft cap (1200), and the
# subagent sub-cap scales with it (200 of 400, was 50 of 100). Empty files, so only the count
# caps can fire. RED on the old defaults (300 / 50).
setup "prune-hard-default"
D="$BRAIN_DIR/transcripts"
i=1; while [ "$i" -le 1205 ]; do printf -v n '%04d' "$i"; : > "$D/dddddddd-unmined-${n}_proj_2026-07-02.txt"; i=$((i + 1)); done
sb_prune_transcripts
COUNT=$(find "$D" -name '*.txt' -type f | wc -l | tr -d ' ')
[ "$COUNT" -eq 1200 ] || fail "the un-mined hard ceiling should default to 1200 (3 x the 400 soft cap), got $COUNT"
grep -q "UN-EXTRACTED" "$BRAIN_DIR/error-log.jsonl" || fail "default hard-cap eviction of un-mined transcripts was silent"
setup "subagent-subcap-default"
D="$BRAIN_DIR/transcripts"
i=1; while [ "$i" -le 205 ]; do printf -v n '%03d' "$i"; printf 'r\n' > "$D/sub-agent${n}_proj_2026-07-02.txt"; i=$((i + 1)); done
sb_archive_subagent_result agentnew general-purpose proj sess 1 "final answer" || fail "subagent archive write failed"
SUBS=$(find "$D" -name 'sub-*.txt' -type f | wc -l | tr -d ' ')
[ "$SUBS" -eq 200 ] || fail "the subagent sub-cap should default to 200 (proportional to the 400 cap), got $SUBS"
pass "prune: hard count ceiling defaults to 1200 and the subagent sub-cap to 200"

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
  # ${1##*/} not $(basename): this fixture ran 325 basename spawns per test — on MSYS that alone
  # was ~15s of a test that must fit a 120s budget. The fixture must not be slower than the code.
  printf '{"basename":"%s","ts":"2026-07-02T00:00:00Z","outcome":"ok"}\n' "${1##*/}" \
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
# The ordering question needs the cap at the fixture size (101 files); the default is 400.
SB_TRANSCRIPT_CAP=100 sb_prune_transcripts
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
SB_TRANSCRIPT_CAP=100 sb_prune_transcripts   # fixture-sized cap (101 files); the default is 400
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
SB_TRANSCRIPT_MAX_BYTES=5242880 sb_prune_transcripts   # fixture-sized byte cap (6 MB); the default is 25 MB
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

# --- Subtest: a file list inside the MSYS heredoc hang window must not hang the prune.
# sb_prune_transcripts fed $files (every archive path, one per line) to its two read loops
# through `<<EOF` heredocs, and an expanded heredoc blocks Git-Bash for good at
# 65,537..~65,650 bytes, exactly like a `<<<` here-string. Empty files, caps lifted, so nothing
# is evicted: the list is sized to 65,590 bytes (path lines + newlines, the heredoc's own
# trailing newline included) by one pad-length name. Watchdog: the backgrounded subshell is the
# blocked writer itself; poll, then KILL, never `wait` on it. RED reproduces on MSYS only.
setup "hdwin"
HD_DIR="$BRAIN_DIR/transcripts"
HD_D=$(( ${#HD_DIR} + 2 ))            # "/" before the name + the newline after it
HD_L=40                               # name length of the bulk files
HD_N=$(( (65590 - HD_D - 20) / (HD_D + HD_L) ))
HD_PAD=$(( 65590 - HD_N * (HD_D + HD_L) - HD_D ))
[ "$HD_PAD" -ge 12 ] && [ "$HD_PAD" -le 200 ] || fail "hd-window fixture: pad name length $HD_PAD out of range (dir ${#HD_DIR} B)"
i=1; while [ "$i" -le "$HD_N" ]; do : > "$HD_DIR/$(printf 'hdw-%0*d.txt' $((HD_L - 8)) "$i")"; i=$((i + 1)); done
: > "$HD_DIR/$(printf 'pad-%0*d.txt' $((HD_PAD - 8)) 0)"
( SB_TRANSCRIPT_CAP=100000 SB_TRANSCRIPT_HARD_CAP=100000 sb_prune_transcripts ) &
HD_WD=$!; i=0
while kill -0 "$HD_WD" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
if kill -0 "$HD_WD" 2>/dev/null; then
  kill -KILL "$HD_WD" 2>/dev/null
  fail "prune hung on a 65,590-byte archive list ($((HD_N + 1)) files; MSYS heredoc window) — killed after 60 s"
fi
wait "$HD_WD"
HD_LEFT=$(find "$HD_DIR" -name '*.txt' -type f | wc -l | tr -d ' ')
[ "$HD_LEFT" -eq $((HD_N + 1)) ] || fail "hd-window prune evicted files under lifted caps: $HD_LEFT of $((HD_N + 1)) left"
pass "prune: a 65,590-byte archive list ($((HD_N + 1)) files) does not hang, and evicts nothing under lifted caps"

# --- Subtest (O4): a listing pass that yields NO rows while the archive is over the cap must
# leave a row. The partition loop reads `< <(printf '%s\n' "$files")`; a process substitution
# that cannot fork (EAGAIN — routine on a loaded Windows box) feeds the loop nothing, so both
# eviction queues stay empty and the cap is silently not enforced. Simulated by shadowing the
# `printf` builtin so ONLY the list-feeding call (the one whose text holds the archive paths)
# fails; sb_log_error's own printf carries no archive path and still runs for real.
setup "nopartition"
NP_DIR="$BRAIN_DIR/transcripts"
for i in 1 2 3 4 5; do : > "$NP_DIR/np-$i.txt"; done
: > "$BRAIN_DIR/error-log.jsonl"
(
  printf() {
    if [ "$1" = '%s\n' ]; then case "${2:-}" in *"/transcripts/"*) return 1 ;; esac; fi
    builtin printf "$@"
  }
  SB_TRANSCRIPT_CAP=2 SB_TRANSCRIPT_HARD_CAP=300 sb_prune_transcripts
)
grep -q 'sb_prune_transcripts' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  || fail "O4: an over-cap archive whose listing pass yielded no rows left no error row (nothing pruned, silently)"
[ "$(find "$NP_DIR" -name '*.txt' -type f | wc -l | tr -d ' ')" -eq 5 ] || fail "O4: files were evicted although the listing pass yielded nothing"
# and a healthy over-cap prune must NOT emit that row
setup "partition-ok"
for i in 1 2 3 4 5; do : > "$BRAIN_DIR/transcripts/ok-$i.txt"; done
SB_TRANSCRIPT_CAP=2 SB_TRANSCRIPT_HARD_CAP=300 sb_prune_transcripts
grep -q 'listing pass' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null && fail "O4: a normal over-cap prune logged the no-rows error"
pass "prune: an over-cap archive with an empty listing pass logs a row; a normal prune stays quiet (O4)"

# === R2 (0.56.0) secret scrub: sb_scrub_secrets, sb_preprocess_transcript, sb_scrub_archive_file ===
# Fixture credentials are assembled at run time, so no credential-shaped literal sits in the repo.
rep() { local s="" k=0; while [ "$k" -lt "$2" ]; do s="$s$1"; k=$((k + 1)); done; printf '%s' "$s"; }
K_ANT="sk-ant-api03-$(rep aB3_ 12)-$(rep Zq9 6)AA"
K_OAI="sk-$(rep aB3 8)"
K_GHP="ghp_$(rep a1B2 9)"
K_GPAT="github_pat_$(rep 11A_b 5)"
K_AWS="AKIA$(rep Q7 8)"
K_SLK="xoxb-$(rep 12 6)-$(rep ab 4)"
K_BEAR="$(rep Zz.9 6)"
PEM_B="-----BEGIN RSA PRIV""ATE KEY-----"; PEM_E="-----END RSA PRIV""ATE KEY-----"
PEM_OB="-----BEGIN OPENSSH PRIV""ATE KEY-----"

setup "scrub"
SD="$TMP/scrub/fx"; mkdir -p "$SD"
# one of every kind, LF
printf '%s\n' "USER: my key is $K_ANT ok" "  export OPENAI_API_KEY=$K_OAI" "  token $K_GHP and $K_GPAT" \
  "aws=$K_AWS;" "slack:$K_SLK" "curl -H \"Authorization: Bearer $K_BEAR\" x" > "$SD/kinds.in"
printf '%s\n' "USER: my key is [redacted:anthropic] ok" "  export OPENAI_API_KEY=[redacted:openai]" \
  "  token [redacted:github] and [redacted:github]" "aws=[redacted:aws];" "slack:[redacted:slack]" \
  "curl -H \"Authorization: [redacted:bearer]\" x" > "$SD/kinds.want"
# CRLF: the \r is kept, including right after a token
printf '%s\r\n' "k=$K_ANT" "  ASSISTANT text $K_AWS" "plain" > "$SD/crlf.in"
printf '%s\r\n' "k=[redacted:anthropic]" "  ASSISTANT text [redacted:aws]" "plain" > "$SD/crlf.want"
# multi-line PEM: the BEGIN line keeps its prefix (a `USER:` line opens an exchange in the episodic
# parser), each body line and the END line become a marker, the END line keeps its tail, a blank
# line inside the block stays blank
printf '%s\n' "USER: deploy with $PEM_B" "MIIEowIBAAKCAQEA$(rep Ab 20)" "$(rep xY 30)+/=" "" "$PEM_E thanks" \
  "ASSISTANT:" "  noted" > "$SD/pem.in"
printf '%s\n' "USER: deploy with [redacted:private-key]" "[redacted:private-key]" "[redacted:private-key]" "" \
  "[redacted:private-key] thanks" "ASSISTANT:" "  noted" > "$SD/pem.want"
# a key cut short (Bash commands are cut at 120 chars, thinking at 100), CRLF: the block ends at the
# first line that is not key material, so it never swallows the rest of the window
printf '%s\r\n' "  (thinking: $PEM_OB" "b3BlbnNzaC1rZXktdjEAAAAA$(rep Qw 10)" "USER: next question" "MIIEow$(rep Ab 10)" > "$SD/pemcut.in"
printf '%s\r\n' "  (thinking: [redacted:private-key]" "[redacted:private-key]" "USER: next question" "MIIEow$(rep Ab 10)" > "$SD/pemcut.want"
# a one-line block (a JSON string with literal \n escapes)
printf '%s\n' "  key=\"$PEM_B\\nMIIE$(rep Ab 10)\\n$PEM_E\" done" > "$SD/pem1.in"
printf '%s\n' "  key=\"[redacted:private-key]\" done" > "$SD/pem1.want"
# adjacent secrets, and an OpenAI key glued to an Anthropic one: the Anthropic form must run
# first, or the generic sk- run stops at "-ant-" and leaves the rest of the key in clear
printf '%s\n' "$K_ANT $K_OAI,$K_GHP;$K_AWS $K_SLK" "$K_OAI$K_ANT" > "$SD/adjacent.in"
printf '%s\n' "[redacted:anthropic] [redacted:openai],[redacted:github];[redacted:aws] [redacted:slack]" \
  "[redacted:openai][redacted:anthropic]" > "$SD/adjacent.want"
# NOT matched, by design: OTP-like short codes, short sk- strings, an sk- run inside a longer
# identifier (task-/disk- ids), a short ghp_, a short Bearer value
printf '%s\n' "your code is 123456" "sk-short1234" "task-$(rep 0a1B 6)" "ghp_tooshort" "Bearer abc" > "$SD/clean.in"
cp "$SD/clean.in" "$SD/clean.want"
# no trailing newline: the last line stays unterminated
printf 'first\nlast %s' "$K_OAI" > "$SD/nonl.in"
printf 'first\nlast [redacted:openai]' > "$SD/nonl.want"
: > "$SD/empty.in"; : > "$SD/empty.want"
for fx in kinds crlf pem pemcut pem1 adjacent clean nonl empty; do
  sb_scrub_secrets < "$SD/$fx.in" > "$SD/$fx.out" || fail "scrub[$fx]: sb_scrub_secrets exited non-zero"
  cmp -s "$SD/$fx.out" "$SD/$fx.want" || fail "scrub[$fx]: output differs from the expected redaction:
$(od -c "$SD/$fx.out" | head -12)"
  [ "$(wc -l < "$SD/$fx.in")" -eq "$(wc -l < "$SD/$fx.out")" ] \
    || fail "scrub[$fx]: line count changed ($(wc -l < "$SD/$fx.in") -> $(wc -l < "$SD/$fx.out")): the archive_line cursor counts lines"
  sb_scrub_secrets < "$SD/$fx.out" > "$SD/$fx.again" && cmp -s "$SD/$fx.again" "$SD/$fx.out" \
    || fail "scrub[$fx]: a second pass changed the output (not idempotent)"
done
pass "scrub: every format redacted to [redacted:<kind>], PEM per line, CRLF kept, line count invariant, idempotent"

# sb_preprocess_transcript runs the scrub on every window it renders (archive AND extractor input)
PJ="$TMP/scrub/pp.jsonl"
{ jq -nc --arg t "please use $K_ANT now" '{type:"user",message:{content:$t}}'
  jq -nc --arg t "$PEM_B
MIIE$(rep Ab 12)
$PEM_E" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
} > "$PJ"
PP=$(sb_preprocess_transcript < "$PJ" | tr -d '\r')
case "$PP" in *sk-ant-*|*MIIE*) fail "preprocess: a credential survived sb_preprocess_transcript: $PP" ;; esac
case "$PP" in *"USER: please use [redacted:anthropic] now"*) ;; *) fail "preprocess: the Anthropic key was not redacted in place: $PP" ;; esac
[ "$(printf '%s\n' "$PP" | grep -cF '[redacted:private-key]')" -eq 3 ] \
  || fail "preprocess: the PEM block was not redacted line by line: $PP"
pass "preprocess: sb_preprocess_transcript output is scrubbed"

# sb_scrub_archive_file: in place, atomic, mtime kept, line count kept, idempotent, loud
setup "scrub-file"
SA="$BRAIN_DIR/transcripts/s1_proj_2026-01-01.txt"
printf -- '--- session-meta ---\nsession_id: s1\n---\n\nUSER: key %s\n%s\nMIIE%s\n%s\nASSISTANT:\n  done %s' \
  "$K_ANT" "$PEM_B" "$(rep Ab 12)" "$PEM_E" "$K_GHP" > "$SA"   # unterminated last line on purpose
touch -t 202601010000 "$SA" || fail "touch -t unavailable"
SA_MT=$(sb_mtime "$SA"); SA_LC=$(wc -l < "$SA")
sb_scrub_archive_file "$SA" || fail "scrub-file: a good scrub returned non-zero"
grep -qE 'sk-ant-|ghp_|MIIE|PRIVATE KEY' "$SA" && fail "scrub-file: a credential survived the in-place scrub"
grep -q '^USER: key \[redacted:anthropic\]$' "$SA" || fail "scrub-file: the Anthropic key was not redacted in place"
[ "$(sb_mtime "$SA")" = "$SA_MT" ] || fail "scrub-file: mtime changed ($SA_MT -> $(sb_mtime "$SA")): the drainer's quiet-1-h rule reads it"
[ "$(wc -l < "$SA")" -eq "$SA_LC" ] || fail "scrub-file: line count changed ($SA_LC -> $(wc -l < "$SA"))"
[ -n "$(tail -c 1 "$SA")" ] || fail "scrub-file: the unterminated last line gained a newline"
[ -z "$(find "$BRAIN_DIR/transcripts" -name '*.part')" ] || fail "scrub-file: a scratch copy was left behind"
cp "$SA" "$TMP/scrub-file/once"
sb_scrub_archive_file "$SA" || fail "scrub-file: a re-run returned non-zero"
cmp -s "$SA" "$TMP/scrub-file/once" || fail "scrub-file: a re-run changed the file (not idempotent)"
[ "$(sb_mtime "$SA")" = "$SA_MT" ] || fail "scrub-file: a re-run touched the mtime"
# a file with nothing to redact is not rewritten (the mtime of a fresh file would move on a rewrite)
SC="$BRAIN_DIR/transcripts/s2_proj_2026-01-01.txt"; printf 'USER: hello\n' > "$SC"; touch -t 202601010000 "$SC"
SC_MT=$(sb_mtime "$SC"); sb_scrub_archive_file "$SC" || fail "scrub-file: a clean file returned non-zero"
[ "$(sb_mtime "$SC")" = "$SC_MT" ] || fail "scrub-file: a clean file was rewritten"
# failure paths: a missing file, a scrub that fails, and a file that grows mid-scrub (Stop hooks
# append without the drain lock) — each is loud, returns non-zero and leaves the original intact
: > "$BRAIN_DIR/error-log.jsonl"
( sb_scrub_archive_file "$BRAIN_DIR/transcripts/absent.txt" ) && fail "scrub-file: a missing file returned 0"
grep -q 'sb_scrub_archive_file' "$BRAIN_DIR/error-log.jsonl" || fail "scrub-file: a missing file was not logged"
SF="$BRAIN_DIR/transcripts/s3_proj_2026-01-01.txt"; printf 'USER: %s\n' "$K_AWS" > "$SF"; cp "$SF" "$TMP/scrub-file/s3.orig"
: > "$BRAIN_DIR/error-log.jsonl"
( awk() { return 3; }; sb_scrub_archive_file "$SF" ) && fail "scrub-file: a failing scrub returned 0"
cmp -s "$SF" "$TMP/scrub-file/s3.orig" || fail "scrub-file: a failing scrub changed the original"
grep -q 'sb_scrub_archive_file' "$BRAIN_DIR/error-log.jsonl" || fail "scrub-file: a failing scrub was not logged"
[ -z "$(find "$BRAIN_DIR/transcripts" -name '*.part')" ] || fail "scrub-file: a failing scrub left its scratch copy"
: > "$BRAIN_DIR/error-log.jsonl"
( eval "$(declare -f sb_scrub_secrets | sed '1s/sb_scrub_secrets/_sb_real_scrub/')"
  sb_scrub_secrets() { _sb_real_scrub; printf 'USER: late append\n' >> "$SF"; }
  sb_scrub_archive_file "$SF" ) && fail "scrub-file: a file that grew mid-scrub was replaced (the append is lost)"
grep -q '^USER: late append$' "$SF" || fail "scrub-file: the concurrent append was lost"
grep -q 'sb_scrub_archive_file' "$BRAIN_DIR/error-log.jsonl" || fail "scrub-file: the concurrent-append abort was not logged"
[ -z "$(find "$BRAIN_DIR/transcripts" -name '*.part')" ] || fail "scrub-file: the aborted scrub left its scratch copy"
pass "scrub-file: in place, mtime + line count kept, idempotent, clean files untouched, failures loud and lossless"

# === R2 (0.56.0) archive-first: sb_archive_transcript (checked) + sb_archive_raw_window (cursor) ===
setup "archive-checked"
T="$TMP/archive-checked/t.jsonl"
jq -nc --arg t "key $K_ANT" '{type:"user",message:{content:$t}}' > "$T"
A="$BRAIN_DIR/transcripts/sx_proj_$(date +%Y-%m-%d).txt"
printf -- '--- session-meta ---\nsession_id: sx\n---\n\ntorn-tail' > "$A"
sb_archive_transcript "$T" proj sx 1 1 0 || fail "archive-checked: a good append returned non-zero"
grep -q 'sk-ant-' "$A" && fail "archive-checked: the archive holds the raw Anthropic key"
grep -q '^USER: key \[redacted:anthropic\]' "$A" || fail "archive-checked: the window was not archived scrubbed"
grep -qx 'torn-tail' "$A" || fail "archive-checked: the append glued onto a torn last line"
[ -z "$(tail -c 1 "$A")" ] || fail "archive-checked: the archive does not end in a newline"
[ -z "$(find "$BRAIN_DIR/transcripts" -name '*.part')" ] || fail "archive-checked: the stage file was left behind"
mkdir -p "$BRAIN_DIR/transcripts/sf_proj_$(date +%Y-%m-%d).txt"   # a directory squats on the archive name
: > "$BRAIN_DIR/error-log.jsonl"
( sb_archive_transcript "$T" proj sf 1 1 0 ) && fail "archive-checked: a failed append returned 0"
grep -q 'sb_archive_transcript' "$BRAIN_DIR/error-log.jsonl" || fail "archive-checked: a failed append was not logged"
pass "archive: append is scrubbed, checked and newline-terminated; a failure is loud and non-zero"

# Archive lines rendered by jq carry a CR on hosts whose jq writes CRLF (jq 1.8 on Windows): count CR-blind.
acount() { tr -d '\r' < "$1" | grep -c -- "$2"; }
setup "raw-window"
T="$TMP/raw-window/t.jsonl"; make_transcript "$T" 10
TN=$(sb_normalize_path "$T")
A="$BRAIN_DIR/transcripts/s1_proj_$(date +%Y-%m-%d).txt"
CUR="$BRAIN_DIR/.last-archived-line-proj--s1"
# The first call passes the Windows form of the path where one exists: the cursor stores the
# normalized path, so the POSIX form later is the SAME transcript (no reset, no duplicate).
T_FIRST="$T"; command -v cygpath >/dev/null 2>&1 && T_FIRST=$(cygpath -w "$T")
sb_archive_raw_window "$T_FIRST" proj s1 10 proj--s1 || fail "raw-window: the first window returned non-zero"
[ "$(cat "$CUR")" = "$(printf '10\t%s' "$TN")" ] || fail "raw-window: cursor should be '10<TAB>$TN', got '$(cat "$CUR")'"
[ "$(grep -c '^USER: question' "$A")" -eq 3 ] || fail "raw-window: lines 1-10 not archived once (questions: $(grep -c '^USER: question' "$A"))"
A_SUM=$(cksum < "$A")
sb_archive_raw_window "$T" proj s1 10 proj--s1 || fail "raw-window: an empty window returned non-zero"
[ "$(cksum < "$A")" = "$A_SUM" ] || fail "raw-window: an unchanged transcript (or the other path form) re-archived its window"
make_transcript "$T" 15
sb_archive_raw_window "$T" proj s1 15 proj--s1
[ "$(grep -c '^USER: question' "$A")" -eq 5 ] || fail "raw-window: only lines 11-15 should be appended (questions: $(grep -c '^USER: question' "$A"))"
[ "$(cut -f1 "$CUR")" = 15 ] || fail "raw-window: cursor did not advance to 15"
# a different transcript under the same key (path change) -> cursor 0
T2="$TMP/raw-window/other.jsonl"; make_transcript "$T2" 20
sb_archive_raw_window "$T2" proj s1 20 proj--s1
[ "$(acount "$A" '^USER: question 1$')" -eq 2 ] || fail "raw-window: a new transcript path did not restart the window at 0"
# the transcript shrank below the cursor (replaced) -> cursor 0
make_transcript "$T2" 5
sb_archive_raw_window "$T2" proj s1 5 proj--s1
[ "$(acount "$A" '^USER: question 1$')" -eq 3 ] || fail "raw-window: a cursor past the transcript end did not reset to 0"
pass "raw-window: cursor <raw_line TAB normalized path>, appends only (cursor, TOTAL], resets on path change and shrink"

setup "raw-legacy"
T="$TMP/raw-legacy/t.jsonl"; make_transcript "$T" 10
A="$BRAIN_DIR/transcripts/s2_proj_$(date +%Y-%m-%d).txt"
printf '6\n' > "$BRAIN_DIR/.last-extracted-line-proj--s2"
sb_archive_raw_window "$T" proj s2 10 proj--s2
[ "$(acount "$A" '^USER: question 1$')" -eq 0 ] || fail "raw-legacy: an absent cursor must start from the legacy extraction marker (6), not 0"
[ "$(acount "$A" '^USER: question 7$')" -eq 1 ] || fail "raw-legacy: lines 7-10 were not archived"
pass "raw-window: an absent cursor is initialised from the legacy .last-extracted-line marker"

setup "raw-edge"
T="$TMP/raw-edge/t.jsonl"; : > "$T"
sb_archive_raw_window "$T" proj s3 0 proj--s3 || fail "raw-edge: an empty transcript returned non-zero"
[ ! -e "$BRAIN_DIR/.last-archived-line-proj--s3" ] || fail "raw-edge: an empty window wrote a cursor"
printf '%s\n' '{"type":"system","content":"x"}' '{"type":"attachment"}' > "$T"
sb_archive_raw_window "$T" proj s3 2 proj--s3 || fail "raw-edge: a window that renders nothing returned non-zero"
[ -z "$(find "$BRAIN_DIR/transcripts" -name 's3_*')" ] || fail "raw-edge: a window that renders nothing created a header-only archive"
[ "$(cut -f1 "$BRAIN_DIR/.last-archived-line-proj--s3")" = 2 ] || fail "raw-edge: the cursor did not advance past a window that renders nothing"
make_transcript "$T" 4
mkdir -p "$BRAIN_DIR/transcripts/s4_proj_$(date +%Y-%m-%d).txt"   # the append will fail
: > "$BRAIN_DIR/error-log.jsonl"
( sb_archive_raw_window "$T" proj s4 4 proj--s4 ) && fail "raw-edge: a failed append returned 0"
[ ! -e "$BRAIN_DIR/.last-archived-line-proj--s4" ] || fail "raw-edge: the cursor advanced after a failed append (the window would be lost)"
grep -q 'sb_archive_transcript' "$BRAIN_DIR/error-log.jsonl" || fail "raw-edge: the failed append was not logged"
pass "raw-window: empty window is a no-op, a render-nothing window advances without a file, a failed append keeps the cursor"

echo "ALL PASS"
