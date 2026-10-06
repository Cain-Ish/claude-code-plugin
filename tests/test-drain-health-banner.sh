#!/bin/bash
# pins: SB_DRAIN_DEADMAN — kill-switch test: asserts =off suppresses the deadman banner
# pins: SB_DRAIN_HEALTH_BANNER — kill-switch test: asserts =off suppresses the health banner
# pins: SB_SCRUB_MIGRATE_MAX_FILES — the no-drainer scrub case sets 2 so the migration needs several session starts (the per-run cap under test)
# run-all-timeout: 360   (~30 SessionStart runs at ~6 s each on MSYS; the no-drainer scrub case adds 4 plus a 5 s lock wait and its detached runs, ~50 s. Measured on a quiet MSYS dev box 2026-10-06: 167-170 s; 103-108 s before the M5 and N cases)
# Out-of-band DRAINER health banner (Phase 1 task 5, root cause #2: silent failure).
# ORACLE: crafted error-log.jsonl / .extraction-state.jsonl / quarantine fixtures with
# KNOWN counts → assert the banner fires/omits and the OS-aware remedy matches uname -s.
# We assert against session-load.sh's emitted stdout, never by re-calling the helper.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

B=$(mktemp -d); trap 'rm -rf "$B"' EXIT
export HOME="$B"
# Defensively disable the maintain/dream cascade — a hook test must never spawn.
printf '{"auto_improve": false, "auto_maintain": false}\n' > "$B/config.json"
BANNER='background extraction is failing silently'

