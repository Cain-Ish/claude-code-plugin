#!/usr/bin/env bash
# P4 (deep-review): FORGET derives a page's age from its filesystem mtime
# (wiki-forget-score.sh:38). dream-snapshot.sh snapshotted the wiki with plain
# `cp -r`, which RESETS every staged page's mtime to "now"; dream-accept then
# rsyncs those onto live, re-arming the FORGET age-gate corpus-wide so no page
# can ever accumulate enough age to become a candidate. The FORGET recency fix
# (0.24.47) was silently neutered by this.
#
# ORACLE: the page's REAL mtime (a filesystem fact, not a re-read of the
# implementation's own output). A genuinely-old page must keep its old mtime
# through the snapshot.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SNAP="$REPO_ROOT/scripts/dream-snapshot.sh"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export BRAIN_DIR="$SANDBOX/brain"
export KNOWLEDGE_DIR="$SANDBOX/knowledge"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"   # dream-snapshot reads THIS, not bare KNOWLEDGE_DIR
mkdir -p "$BRAIN_DIR/transcripts" "$KNOWLEDGE_DIR/wiki/entities"

# an OLD page (set mtime to 2025-01-01) + a transcript so the snapshot runs
OLD="$KNOWLEDGE_DIR/wiki/entities/ancient.md"
printf -- '---\ntitle: ancient\ntype: entities\nrelated: []\n---\n\n# ancient\n\nbody\n' > "$OLD"
touch -t 202501010000 "$OLD"
printf 'session transcript content\n' > "$BRAIN_DIR/transcripts/sess_2025-01-01.txt"

ORIG_MTIME=$(stat -c %Y "$OLD" 2>/dev/null || stat -f %m "$OLD")

CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$SNAP" --max-count 5 >/dev/null 2>&1 || true

STAGED=$(find "$BRAIN_DIR/dreams" -path '*/staging/wiki/entities/ancient.md' 2>/dev/null | head -1)
[ -n "$STAGED" ] || fail "snapshot did not produce a staged copy of the page"

STAGED_MTIME=$(stat -c %Y "$STAGED" 2>/dev/null || stat -f %m "$STAGED")
NOW=$(date +%s)

# The staged mtime must equal the ORIGINAL old mtime — NOT be reset to ~now.
if [ "$STAGED_MTIME" = "$ORIG_MTIME" ]; then
  pass "snapshot preserves the old page's mtime ($STAGED_MTIME) — FORGET age survives"
else
  DELTA=$(( NOW - STAGED_MTIME ))
  fail "staged mtime reset (orig=$ORIG_MTIME staged=$STAGED_MTIME, ${DELTA}s ago ≈ now) — FORGET age-gate re-armed"
fi

# Sharper: the staged page must be older than the 30-day FORGET MINAGE floor.
AGE_DAYS=$(( (NOW - STAGED_MTIME) / 86400 ))
[ "$AGE_DAYS" -ge 30 ] && pass "staged page age ${AGE_DAYS}d ≥ 30d MINAGE (a real FORGET candidate)" \
  || fail "staged page age ${AGE_DAYS}d < 30d — would be PROTECT:age'd, never forgettable"

# ---------------------------------------------------------------------------
# D095: transcript selection must be by the DATE embedded in the filename,
# newest first, never by lexical filename sort. `<session-id>_<slug>_<date>.txt`
# and `sub-<hex>_<slug>_<date>.txt` both put the date as a SUFFIX; a plain
# `ls | sort -r` puts every sub-* file first ('s' > any hex digit) regardless
# of date. Fixture: 6 UUID-prefixed main-session transcripts dated NEWER
# (2026-08-01..06) + 6 sub-* transcripts dated OLDER (2026-07-01..06). The 6
# newest (the main-session files) must be staged; the 6 older sub-* must not.
rm -rf "$SANDBOX/home2" "$BRAIN_DIR/dreams"
BRAIN_DIR2="$SANDBOX/brain2"
KNOWLEDGE_DIR2="$SANDBOX/knowledge2"
mkdir -p "$BRAIN_DIR2/transcripts" "$KNOWLEDGE_DIR2/wiki/entities"
printf -- '---\ntitle: p\ntype: entities\nrelated: []\n---\n\n# p\n\nbody\n' > "$KNOWLEDGE_DIR2/wiki/entities/p.md"