emit(){ printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' | env BRAIN_DIR="$B" HOME="$B" bash "$SL" 2>/dev/null; }
reset(){ rm -f "$B/error-log.jsonl" "$B/.extraction-state.jsonl" "$B/.llm-maintain-quarantine"; }
ec124(){ local n="$1" i; : > "$B/error-log.jsonl"
  for i in $(seq 1 "$n"); do
    printf '{"ts":"2026-06-17T13:0%s:00Z","script":"extract-drain.sh","level":"TRACE","message":"extractor-diag stage=direct ec=124 out=0 cc=0 ak=0 pty=no"}\n' "$i" >> "$B/error-log.jsonl"
  done; }

echo "=== drain-health banner ==="

# 1: >=3 ec=124 timeouts → banner fires
reset; ec124 4
O=$(emit)
printf '%s' "$O" | grep -q "$BANNER" && pass "1: >=3 ec=124 timeouts fire the banner" || fail "1: banner did not fire on timeouts"

# 2: no signal → no banner
reset
O=$(emit)
printf '%s' "$O" | grep -q "$BANNER" && fail "2: banner fired with no signal" || pass "2: no signal → no banner"

# 3: quarantine ALONE → drain-health banner does NOT fire (dream-autostage owns it)
reset; printf '[2026-06-11T00:00:00Z] quarantined: bwrap preflight failed\n' > "$B/.llm-maintain-quarantine"
O=$(emit)
printf '%s' "$O" | grep -q "$BANNER" && fail "3: drain-health double-fired on quarantine" || pass "3: quarantine-alone does NOT fire drain-health (no double-banner)"

# 4: >=5 archives whose unextracted tail is dead-lettered → banner fires. R2: the count comes from
# sb_drain_cursor_map, so the archives must exist (3 lines each; an error row covers (0,3]).
reset; : > "$B/.extraction-state.jsonl"; mkdir -p "$B/transcripts"
for i in 1 2 3 4 5 6; do
  printf -- '--- session-meta ---\n---\nUSER: x\n' > "$B/transcripts/s$i.txt"
  printf '{"basename":"s%s.txt","ts":"2026-06-17T00:00:00Z","outcome":"error","from":0,"lines":3,"fails":3}\n' "$i" >> "$B/.extraction-state.jsonl"
done
O=$(emit)
printf '%s' "$O" | grep -q "$BANNER" && pass "4: >=5 dead-letter transcripts fire the banner" || fail "4: dead-letter banner did not fire"
# 4b (R2 fix X2#1): the same six archives GREW past their dead region. The new lines are pending
# work, but the dead region (0,3] of each was never extracted and never will be: it still counts
# (it used to vanish from every counter once the archive grew or a later window succeeded), and
# the growth is not counted as dead.
for i in 1 2 3 4 5 6; do printf 'USER: more\nASSISTANT: ok\n' >> "$B/transcripts/s$i.txt"; done
O=$(emit)
printf '%s' "$O" | grep -q "$BANNER" && printf '%s' "$O" | grep -q '6 transcript(s) hold dead-lettered windows (6 window(s), 18 lines' \
  && pass "4b: a dead region stays counted after growth; the growth is not dead" \
  || fail "4b: dead regions of grown archives miscounted (got: $(printf '%s' "$O" | grep 'signal:' | head -c 300))"
rm -f "$B/transcripts"/s[1-6].txt

# 5: kill switch suppresses
reset; ec124 4
O=$(SB_DRAIN_HEALTH_BANNER=off emit)
printf '%s' "$O" | grep -q "$BANNER" && fail "5: kill switch did not suppress" || pass "5: SB_DRAIN_HEALTH_BANNER=off suppresses"

# 6: OS-aware remedy
reset; ec124 4
O=$(emit)
if [ "$(uname -s)" = "Linux" ]; then
  printf '%s' "$O" | grep -q 'SB_DRAIN_EXTRACT_TIMEOUT' && pass "6: Linux remedy names the timeout knob" || fail "6: Linux remedy missing the timeout knob"
else
  printf '%s' "$O" | grep -q 'second-brain:maintain' && pass "6: non-Linux remedy points to in-session maintain" || fail "6: non-Linux remedy missing"
fi

# Direct unit coverage for the two threshold-driving banner helpers (review: they had no direct
# test). Source lib.sh and assert the count logic against crafted fixtures, incl. the dead-letter
# fold's per-basename last-write-wins (a retried-then-errored basename counts once; an
# errored-then-recovered one does not count).
export BRAIN_DIR="$B/helpers"; mkdir -p "$BRAIN_DIR"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib.sh"
printf '%s\n' \
  '{"script":"extract-drain.sh","level":"TRACE","message":"extractor-diag stage=direct ec=124 x"}' \
  '{"script":"extract-drain.sh","level":"TRACE","message":"extractor-diag stage=pty ec=124 x"}' \
  '{"script":"x","message":"unrelated line, no token"}' > "$BRAIN_DIR/error-log.jsonl"
HN=$(sb_count_drain_timeouts 40)
[ "$HN" = "2" ] && pass "helper: sb_count_drain_timeouts counts ec=124 lines (2)" || fail "helper: timeouts=$HN (want 2)"
# R2: a dead letter is an ARCHIVE holding a dead-lettered window (an error row whose lines no ok
# row re-covered), whatever its state (X2#1). a errored; b retried then errored; c errored then an
# ok row re-covered the same window; d errored on (0,3] and grew to 5 lines since (still dead).
mkdir -p "$BRAIN_DIR/transcripts"
for f in a b c; do printf 'l1\nl2\nl3\n' > "$BRAIN_DIR/transcripts/$f.txt"; done
printf 'l1\nl2\nl3\nl4\nl5\n' > "$BRAIN_DIR/transcripts/d.txt"
printf '%s\n' \
  '{"basename":"a.txt","outcome":"error","from":0,"lines":3}' \
  '{"basename":"b.txt","outcome":"retry","from":0,"lines":3}' \
  '{"basename":"b.txt","outcome":"error","from":0,"lines":3}' \
  '{"basename":"c.txt","outcome":"error","from":0,"lines":3}' \
  '{"basename":"c.txt","outcome":"ok","from":0,"lines":3}' \
  '{"basename":"d.txt","outcome":"error","from":0,"lines":3}' > "$BRAIN_DIR/.extraction-state.jsonl"
HD=$(sb_count_drain_dead_letters)
[ "$HD" = "3" ] && pass "helper: sb_count_drain_dead_letters (a, b, d hold a dead window; c re-covered → 3)" || fail "helper: dead-letters=$HD (want 3)"

echo "=== capture-health extracted count ==="
# R2: "N archived · M extracted" counts ARCHIVES (via the cursor map), not ok rows: delta extraction
# writes one ok row per window, so the row count overstated it (here 3 rows for 1 archive).
CB="$B/capture"; mkdir -p "$CB/transcripts" "$CB/sbin"
printf '{"auto_improve": false, "auto_maintain": false}\n' > "$CB/config.json"
printf -- '--- session-meta ---\n---\nUSER: a\nUSER: b\nUSER: c\nUSER: d\n' > "$CB/transcripts/x1.txt"
printf '%s\n' \
  '{"basename":"x1.txt","ts":"2026-06-17T00:00:00Z","outcome":"ok","from":0,"lines":3}' \
  '{"basename":"x1.txt","ts":"2026-06-17T00:00:00Z","outcome":"ok","from":3,"lines":4}' \
  '{"basename":"x1.txt","ts":"2026-06-17T00:00:00Z","outcome":"ok","from":4,"lines":6}' > "$CB/.extraction-state.jsonl"
printf '#!/bin/bash\nexit 0\n' > "$CB/sbin/claude"; printf '#!/bin/bash\necho OtherOS\n' > "$CB/sbin/uname"
chmod +x "$CB/sbin/claude" "$CB/sbin/uname"
CO=$(printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' \
  | env PATH="$CB/sbin:$PATH" ANTHROPIC_API_KEY="" BRAIN_DIR="$CB" HOME="$CB" bash "$SL" 2>/dev/null)
printf '%s' "$CO" | grep -q 'capture: 1 archived · 1 extracted' \
  && pass "C1: extracted counts archives, not ok rows (1 archive, 3 windows)" \
  || fail "C1: capture line miscounts (got: $(printf '%s' "$CO" | grep -i 'second-brain capture' | head -c 200))"

echo "=== sb-health-snapshot backlog ==="
# R2: the snapshot's backlog comes from the cursor map. g1 was extracted to line 3 and then GREW
# (pending); g2 is fully extracted (done). The old comm-over-basenames called both done.
SNAP="$ROOT/.claude/skills/sb-diagnostics-and-tooling/scripts/sb-health-snapshot.sh"
SB2="$B/snap"; mkdir -p "$SB2/transcripts" "$SB2/sbin"
printf '#!/bin/bash\nexit 0\n' > "$SB2/sbin/node"; chmod +x "$SB2/sbin/node"   # skip the auth probe
printf 'l1\nl2\nl3\nl4\nl5\n' > "$SB2/transcripts/g1.txt"
printf 'l1\nl2\nl3\n' > "$SB2/transcripts/g2.txt"
printf 'l1\nl2\nl3\n' > "$SB2/transcripts/g3.txt"   # X2#1: dead (0,2], then ok (2,3]: done, 2 dead lines
printf '%s\n' \
  '{"basename":"g1.txt","ts":"2026-06-17T00:00:00Z","outcome":"ok","from":0,"lines":3}' \
  '{"basename":"g2.txt","ts":"2026-06-17T00:00:00Z","outcome":"ok","from":0,"lines":3}' \
  '{"basename":"g3.txt","ts":"2026-06-17T00:00:00Z","outcome":"error","from":0,"lines":2,"fails":3}' \
  '{"basename":"g3.txt","ts":"2026-06-17T00:00:00Z","outcome":"ok","from":2,"lines":3}' > "$SB2/.extraction-state.jsonl"
SO=$(env PATH="$SB2/sbin:$PATH" BRAIN_DIR="$SB2" KNOWLEDGE_DIR="$SB2/k" bash "$SNAP" "$ROOT" 2>/dev/null)
printf '%s' "$SO" | grep -q 'backlog: 1 pending of 3 archived' \
  && pass "S1: snapshot backlog counts the grown archive as pending" \
  || fail "S1: snapshot backlog wrong (got: $(printf '%s' "$SO" | grep 'backlog:'))"
printf '%s' "$SO" | grep -q 'dead-lettered windows: 1 (2 lines) in 1 archive' && printf '%s\n' "$SO" | grep -q 'dead-letters=1$' \
  && pass "S1b: snapshot surfaces a dead window under the cursor" \
  || fail "S1b: snapshot hid the dead window (got: $(printf '%s' "$SO" | grep -E 'backlog:|dead-letters='))"

echo "=== cursor-map failure is never 'nothing pending' (R2 fix X2#2) ==="
# A jq shim on PATH fails ONLY the cursor-map program (the one jq program that defines `epoch`)
# and passes every other jq call through, so what fails is the map and nothing else. Each reader
# must say the map failed instead of rendering zeros ("nothing pending, health ok").
JQS="$B/jqshim"; mkdir -p "$JQS"
REALJQ=$(command -v jq)
printf '#!/bin/bash\ncase "$*" in *"def epoch"*) exit 5 ;; esac\nexec "%s" "$@"\n' "$REALJQ" > "$JQS/jq"; chmod +x "$JQS/jq"
reset; mkdir -p "$B/transcripts"; printf -- '--- session-meta ---\n---\nUSER: x\n' > "$B/transcripts/m1.txt"
O=$(printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' | env PATH="$JQS:$PATH" BRAIN_DIR="$B" HOME="$B" bash "$SL" 2>/dev/null)
printf '%s' "$O" | grep -q "$BANNER" && printf '%s' "$O" | grep -q 'cursor map failed' \
  && pass "M1: a failed cursor map fires the drain-health banner and names the map" \
  || fail "M1: a failed cursor map read as nothing pending (got: $(printf '%s' "$O" | grep -A2 "$BANNER" | head -c 300))"
rm -f "$B/transcripts/m1.txt"
MF=$( sb_drain_cursor_map() { return 1; }; sb_count_drain_dead_letters; echo "rc=$?" )
[ "$MF" = "?"$'\n'"rc=1" ] && pass "M2: sb_count_drain_dead_letters prints ? and returns 1 on a map failure" \
  || fail "M2: dead-letter counter hid the map failure (got: $MF)"
CO=$(printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' \
  | env PATH="$JQS:$CB/sbin:$PATH" ANTHROPIC_API_KEY="" BRAIN_DIR="$CB" HOME="$CB" bash "$SL" 2>/dev/null)
printf '%s' "$CO" | grep -q 'capture: 1 archived · ? extracted' \
  && pass "M3: the capture line shows ? extracted on a map failure, not 0" \
  || fail "M3: capture line hid the map failure (got: $(printf '%s' "$CO" | grep -i 'second-brain.*capture' | head -c 200))"
SO=$(env PATH="$JQS:$SB2/sbin:$PATH" BRAIN_DIR="$SB2" KNOWLEDGE_DIR="$SB2/k" bash "$SNAP" "$ROOT" 2>/dev/null)
printf '%s' "$SO" | grep -q 'backlog: ? (cursor map failed' \
  && pass "M4: the snapshot backlog says the cursor map failed" \
  || fail "M4: snapshot backlog hid the map failure (got: $(printf '%s' "$SO" | grep 'backlog:'))"
# M5: the drainer records a map failure as extractor status=fail, reason "cursor map unavailable".
# That is jq / lib.sh trouble, not auth: the FAILED banner's hint must point there, never at
# /login or an API key (the default hint did).
reset
printf '%s\n' '{"status":"fail","backend":"claude-cli","checked_at":"2026-10-06T00:00:00Z","reason":"cursor map unavailable: drain accounting failed (drained 0, 0 failed this run; see error-log.jsonl)"}' > "$B/.extractor-health.json"
O=$(emit)
M5H=$(printf '%s\n' "$O" | grep -A5 'extractor: FAILED' | grep -E '^(fix|cause):' | head -1)
case "$M5H" in *jq*) M5J=1 ;; *) M5J="" ;; esac
case "$M5H" in *lib.sh*) M5L=1 ;; *) M5L="" ;; esac
case "$M5H" in *error-log*) M5E=1 ;; *) M5E="" ;; esac
case "$M5H" in *"/login"*|*ANTHROPIC_API_KEY*) M5A=1 ;; *) M5A="" ;; esac
if [ -n "$M5A" ]; then fail "M5: the cursor-map hint still sends the user to /login or an API key (got: $M5H)"
elif [ -n "$M5J" ] && [ -n "$M5L" ] && [ -n "$M5E" ]; then pass "M5: the cursor-map FAILED hint names jq, lib.sh and the error log, not /login"
else fail "M5: the cursor-map FAILED hint does not name jq / lib.sh / error-log (got: ${M5H:-no hint line})"; fi
rm -f "$B/.extractor-health.json"

echo "=== archive scrub hold (X2#3) ==="
# The one-time secret-scrub migration holds an archive from extraction until it is scrubbed. One
# whose scrub failed 3+ times (an attempt per migration run) is surfaced; fewer attempts are not.
reset; rm -f "$B/.archive-scrub-v1"
printf 'transcripts/h1.txt\t3\ntranscripts/h2.txt\t1\ndreams/d1/transcripts/h3.txt\t0\n' > "$B/.archive-scrub-v1.todo"
O=$(emit)
printf '%s' "$O" | grep -q "$BANNER" && printf '%s' "$O" | grep -q '1 archive(s) held from extraction: their secret scrub failed 3+ times' \
  && pass "H1: an archive whose scrub failed 3+ times is surfaced" || fail "H1: scrub hold not surfaced (got: $(printf '%s' "$O" | grep 'signal:' | head -c 300))"
printf 'transcripts/h1.txt\t2\n' > "$B/.archive-scrub-v1.todo"
O=$(emit)
printf '%s' "$O" | grep -q 'secret scrub failed' && fail "H2: a scrub under 3 attempts fired the banner" || pass "H2: fewer than 3 attempts stay quiet"
rm -f "$B/.archive-scrub-v1.todo"
printf 'transcripts/s1.txt\t4\ntranscripts/s2.txt\t0\n' > "$SB2/.archive-scrub-v1.todo"
SO=$(env PATH="$SB2/sbin:$PATH" BRAIN_DIR="$SB2" KNOWLEDGE_DIR="$SB2/k" bash "$SNAP" "$ROOT" 2>/dev/null)
printf '%s' "$SO" | grep -q 'archive scrub: 2 file(s) still to scrub (1 failed 3+ attempts' \
  && pass "H3: the snapshot shows the scrub to-do count and the stuck ones" || fail "H3: snapshot scrub line (got: $(printf '%s' "$SO" | grep 'archive scrub'))"