for d in 01 02 03 04 05 06; do
  uuid="11111111-1111-1111-1111-11111111${d}${d}"
  printf 'main session transcript %s\n' "$d" > "$BRAIN_DIR2/transcripts/${uuid}_proj_2026-08-${d}.txt"
  printf 'sub-agent transcript %s\n' "$d" > "$BRAIN_DIR2/transcripts/sub-aaaa${d}_proj_2026-07-${d}.txt"
done

CLAUDE_PLUGIN_ROOT="$REPO_ROOT" BRAIN_DIR="$BRAIN_DIR2" \
  CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR2" KNOWLEDGE_DIR="$KNOWLEDGE_DIR2" \
  bash "$SNAP" --max-count 6 >/dev/null 2>&1 || fail "dream-snapshot exited non-zero on the selection fixture"

STAGED_DIR=$(find "$BRAIN_DIR2/dreams" -maxdepth 2 -type d -name transcripts | head -1)
[ -n "$STAGED_DIR" ] || fail "no staged transcripts dir produced"
STAGED_MAIN=$(find "$STAGED_DIR" -name '1111*' | wc -l | tr -d ' ')
STAGED_SUB=$(find "$STAGED_DIR" -name 'sub-*' | wc -l | tr -d ' ')
if [ "$STAGED_MAIN" = "6" ] && [ "$STAGED_SUB" = "0" ]; then
  pass "D095: the 6 newest main-session transcripts are staged, the 6 older sub-* excluded"
else
  fail "D095: selection is not date-ordered (staged main=$STAGED_MAIN sub=$STAGED_SUB, expected main=6 sub=0)"
fi

# ---------------------------------------------------------------------------
# D091: a `cp -rp` failure (or a silent partial copy) must mark the dream
# failed instead of writing a "pending" status.json and letting a half-copied
# staging tree pass dream-accept's floor.
FAKEBIN="$SANDBOX/fakebin-cp-fail"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/cp" <<EOF
#!/bin/bash
echo x >> "$FAKEBIN/calls"
exit 7
EOF
chmod +x "$FAKEBIN/cp"

BRAIN_DIR3="$SANDBOX/brain3"
KNOWLEDGE_DIR3="$SANDBOX/knowledge3"
mkdir -p "$BRAIN_DIR3/transcripts" "$KNOWLEDGE_DIR3/wiki/entities"
printf -- '---\ntitle: p\ntype: entities\nrelated: []\n---\n\n# p\n\nbody\n' > "$KNOWLEDGE_DIR3/wiki/entities/p.md"
printf 'tx\n' > "$BRAIN_DIR3/transcripts/sess_2026-01-01.txt"

set +e
PATH="$FAKEBIN:$PATH" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" BRAIN_DIR="$BRAIN_DIR3" \
  CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR3" KNOWLEDGE_DIR="$KNOWLEDGE_DIR3" \
  bash "$SNAP" --max-count 5 >/dev/null 2>/dev/null
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "D091: dream-snapshot exited 0 despite cp failing"

FAILED_STATUS=$(find "$BRAIN_DIR3/dreams" -name status.json -exec jq -r '.status' {} \; 2>/dev/null | head -1)
FAILED_ERR=$(find "$BRAIN_DIR3/dreams" -name status.json -exec jq -r '.error' {} \; 2>/dev/null | head -1)
if [ "$FAILED_STATUS" = "failed" ]; then
  pass "D091: a cp failure marks the dream failed (error: $FAILED_ERR)"
else
  fail "D091: cp exited 7 but status.json status='$FAILED_STATUS' (expected failed)"