rm -f "$SB2/.archive-scrub-v1.todo"; : > "$SB2/.archive-scrub-v1"
SO=$(env PATH="$SB2/sbin:$PATH" BRAIN_DIR="$SB2" KNOWLEDGE_DIR="$SB2/k" bash "$SNAP" "$ROOT" 2>/dev/null)
printf '%s' "$SO" | grep -q 'archive scrub: done' && pass "H4: the snapshot shows a finished migration" || fail "H4: snapshot scrub line (got: $(printf '%s' "$SO" | grep 'archive scrub'))"
rm -f "$SB2/.archive-scrub-v1"

echo "=== archive scrub without a drainer (0.56.0 integration, item 3) ==="
# The one-time scrub normally runs on drainer ticks, but the drainer timer is opt-in and absent on
# some installs. Until the marker exists, every start forks the same routine detached
# (extract-drain.sh --scrub-only, under the drain lock, skipped while it is held). Cap 2 per run;
# k0 (the oldest: picked first) has a live per-archive lock during run 1, so that run waits ~5 s
# on it. SessionStart must have returned while that run still waits (ordering, not seconds).
S3="$B/nodrainer"; mkdir -p "$S3/transcripts"; cp "$B/config.json" "$S3/"
K3="sk-""ant-api03-$(printf 'Zq9x%.0s' 1 2 3 4 5 6 7 8)"   # built at run time: no key-shaped literal in the repo
for i in 0 1 2; do
  printf -- '--- session-meta ---\nsession_id: k%s\n---\nUSER: my key is %s\nASSISTANT: ok\n' "$i" "$K3" > "$S3/transcripts/k${i}_proj_2026-05-24.txt"
  touch -t "20260524000$i" "$S3/transcripts/k${i}_proj_2026-05-24.txt"