fi
# The live wiki held still, so a cp error is a real fault: no snapshot retry.
D091_CALLS=$(grep -c . "$FAKEBIN/calls" 2>/dev/null || echo 0)
[ "$D091_CALLS" = 1 ] && pass "D091: a cp error on a still wiki is not retried" \
  || fail "D091: cp error on a still wiki was copied $D091_CALLS times (expected 1, no retry)"

# ---------------------------------------------------------------------------
# Concurrent writer: the drainer/maintainer/reindex keep writing the live wiki, so a page
# that lands while `cp -rp` runs leaves staged != live and D091's count check failed the
# whole dream (2026-09-24, live: "staged 933 of 934 live pages" during a reindex). A one-off
# mid-copy write must be absorbed by a re-snapshot; a wiki that never settles must still
# fail loud after the bounded retries. ORACLE: staged vs live page counts on disk and the
# number of wiki copies the fake cp saw — never the script's own status text alone.
set +e
REAL_CP=$(command -v cp)
race_fixture() {  # $1 brain dir, $2 knowledge dir
  mkdir -p "$1/transcripts" "$2/wiki/entities"
  printf -- '---\ntitle: p\ntype: entities\nrelated: []\n---\n\n# p\n\nbody\n' > "$2/wiki/entities/p.md"
  printf 'tx\n' > "$1/transcripts/sess_2026-01-01.txt"
}
# Fake cp: real copy, then a "concurrent writer" acts. $3 mode —
#   once:    lands a new live page during the 1st copy only, and sleeps 2s after every copy
#            (so a created_at stamped AFTER the copy is provably later than the copy start)
#   always:  lands a new live page during every copy (never settles)
#   rename:  renames live p.md -> q.md during the 1st copy (mv keeps the count AND the mtime)
#   partial: drops p.md from the STAGED copy with cp exiting 0, live untouched (a real fault)
#   vanish:  unlinks live p.md during the 1st copy and exits 1, as cp's "cannot stat" does
#   truncate: empties the STAGED p.md and exits 28 (ENOSPC) — page lists still match
# Only the wiki snapshot copy (source "<wiki>/.") is faked, counted and timed; any other cp
# (e.g. lib.sh's transcript copy fallback) passes straight through.
make_race_cp() {  # $1 bin dir, $2 live wiki dir, $3 mode
  mkdir -p "$1"
  cat > "$1/cp" <<EOF
#!/bin/bash
case " \$* " in *"/wiki/. "*) ;; *) exec "$REAL_CP" "\$@" ;; esac
date -u +%Y-%m-%dT%H:%M:%SZ >> "$1/starts"
"$REAL_CP" "\$@"; rc=\$?
for dest; do :; done
n=\$(( \$(cat "$1/calls" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$1/calls"
case "$3:\$n" in
  always:*|once:1) printf -- '---\ntitle: late\ntype: entities\nrelated: []\n---\n\nbody\n' > "$2/entities/late-\$n.md" ;;
  rename:1) mv "$2/entities/p.md" "$2/entities/q.md" ;;
  partial:*) rm -f "\${dest%/}/entities/p.md" ;;
  vanish:1) rm -f "$2/entities/p.md"; rc=1 ;;
  truncate:*) : > "\${dest%/}/entities/p.md"; rc=28 ;;
  tmpvanish:1) echo "cp: cannot stat '$2/.embeddings-cache.json.tmp.4242': No such file or directory" >&2; rc=1 ;;
  ioerr:*) echo "cp: error reading '$2/entities/p.md': Input/output error" >&2; rc=1 ;;
esac
[ "$3" = once ] && sleep 2
exit \$rc
EOF
  chmod +x "$1/cp"
}
run_race() {  # $1 bin dir, $2 brain dir, $3 knowledge dir
  PATH="$1:$PATH" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" BRAIN_DIR="$2" \
    CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$3" KNOWLEDGE_DIR="$3" \
    bash "$SNAP" --max-count 5 >/dev/null 2>&1
}

BRAIN_DIR4="$SANDBOX/brain4"; KNOWLEDGE_DIR4="$SANDBOX/knowledge4"
race_fixture "$BRAIN_DIR4" "$KNOWLEDGE_DIR4"
make_race_cp "$SANDBOX/fakebin-race-once" "$KNOWLEDGE_DIR4/wiki" once
run_race "$SANDBOX/fakebin-race-once" "$BRAIN_DIR4" "$KNOWLEDGE_DIR4"; RC=$?
ST=$(find "$BRAIN_DIR4/dreams" -name status.json -exec jq -r '.status' {} \; | tr -d '\r' | head -1)
STAGED_N=$(find "$BRAIN_DIR4/dreams" -path '*/staging/wiki/*' -name '*.md' | wc -l | tr -d ' ')
LIVE_N=$(find "$KNOWLEDGE_DIR4/wiki" -name '*.md' | wc -l | tr -d ' ')
if [ "$RC" -eq 0 ] && [ "$ST" = "pending" ] && [ "$STAGED_N" = "$LIVE_N" ]; then
  pass "concurrent writer: a page landing mid-copy is absorbed by a re-snapshot (staged=$STAGED_N live=$LIVE_N)"
else
  fail "concurrent writer: rc=$RC status='$ST' staged=$STAGED_N live=$LIVE_N (expected rc=0, pending, staged==live)"
fi
CALLS=$(cat "$SANDBOX/fakebin-race-once/calls" 2>/dev/null || echo 0)
[ "$CALLS" = 2 ] && pass "the raced copy was re-snapshotted exactly once" \
  || fail "concurrent writer: expected 2 wiki copies (race + re-snapshot), saw $CALLS"
[ -z "$(find "$BRAIN_DIR4/dreams" -path '*/staging/wiki/wiki' 2>/dev/null)" ] \
  && pass "re-snapshot does not nest staging/wiki/wiki" || fail "re-snapshot nested a copy under staging/wiki/wiki"
# dream-accept protects live pages newer than created_at, so created_at must not postdate the
# copy it describes. ISO-8601 UTC strings compare correctly as plain strings.
CA=$(find "$BRAIN_DIR4/dreams" -name status.json -exec jq -r '.created_at' {} \; | tr -d '\r' | head -1)
LAST_START=$(tail -1 "$SANDBOX/fakebin-race-once/starts")
if [ -n "$CA" ] && ! [ "$CA" \> "$LAST_START" ]; then
  pass "created_at ($CA) is taken before the copy it describes (started $LAST_START)"
else
  fail "created_at '$CA' postdates the snapshot copy started $LAST_START — accept would overwrite live edits made in between"
fi

BRAIN_DIR6="$SANDBOX/brain6"; KNOWLEDGE_DIR6="$SANDBOX/knowledge6"
race_fixture "$BRAIN_DIR6" "$KNOWLEDGE_DIR6"
make_race_cp "$SANDBOX/fakebin-race-rename" "$KNOWLEDGE_DIR6/wiki" rename
run_race "$SANDBOX/fakebin-race-rename" "$BRAIN_DIR6" "$KNOWLEDGE_DIR6"; RC=$?
ST=$(find "$BRAIN_DIR6/dreams" -name status.json -exec jq -r '.status' {} \; | tr -d '\r' | head -1)
HAS_Q=$(find "$BRAIN_DIR6/dreams" -path '*/staging/wiki/entities/q.md' | wc -l | tr -d ' ')
HAS_P=$(find "$BRAIN_DIR6/dreams" -path '*/staging/wiki/entities/p.md' | wc -l | tr -d ' ')
if [ "$RC" -eq 0 ] && [ "$ST" = "pending" ] && [ "$HAS_Q" = 1 ] && [ "$HAS_P" = 0 ]; then
  pass "a mid-copy rename (same count) is caught by the page-list check and re-snapshotted"