done
# A `bash` spy on PATH counts the forked runs (a run after the marker writes nothing to observe).
mkdir -p "$S3/spy"; REALBASH=$(command -v bash)
printf '#!/bin/bash\ncase " $* " in *" --scrub-only "*) printf "fork\\n" >> "%s" ;; esac\nexec "%s" "$@"\n' "$S3/spy.log" "$REALBASH" > "$S3/spy/bash"
chmod +x "$S3/spy/bash"
s3_forks(){ grep -c . "$S3/spy.log" 2>/dev/null || echo 0; }
# stdout AND stderr go to a pipe read to EOF, as the hook runner reads them: a forked run that kept
# either open would hold SessionStart until it ended.
emit3(){ local o; o=$(printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' | env BRAIN_DIR="$S3" HOME="$S3" PATH="$S3/spy:$PATH" SB_SCRUB_MIGRATE_MAX_FILES=2 bash "$SL" 2>&1 8>&-); }
wait_for(){ local end=$((SECONDS + $1)); shift; until "$@"; do [ "$SECONDS" -ge "$end" ] && return 1; sleep 0.2; done; }
s3_ticks(){ [ "$(grep -c "\"rule\":\"drain-tick\",\"target\":\"$1\"" "$S3/audit-log.jsonl" 2>/dev/null)" -ge "$2" ]; }   # sb_drain_tick rows
s3_keys(){ grep -lF 'sk-ant-' "$S3"/transcripts/k*_proj_2026-05-24.txt 2>/dev/null | sed 's#.*/##; s#_proj.*##' | tr '\n' ' '; }
# N1: the drain lock is held (a drainer run): the start's run skips, touching nothing
if command -v flock >/dev/null 2>&1; then exec 8>"$S3/.extract-drain.lock"; flock -n 8; else mkdir "$S3/.extract-drain.lock.d"; fi
emit3
wait_for 60 s3_ticks lock-held 1 && [ ! -f "$S3/.archive-scrub-v1.todo" ] && [ "$(s3_keys)" = "k0 k1 k2 " ] \
  && pass "N1: with the drain lock held, the start's scrub run skips and touches nothing" \
  || fail "N1: lock-held skip (ticks: $(grep -c drain-tick "$S3/audit-log.jsonl" 2>/dev/null), keys left: $(s3_keys))"
if command -v flock >/dev/null 2>&1; then exec 8>&-; else rmdir "$S3/.extract-drain.lock.d"; fi
# N2: run 1 starts after SessionStart returned and finishes on its own
printf '1\n' > "$S3/transcripts/.k0_proj_2026-05-24.txt.lock"
emit3
N2_EARLY="$(grep -c "$(printf '\t1$')" "$S3/.archive-scrub-v1.todo" 2>/dev/null) $(s3_keys)"
[ "$N2_EARLY" = "0 k0 k1 k2 " ] || [ "$N2_EARLY" = " k0 k1 k2 " ] \
  && pass "N2: SessionStart returned while its scrub run was still waiting on k0's lock" \
  || fail "N2: SessionStart waited for its scrub run (state on return: $N2_EARLY)"
wait_for 60 s3_ticks archive-scrub 1 && [ "$(s3_keys)" = "k0 k2 " ] \
  && grep -qx "$(printf 'transcripts/k0_proj_2026-05-24.txt\t1')" "$S3/.archive-scrub-v1.todo" \
  && pass "N2: run 1 scrubbed its cap (k0 failed on the held lock, k1 scrubbed) and listed the rest" \
  || fail "N2: run 1 (keys left: $(s3_keys); list: $(tr '\t\n' ': ' < "$S3/.archive-scrub-v1.todo" 2>/dev/null))"
rm -f "$S3/transcripts/.k0_proj_2026-05-24.txt.lock"
# N3: the next start resumes (cap 2: k2, then k0 once its lock is gone) and writes the marker;
# after it, no start forks a run any more
emit3; wait_for 60 s3_ticks archive-scrub 2
[ -f "$S3/.archive-scrub-v1" ] && [ ! -f "$S3/.archive-scrub-v1.todo" ] && [ -z "$(s3_keys)" ] \
  && pass "N3: with no drainer, session starts scrub every candidate and write the marker" \
  || fail "N3: migration incomplete (keys left: $(s3_keys); marker: $([ -f "$S3/.archive-scrub-v1" ] && echo yes || echo no))"
[ ! -e "$S3/.extraction-state.jsonl" ] && [ ! -e "$S3/.extractor-health.json" ] \
  && pass "N3: the start runs write no drainer progress (done-set, extractor health: the loop-dead / dead-man clocks)" \
  || fail "N3: a scrub-only run wrote drainer progress files"
grep -q 'background archive scrub' "$S3/error-log.jsonl" 2>/dev/null \
  && fail "N3: a start's scrub run failed ($(grep 'background archive scrub' "$S3/error-log.jsonl" | head -c 300))" \
  || pass "N3: no start's scrub run failed"
N3_FORKS=$(s3_forks)
emit3; sleep 2
[ "$N3_FORKS" = 3 ] && [ "$(s3_forks)" = 3 ] && pass "N3: one fork per start until the marker, none after it" \
  || fail "N3: forks per start wrong (3 starts before the marker: $N3_FORKS; after one more: $(s3_forks))"

echo "=== drainer dead-man switch ==="
# Fires on SILENCE (stale progress + newer queued work) — the state no failure-
# signature banner can see: the 2026-07 lock wedge left ZERO log lines for six
# days while the scheduler exited 0 and 17 queued transcripts were evicted.
DM='drainer DEAD-MAN'

# D1: stale state + newer queued transcript → dead-man fires
reset; mkdir -p "$B/transcripts"
: > "$B/.extraction-state.jsonl"; touch -t 202601010000 "$B/.extraction-state.jsonl"
printf 'x' > "$B/transcripts/fresh_claude-code-plugin_2026-07-30.txt"
O=$(emit)
printf '%s' "$O" | grep -q "$DM" && pass "D1: stale progress + newer queue fires dead-man" || fail "D1: dead-man did not fire"
# D173: this is a trace signal (also user-visible via the banner above), not a hook
# failure — gate=/ec0 routes it to audit-log, and it must NOT also land in error-log
# (that channel is reserved for real failures; drain-deadman was 27% of it before D173).
grep -q "gate=drain-deadman" "$B/audit-log.jsonl" 2>/dev/null && pass "D1b: dead-man logged to audit-log (trace)" || fail "D1b: no audit-log entry"
grep -q "drain-deadman" "$B/error-log.jsonl" 2>/dev/null && fail "D1b: dead-man trace leaked into error-log" || pass "D1c: dead-man does not pollute error-log"

# D2: stale state, NO newer transcripts (idle machine) → silent (false-positive guard)
reset; rm -f "$B/transcripts"/*.txt
: > "$B/.extraction-state.jsonl"; touch -t 202601010000 "$B/.extraction-state.jsonl"
O=$(emit)
printf '%s' "$O" | grep -q "$DM" && fail "D2: dead-man false-fired on an idle machine" || pass "D2: staleness alone stays silent (no queued work = no drain expected)"

# D3: fresh state + queued transcript → silent (drainer is alive)
reset; : > "$B/.extraction-state.jsonl"
printf 'x' > "$B/transcripts/fresh2_claude-code-plugin_2026-07-30.txt"
O=$(emit)
printf '%s' "$O" | grep -q "$DM" && fail "D3: dead-man fired though progress is fresh" || pass "D3: fresh progress stays silent"

# D4: kill switch
reset; : > "$B/.extraction-state.jsonl"; touch -t 202601010000 "$B/.extraction-state.jsonl"
printf 'x' > "$B/transcripts/fresh3_claude-code-plugin_2026-07-30.txt"
O=$(SB_DRAIN_DEADMAN=off emit)
printf '%s' "$O" | grep -q "$DM" && fail "D4: kill switch ignored" || pass "D4: SB_DRAIN_DEADMAN=off suppresses"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