else
  fail "mid-copy rename: rc=$RC status='$ST' staged q.md=$HAS_Q p.md=$HAS_P (expected pending with q.md only — a count check passes the stale p.md)"
fi

BRAIN_DIR7="$SANDBOX/brain7"; KNOWLEDGE_DIR7="$SANDBOX/knowledge7"
race_fixture "$BRAIN_DIR7" "$KNOWLEDGE_DIR7"
make_race_cp "$SANDBOX/fakebin-race-partial" "$KNOWLEDGE_DIR7/wiki" partial
run_race "$SANDBOX/fakebin-race-partial" "$BRAIN_DIR7" "$KNOWLEDGE_DIR7"; RC=$?
ST=$(find "$BRAIN_DIR7/dreams" -name status.json -exec jq -r '.status' {} \; | tr -d '\r' | head -1)
CALLS=$(cat "$SANDBOX/fakebin-race-partial/calls" 2>/dev/null || echo 0)
if [ "$RC" -ne 0 ] && [ "$ST" = "failed" ] && [ "$CALLS" = 1 ]; then
  pass "a short copy against a live wiki that held still fails at once (no retry)"
else
  fail "partial copy, live unchanged: rc=$RC status='$ST' copies=$CALLS (expected non-zero, failed, 1 copy)"
fi

BRAIN_DIR9="$SANDBOX/brain9"; KNOWLEDGE_DIR9="$SANDBOX/knowledge9"
race_fixture "$BRAIN_DIR9" "$KNOWLEDGE_DIR9"
make_race_cp "$SANDBOX/fakebin-race-vanish" "$KNOWLEDGE_DIR9/wiki" vanish
run_race "$SANDBOX/fakebin-race-vanish" "$BRAIN_DIR9" "$KNOWLEDGE_DIR9"; RC=$?
ST=$(find "$BRAIN_DIR9/dreams" -name status.json -exec jq -r '.status' {} \; | tr -d '\r' | head -1)
CALLS=$(cat "$SANDBOX/fakebin-race-vanish/calls" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$ST" = "pending" ] && [ "$CALLS" = 2 ]; then
  pass "a cp error from a page unlinked mid-copy is retried, not failed"
else
  fail "page unlinked mid-copy: rc=$RC status='$ST' copies=$CALLS (expected rc=0, pending, 2 copies)"
fi

# D091's harm with the page lists intact: cp truncates a page and exits non-zero (ENOSPC) while
# the live wiki holds still. Only the cp exit code can catch this — the dream must fail.
BRAIN_DIR10="$SANDBOX/brain10"; KNOWLEDGE_DIR10="$SANDBOX/knowledge10"
race_fixture "$BRAIN_DIR10" "$KNOWLEDGE_DIR10"
make_race_cp "$SANDBOX/fakebin-race-truncate" "$KNOWLEDGE_DIR10/wiki" truncate
run_race "$SANDBOX/fakebin-race-truncate" "$BRAIN_DIR10" "$KNOWLEDGE_DIR10"; RC=$?
ST=$(find "$BRAIN_DIR10/dreams" -name status.json -exec jq -r '.status' {} \; | tr -d '\r' | head -1)
ERR=$(find "$BRAIN_DIR10/dreams" -name status.json -exec jq -r '.error' {} \; | tr -d '\r' | head -1)
CALLS=$(cat "$SANDBOX/fakebin-race-truncate/calls" 2>/dev/null || echo 0)
case "$ERR" in *"exited 28"*) ERR_OK=1 ;; *) ERR_OK=0 ;; esac
if [ "$RC" -ne 0 ] && [ "$ST" = "failed" ] && [ "$ERR_OK" = 1 ] && [ "$CALLS" = 1 ]; then
  pass "a truncating cp error with matching page lists fails the dream (no retry)"
else
  fail "truncating cp error: rc=$RC status='$ST' copies=$CALLS error='$ERR' (expected failed, 'exited 28', 1 copy)"
fi

# A temp file renamed away mid-copy (the embeddings cache and index.md are rewritten through
# tmp+rename by every search) makes cp exit 1 with only "cannot stat … No such file" while the
# page lists hold still: a race, retried — not a failed dream.
BRAIN_DIR12="$SANDBOX/brain12"; KNOWLEDGE_DIR12="$SANDBOX/knowledge12"
race_fixture "$BRAIN_DIR12" "$KNOWLEDGE_DIR12"
make_race_cp "$SANDBOX/fakebin-race-tmpvanish" "$KNOWLEDGE_DIR12/wiki" tmpvanish
run_race "$SANDBOX/fakebin-race-tmpvanish" "$BRAIN_DIR12" "$KNOWLEDGE_DIR12"; RC=$?
ST=$(find "$BRAIN_DIR12/dreams" -name status.json -exec jq -r '.status' {} \; | tr -d '\r' | head -1)
CALLS=$(cat "$SANDBOX/fakebin-race-tmpvanish/calls" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$ST" = "pending" ] && [ "$CALLS" = 2 ]; then
  pass "a cp error made only of vanished temp files is retried, not failed"
else
  fail "vanished temp file, lists unchanged: rc=$RC status='$ST' copies=$CALLS (expected rc=0, pending, 2 copies)"
fi

# Any other cp error with matching page lists (EIO here) is a fault: fail at once, no retry, and
# the reason names the attempt.
BRAIN_DIR13="$SANDBOX/brain13"; KNOWLEDGE_DIR13="$SANDBOX/knowledge13"
race_fixture "$BRAIN_DIR13" "$KNOWLEDGE_DIR13"
make_race_cp "$SANDBOX/fakebin-race-ioerr" "$KNOWLEDGE_DIR13/wiki" ioerr
run_race "$SANDBOX/fakebin-race-ioerr" "$BRAIN_DIR13" "$KNOWLEDGE_DIR13"; RC=$?
ST=$(find "$BRAIN_DIR13/dreams" -name status.json -exec jq -r '.status' {} \; | tr -d '\r' | head -1)
ERR=$(find "$BRAIN_DIR13/dreams" -name status.json -exec jq -r '.error' {} \; | tr -d '\r' | head -1)
CALLS=$(cat "$SANDBOX/fakebin-race-ioerr/calls" 2>/dev/null || echo 0)
case "$ERR" in *"exited 1"*"attempt 1/3"*) ERR_OK=1 ;; *) ERR_OK=0 ;; esac
if [ "$RC" -ne 0 ] && [ "$ST" = "failed" ] && [ "$ERR_OK" = 1 ] && [ "$CALLS" = 1 ]; then
  pass "a non-vanish cp error (EIO) with matching page lists fails at once, naming the attempt"
else
  fail "EIO cp error: rc=$RC status='$ST' copies=$CALLS error='$ERR' (expected failed, 'exited 1 … attempt 1/3', 1 copy)"
fi

# A find that cannot list the staged tree leaves the snapshot unverified — fail, never pass.
REAL_FIND=$(command -v find)
BRAIN_DIR11="$SANDBOX/brain11"; KNOWLEDGE_DIR11="$SANDBOX/knowledge11"
race_fixture "$BRAIN_DIR11" "$KNOWLEDGE_DIR11"
mkdir -p "$SANDBOX/fakebin-findfail"
cat > "$SANDBOX/fakebin-findfail/find" <<EOF
#!/bin/bash
case "\$PWD" in */staging/wiki) exit 1 ;; esac
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$SANDBOX/fakebin-findfail/find"
run_race "$SANDBOX/fakebin-findfail" "$BRAIN_DIR11" "$KNOWLEDGE_DIR11"; RC=$?
ST=$("$REAL_FIND" "$BRAIN_DIR11/dreams" -name status.json -exec jq -r '.status' {} \; | tr -d '\r' | head -1)
ERR=$("$REAL_FIND" "$BRAIN_DIR11/dreams" -name status.json -exec jq -r '.error' {} \; | tr -d '\r' | head -1)
case "$ERR" in *"could not list"*) ERR_OK=1 ;; *) ERR_OK=0 ;; esac
if [ "$RC" -ne 0 ] && [ "$ST" = "failed" ] && [ "$ERR_OK" = 1 ]; then
  pass "a failed page listing fails the dream instead of passing it unverified"
else
  fail "find failure: rc=$RC status='$ST' error='$ERR' (expected failed, 'could not list')"
fi

# A leftover staging/wiki that cannot be removed (Windows: a scanner holding a handle) must fail
# the dream — never be copied into, which nests staging/wiki/wiki and passes a recursive count.
REAL_RM=$(command -v rm)
BRAIN_DIR8="$SANDBOX/brain8"; KNOWLEDGE_DIR8="$SANDBOX/knowledge8"
race_fixture "$BRAIN_DIR8" "$KNOWLEDGE_DIR8"
make_race_cp "$SANDBOX/fakebin-race-rmfail" "$KNOWLEDGE_DIR8/wiki" once
cat > "$SANDBOX/fakebin-race-rmfail/rm" <<EOF
#!/bin/bash
case "\$*" in *staging/wiki) exit 1 ;; esac
exec "$REAL_RM" "\$@"
EOF
chmod +x "$SANDBOX/fakebin-race-rmfail/rm"
run_race "$SANDBOX/fakebin-race-rmfail" "$BRAIN_DIR8" "$KNOWLEDGE_DIR8"; RC=$?
ST=$(find "$BRAIN_DIR8/dreams" -name status.json -exec jq -r '.status' {} \; | tr -d '\r' | head -1)
ERR=$(find "$BRAIN_DIR8/dreams" -name status.json -exec jq -r '.error' {} \; | tr -d '\r' | head -1)
NESTED=$(find "$BRAIN_DIR8/dreams" -path '*/staging/wiki/wiki' 2>/dev/null | wc -l | tr -d ' ')
case "$ERR" in *"fresh staging/wiki"*) ERR_OK=1 ;; *) ERR_OK=0 ;; esac
if [ "$RC" -ne 0 ] && [ "$ST" = "failed" ] && [ "$ERR_OK" = 1 ] && [ "$NESTED" = 0 ]; then
  pass "an unremovable leftover staging/wiki fails the dream instead of nesting a copy"
else
  fail "unremovable staging/wiki: rc=$RC status='$ST' nested=$NESTED error='$ERR'"
fi

BRAIN_DIR5="$SANDBOX/brain5"; KNOWLEDGE_DIR5="$SANDBOX/knowledge5"
race_fixture "$BRAIN_DIR5" "$KNOWLEDGE_DIR5"
make_race_cp "$SANDBOX/fakebin-race-always" "$KNOWLEDGE_DIR5/wiki" always
run_race "$SANDBOX/fakebin-race-always" "$BRAIN_DIR5" "$KNOWLEDGE_DIR5"; RC=$?
ST=$(find "$BRAIN_DIR5/dreams" -name status.json -exec jq -r '.status' {} \; | tr -d '\r' | head -1)
ERR=$(find "$BRAIN_DIR5/dreams" -name status.json -exec jq -r '.error' {} \; | tr -d '\r' | head -1)
CALLS=$(cat "$SANDBOX/fakebin-race-always/calls" 2>/dev/null || echo 0)
case "$ERR" in *"snapshot incomplete"*) ERR_OK=1 ;; *) ERR_OK=0 ;; esac
if [ "$RC" -ne 0 ] && [ "$ST" = "failed" ] && [ "$ERR_OK" = 1 ] && [ "$CALLS" = 3 ]; then
  pass "never-settling wiki: fails loud after 3 bounded snapshot attempts ($ERR)"
else
  fail "never-settling wiki: rc=$RC status='$ST' copies=$CALLS error='$ERR' (expected non-zero, failed, 3 copies, 'snapshot incomplete')"
fi

echo "ALL PASS"
