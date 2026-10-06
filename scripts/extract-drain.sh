#!/bin/bash
# extract-drain.sh — out-of-band extraction drainer. Processes archived
# transcripts that were skipped by the in-session extractor (OAuth recursive
# lock). Run by a systemd user timer, OUTSIDE any Claude session.
#
#   SB_DRAIN_BATCH      extractor calls per run (default 5): one forward chunk per call, and a
#                       failed attempt takes a slot too
#   SB_DRAIN_MAX_FAILS  retries before a window is dead-lettered (default 3)
#   SB_DRAIN_QUIET_S    an archive quiet this long (mtime) is settled (default 3600)
#   SB_DRAIN_DELTA_MIN_BYTES  a LIVE archive is extracted once this much is new (default 4096)
#   SB_DRAIN_MIN_BYTES  a settled, never-extracted archive smaller than this is marked done without an LLM call
#                       (too-small, default 1024)
#   SB_SCRUB_MIGRATE_MAX_FILES  one-time archive scrub: files per run (default 50)
#   SB_SCRUB_MIGRATE_MAX_S      one-time archive scrub: no new scrub starts past this many seconds of a
#                               run (default 20; one scrub always runs)
#   SB_EXTRACT_STUB     test-only: path to a stub called instead of the real extractor, as
#                       `$SB_EXTRACT_STUB <txt> <slug> <from> <to>` (archive lines (from, to]).
# Exits 0 on every out-of-session path (fail-soft for the scheduler). Exits 3 ONLY when run
# INSIDE a Claude Code session (CLAUDECODE=1) — that refusal used to exit 0 and read as success.
set -u
source "$(dirname "$0")/lib.sh"

# Defer if an interactive claude session is active for this uid. The recursive-
# claude OAuth lock is GLOBAL (held by any live interactive session), so a
# `claude -p` extraction would hang on the timeout — and worse, spawn a full
# recursive claude per attempt and bump the poison-pill counter on a transcript
# that is actually fine. So we skip cleanly (no attempt, no retry, no spawn) and
# let the next timer fire retry during an idle window. Detection: a `claude`
# process (this uid) whose args lack `-p` (the -p ones are our own extractor /
# other print-mode calls). SB_INTERACTIVE_OVERRIDE forces the verdict for tests.
# Portable args read: `ps -p <pid> -o args=` works on Linux/macOS/Git-Bash (no /proc,
# which is Linux-only). Returns the full command line for the pid.
sb_drain_proc_args() { ps -p "$1" -o args= 2>/dev/null; }

# Windows/MSYS liveness probe. The POSIX fallback below (`ps -e -o args=`) is a GNU-ism that
# MSYS ps REJECTS outright ("ps: unknown option -- o", verified live on Git-Bash), so the
# heredoc it feeds is EMPTY and the defer guard silently answers "no interactive session" on
# the PRIMARY dev platform — fail-open, and the exact condition the guard exists to prevent
# (a `claude -p` spawned under the global OAuth recursive lock hangs to its timeout and
# poison-pills good transcripts). MSYS `ps -W` DOES enumerate native Windows processes; it
# prints the exe PATH with no args, which is enough to spot a live Claude Code CLI.
# Match claude.exe specifically — the Claude DESKTOP app (…\WindowsApps\Claude_*\…) is a
# different program and must not pin the drainer into a permanent defer.
sb_drain_win_claude_present() {
  command -v uname >/dev/null 2>&1 || return 1
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) : ;; *) return 1 ;; esac
  # Match ONLY the Claude Code CLI (installed under ~/.local/bin, npm-global bin, or a
  # node_modules/.bin), never Claude DESKTOP: the desktop app is
  # `WindowsApps\Claude_<ver>_x64__<hash>\app\claude.exe` and is always running on a desk
  # where it is installed — the previous pattern `[/\\]claude\.exe` matched its 9 processes,
  # so this probe returned "interactive CLI present" on 100% of scheduler ticks with NO CLI
  # session open. Measured 2026-08-23: `ps -W` showed 9 desktop + 2 CLI claude.exe rows; the
  # drainer deferred on every tick and only ever drained via the every-6th-tick escape.
  # The test fixture (test-drain-defer-windows.sh W4) used `cowork-svc.exe` — a name the
  # desktop app never spawns — so the exclusion it "proved" was never exercised.
  ps -W 2>/dev/null | grep -viE '[/\\]WindowsApps[/\\]' | grep -qiE '[/\\]claude\.exe([[:space:]]|$)'
}

# Relaxed verdict (opt-in, SB_DRAIN_DEFER_PMODE_ONLY=1): defer ONLY when ANOTHER
# live `claude -p` is present (a concurrent extractor / print-mode call that
# genuinely contends for the recursive-claude path). A plain interactive session
# is ignored because the bounded extractor cannot hang on it. Mirrors
# sb_drain_should_defer's pgrep||ps structure EXACTLY (cross-OS), inverting only
# the -p test (present -> defer, instead of absent -> defer).
sb_drain_pmode_present() {
  case "${SB_INTERACTIVE_OVERRIDE:-}" in active) return 0 ;; inactive) return 1 ;; esac
  local p args
  if command -v pgrep >/dev/null 2>&1; then
    for p in $(pgrep -u "$(id -u)" -x claude 2>/dev/null); do
      args=$(sb_drain_proc_args "$p")
      case " $args " in *" -p "*) return 0 ;; esac
    done
  else
    while IFS= read -r args; do
      [ -n "$args" ] || continue
      case " $args " in *" -p "*) return 0 ;; esac
    done <<EOF
$(ps -e -o args= 2>/dev/null | grep -iE '(^|[ /\\])claude([ "]|\.exe|$)')
EOF
  fi
  return 1
}

sb_drain_should_defer() {
  case "${SB_INTERACTIVE_OVERRIDE:-}" in
    active)   return 0 ;;
    inactive) return 1 ;;
  esac
  local p args
  if command -v pgrep >/dev/null 2>&1; then
    for p in $(pgrep -u "$(id -u)" -x claude 2>/dev/null); do
      args=$(sb_drain_proc_args "$p")
      case " $args " in
        *" -p "*) : ;;   # print-mode (our extractor or similar) — ignore
        *) return 0 ;;   # interactive session present → defer
      esac
    done
  else
    # Windows first: ps -W is the ONLY probe that sees native Claude processes here, and the
    # POSIX form below cannot even parse. It carries no args, so any live claude.exe defers —
    # conservative by design (the un-starve escape still releases a genuinely starved queue).
    if sb_drain_win_claude_present; then return 0; fi
    # No pgrep (some Git-Bash) — best-effort ps scan: defer on any interactive claude
    # found; if ps yields nothing, proceed (fail-open, same posture as the /proc path).
    while IFS= read -r args; do
      [ -n "$args" ] || continue
      case " $args " in *" -p "*) : ;; *) return 0 ;; esac
    done <<EOF
$(ps -e -o args= 2>/dev/null | grep -iE '(^|[ /\\])claude([ "]|\.exe|$)')
EOF
  fi
  return 1
}

# --- Persisted consecutive-defer counter (un-starve, root cause #1) -------
# An always-on interactive operator makes sb_drain_should_defer return 0 on
# EVERY timer fire, so the backlog never drains. The extractor is provably
# BOUNDED (SB_DRAIN_EXTRACT_TIMEOUT x backend + MAX_FAILS poison-pill — see
# lib.sh sb_call_extractor; CLAUDECODE is unset out-of-band so the in-session
# queue branch never fires), so a forced attempt costs at most one timeout, not
# a hang. We therefore allow ONE drain through whenever starvation crosses a
# bound. State lives in BRAIN_DIR so it survives across timer fires.
DEFER_COUNT_F="$BRAIN_DIR/.drain-defer-count"
ESCAPE_STAMP_F="$BRAIN_DIR/.last-drain-escape"
sb_drain_defer_count() {
  local n=0
  [ -f "$DEFER_COUNT_F" ] && n=$(tr -d '[:space:]' < "$DEFER_COUNT_F" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%d' "$n"
}
sb_drain_defer_bump() { printf '%d' "$(( $(sb_drain_defer_count) + 1 ))" > "$DEFER_COUNT_F" 2>/dev/null || true; }
sb_drain_defer_reset() { rm -f "$DEFER_COUNT_F" 2>/dev/null || true; }

# EVERY exit of a drainer tick leaves ONE audit row: gate=drain-tick verdict=<why>. Under the
# scheduler (wscript //B on Windows, systemd/launchd elsewhere) stderr goes nowhere, so the
# `exit 0` paths below used to leave no trace at all: the 3-day 2026-08 starvation and the
# 6-day 2026-07 lock wedge (see the mkdir-lock comment) both ran "green" with zero log rows.
# One verdict row per tick is what lets the next audit answer "did it run, what did it decide".
sb_drain_tick() {  # $1 = verdict, $2 = detail
  sb_log_audit "extract-drain.sh" "flag" "drain-tick" "${1:-?}" "${2:-}" "" 2>/dev/null || true
}

# Age (seconds) of the OLDEST archive still holding unextracted, not-dead-lettered lines; 0 if
# none. Reads DRAIN_MAP (one sb_drain_cursor_map per tick: oldest-first, mtime included), so there
# is no per-file stat or done-set scan here.
sb_drain_oldest_pending_age() {
  sb_drain_map_counts "${DRAIN_MAP:-}"
  [ "$SB_DM_OLDEST_PENDING_MTIME" -gt 0 ] || { printf '0'; return; }
  local age=$(( $(date +%s) - SB_DM_OLDEST_PENDING_MTIME ))
  [ "$age" -lt 0 ] && age=0
  printf '%d' "$age"
}

# The forced escape is SAFE because every attempt is TIME-BOUNDED: with ANTHROPIC_API_KEY the
# curl backstop self-bounds via --max-time; without it sb_call_extractor wraps `claude -p` in
# sb_timeout (lib.sh), which refuses loudly rather than run unbounded when no timeout binary
# exists. A hung attempt therefore costs one timeout and records `retry`; only
# SB_DRAIN_MAX_FAILS (3) consecutive failures dead-letter a transcript. That bound is the whole
# safety argument — there is no longer an opt-in flag gating the escape (see the history note
# inside the function for why the old gate was the 3-day outage).
sb_drain_escape_safe() {
  [ -n "${ANTHROPIC_API_KEY:-}" ] && return 0
  # No API key: the attempt runs through `claude -p`, so it MUST be time-bounded — that bound
  # is the whole safety story, and it is sufficient. Requiring SB_DRAIN_DEFER_PMODE_ONLY=1 here
  # (default 0) made the escape UNREACHABLE on the most common setup — subscription auth with an
  # editor session open — so the drainer deferred forever and the pipeline silently died:
  # measured 2026-08-22 on the dev box at 120 consecutive defers, 72/100 transcripts never
  # mined, 3 days since the last successful drain, while the scheduled task ran every 30 min
  # and exited 0. The premise of that gate ("a forced `claude -p` hangs to the timeout and
  # poison-pills good transcripts under a held OAuth lock") was tested directly with an
  # interactive session live: it drained cleanly in seconds, backend claude-cli, 0 failed.
  # Worst case is bounded anyway — a hang costs one timeout and records `retry`, and only
  # SB_DRAIN_MAX_FAILS (3) consecutive failures dead-letter a transcript.
  # To suppress escapes without this gate: raise SB_DRAIN_DEFER_MAX / SB_DRAIN_STALE_MAX.
  # The former `command -v timeout || gtimeout` requirement is gone too: sb_call_extractor now
  # bounds claude via sb_timeout (lib.sh), which FAILS LOUD (exit 127 + error-log) when no
  # timeout binary exists rather than running claude unbounded. So on stock macOS an escape
  # attempt records `retry` with a logged reason instead of deferring forever in silence.
  return 0
}

# Should we let ONE drain escape the defer despite a live interactive session? Only when the
# escape is safe (above) AND consecutive defers crossed SB_DRAIN_DEFER_MAX (default 6) OR the
# oldest pending transcript is older than SB_DRAIN_STALE_MAX (default 86400s).
sb_drain_starved() {
  sb_drain_escape_safe || return 1
  local dmax="${SB_DRAIN_DEFER_MAX:-6}";  case "$dmax"  in ''|*[!0-9]*) dmax=6 ;; esac
  local smax="${SB_DRAIN_STALE_MAX:-86400}"; case "$smax" in ''|*[!0-9]*) smax=86400 ;; esac
  # Counter branch: N consecutive defers crossed the bound → escape (self-resets via the
  # counter; deliberately does NOT stamp the age cooldown).
  [ "$(sb_drain_defer_count)" -ge "$dmax" ] && return 0
  # Age branch: oldest pending transcript older than smax, rate-limited to once per
  # SB_DRAIN_ESCAPE_COOLDOWN (default smax). The cooldown is stamped HERE, only on an
  # age-driven escape — so a counter escape can't suppress the next legitimate age escape.
  if [ "$(sb_drain_oldest_pending_age)" -gt "$smax" ]; then
    local cd="${SB_DRAIN_ESCAPE_COOLDOWN:-$smax}"; case "$cd" in ''|*[!0-9]*) cd="$smax" ;; esac
    local last=0
    [ -f "$ESCAPE_STAMP_F" ] && last=$(sb_mtime "$ESCAPE_STAMP_F")
    if [ "$(( $(date +%s) - ${last:-0} ))" -gt "$cd" ]; then
      touch "$ESCAPE_STAMP_F" 2>/dev/null || true
      return 0
    fi
  fi
  return 1
}

# The whole point is to run outside a session — refuse the recursive-lock context.
if [ "${CLAUDECODE:-}" = "1" ]; then
  # Exit 3, NOT 0. A hand-run from inside a session (which is exactly what the dead-man banner
  # used to tell operators to do) printed this line and exited 0 — indistinguishable from
  # "drained fine" to any caller or eyeball, so a dead pipeline read as healthy. The scheduler
  # runs out-of-session and never reaches this branch, so nothing legitimate regresses.
  echo "extract-drain: refusing to run inside a Claude Code session (nothing was drained)" >&2
  echo "  run it from a plain shell, or let the scheduled task do it." >&2
  exit 3
fi

# Defer (don't fail) while an interactive session is live — UNLESS the backlog
# has starved past a bound, in which case we let exactly ONE drain through. The
# extractor is bounded (timeout x backend + poison-pill), so a forced attempt is
# safe under either premise: at worst it spends one SB_DRAIN_EXTRACT_TIMEOUT and
# at most one poison-retry per starved transcript — never an unbounded hang.
# SB_DRAIN_DEFER_PMODE_ONLY=1 additionally relaxes the BASE verdict to defer only
# on another live `claude -p` (verified-false hang premise; off by default so the
# empty-output quality guard for plain interactive sessions is preserved).
# LOCK FIRST, decide second. The single-flight lock used to sit AFTER the defer/escape block,
# so a tick that lost the lock had already stamped .last-drain-escape and reset the defer
# counter — an escape burned with nothing drained (observed live 2026-08-23 09:26:23 while a
# hand-run held the lock: 24h cooldown consumed, counter reset, tick exited 0, no log row).
TX_DIR="$BRAIN_DIR/transcripts"
[ -d "$TX_DIR" ] || { sb_drain_tick no-transcripts-dir "$TX_DIR"; exit 0; }
# Single-flight: a slow run must not overlap the next timer fire. Prefer flock
# (auto-releases on exit); fall back to an atomic mkdir-lock (stock macOS / Git-Bash
# have no flock(1)) with a staleness steal so a crashed run can't block forever.
if [ "${SB_DRAIN_FORCE_MKDIR_LOCK:-0}" != "1" ] && command -v flock >/dev/null 2>&1; then
  exec 9>"$BRAIN_DIR/.extract-drain.lock" || { sb_drain_tick lock-open-failed "$BRAIN_DIR/.extract-drain.lock"; exit 0; }
  flock -n 9 || { sb_drain_tick lock-held "flock: another run is active"; exit 0; }
else
  LOCK_DIR="$BRAIN_DIR/.extract-drain.lock.d"
  # 7200s staleness (deep-review): the 120s drainer timeout makes a worst-case
  # fully-degraded batch (5 x direct+pty+API retries) approach the old 1800s
  # threshold, which equals the scheduler interval — a live run could be judged
  # stale and its lock stolen, re-opening the overlap race the lock prevents.
  STALE="${SB_DRAIN_LOCK_STALE:-7200}"; case "$STALE" in ''|*[!0-9]*) STALE=7200 ;; esac
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    lmtime=$(sb_mtime "$LOCK_DIR")
    lage=$(( $(date +%s) - ${lmtime:-0} ))
    if [ "$lage" -gt "$STALE" ]; then
      # Steal a stale lock, but guard the steal race: if two runs both steal, each
      # clear+mkdir can "succeed", so write our PID and read it back — only the last
      # writer owns it; the other exits. (Bounded anyway: schedulers fire one/interval.)
      # rm -rf, NOT rmdir: the steal path itself writes $LOCK_DIR/pid, so a run killed
      # after that point leaves the dir NON-EMPTY — rmdir then fails forever, mkdir
      # fails, and every future run exits 0 while the queue ages past the eviction cap
      # (the 2026-07 six-day wedge: scheduler green 48x/day, 17 transcripts lost).
      rm -rf "$LOCK_DIR" 2>/dev/null; mkdir "$LOCK_DIR" 2>/dev/null || { sb_drain_tick lock-steal-failed "mkdir after stale clear"; exit 0; }
      echo "$$" > "$LOCK_DIR/pid" 2>/dev/null
      [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] || { sb_drain_tick lock-steal-lost "another stealer won"; exit 0; }
    else
      sb_drain_tick lock-held "mkdir-lock age ${lage}s < stale ${STALE}s"; exit 0
    fi
  fi
  trap 'rm -f "$LOCK_DIR/pid" 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
  # D116: brain-os-run.sh runs INSIDE this lock (see its call sites below) and its
  # embed-warm/codemap passes were previously unbounded — able to run past $STALE and
  # get this still-live lock stolen by the next tick, whose cleanup trap then removes
  # the STEALER's lock too, letting a THIRD tick in. Hand it the absolute deadline (this
  # mkdir just set the lock's mtime to "now", steal or fresh) minus a safety margin for
  # the batch/consolidation work that runs before it, so its passes self-bound to
  # whatever's left of the staleness budget instead of running unbounded.
  export SB_BRAIN_OS_DEADLINE=$(( $(date +%s) + STALE - 300 ))
fi

# --- R2 drain accounting (0.56.0): line cursors, not a basename set --------------------------
# The done-set rows carry archive_line windows (R2 contract in lib.sh). sb_drain_cursor_map is the
# ONE reader: one wc -l + one stat + one jq per call, never a per-archive loop. DRAIN_MAP holds its
# output for the tick: basename cursor lines state next fails mtime flag dead_windows dead_lines.
STATE="$BRAIN_DIR/.extraction-state.jsonl"   # TX_DIR set + checked (loudly) above the lock
now() { date -u +%FT%TZ; }
# drain_clock: DRAIN_TS (row ts) + DRAIN_NOW_S (epoch) from ONE date spawn.
drain_clock() { read -r DRAIN_TS DRAIN_NOW_S <<< "$(date -u '+%Y-%m-%dT%H:%M:%SZ %s')"; }
drain_clock
# A map failure (logged by sb_drain_cursor_map) leaves an EMPTY map, which the batch loop reads as
# "nothing pending": DRAIN_MAP_FAILED keeps that apart, so the reconcile row and the extractor
# health say the accounting failed instead of "drained 0, 0/0/0". Re-evaluated on every call.
DRAIN_MAP_FAILED=""
drain_map() {
  if DRAIN_MAP=$(sb_drain_cursor_map "$STATE" "$TX_DIR"); then DRAIN_MAP_FAILED=""
  else DRAIN_MAP=""; DRAIN_MAP_FAILED=1; fi
}
# A basename as a JSON string, builtins only (was one `jq -Rn` spawn per row written).
drain_json_str() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; DRAIN_JSON="\"$s\""; }
# drain_row OUTCOME REASON FROM LINES [TRAILING]: append one row for $base. REASON '' = none;
# TRAILING = more members, each with a leading comma. A failed append is logged loud: the window
# is then simply redone next tick (the merge dedups).
drain_row() {
  local r=""; [ -n "$2" ] && r=",\"reason\":\"$2\""
  drain_json_str "$base"
  printf '{"basename":%s,"ts":"%s","outcome":"%s"%s,"from":%s,"lines":%s%s}\n' \
    "$DRAIN_JSON" "$DRAIN_TS" "$1" "$r" "$3" "$4" "${5:-}" >> "$STATE" \
    || sb_log_error "extract-drain.sh" "done-set append failed ($1 $base $3..$4) — the window is redone next tick" 1
}

# --- One-time archive scrub (0.56.0, R2-F#4; per-archive holds and rotation, X2#3) ---------------
# Archives written before 0.56.0 hold secrets in clear (the appender scrubs every window since), and
# so do the transcript copies already staged in dream dirs (the dream-runner reads them). The first
# ticks scrub each one in place with sb_scrub_archive_file (atomic, mtime and line count kept,
# under the per-archive lock the Stop appender takes too), then .archive-scrub-v1 marks the
# migration done for good. LLM-free: it runs from sb_drain_migrate, under the drain lock, before
# the defer gate. A scrub is cheap (no LLM call), so a run is bounded by its own budget, not by
# SB_DRAIN_BATCH: at most SB_SCRUB_MIGRATE_MAX_FILES (50) files, and no scrub starts once the run
# has taken SB_SCRUB_MIGRATE_MAX_S (20 s, counted from the routine's start, the listing grep
# included); one scrub always runs, so every run makes progress.
# The to-do list .archive-scrub-v1.todo is a snapshot, taken by ONE grep -lE over every archive and
# every dream copy, of those holding text sb_scrub_secrets would change (_SB_SCRUB_ERE, lib.sh: the
# real formats). Not the bare literals (_SB_SCRUB_LITERALS): `sk-` alone hits every task-/disk- id,
# so that list named most archives, and a listed archive is held out of extraction and of recall
# (the episodic indexer skips it) until its scrub. The literals stay where a hit only costs a
# scrub call. Archives created later are scrubbed by the appender, and the drainer scrubs any
# archive whose literal grep hits right before extracting it (X2 S6). Format, one line per file
# still to scrub (the episodic indexer reads it to skip those archives):
#   <path relative to BRAIN_DIR>\t<failed scrub attempts>
#   path: transcripts/<name>.txt | dreams/<id>/transcripts/<name>.txt
# Each run picks up to the cap, fewest failed attempts first (a scrub that keeps failing rotates to
# the back instead of blocking the rest), then archives with lines still to extract, then list
# order; drops the scrubbed and vanished ones; counts a failed attempt (the scrub logs why); an
# entry the time bound left unattempted keeps its count. Holds are per archive: until a
# transcripts/ entry leaves the list the batch loop does not extract that archive
# (DRAIN_SCRUB_TODO), and nothing else is held. A list that cannot be read is rebuilt; an archive
# the listing grep cannot read is listed (held, retried); a listing error that names no file keeps
# the list in memory for this run only, so nothing unseen is marked scrubbed.
SCRUB_MARK="$BRAIN_DIR/.archive-scrub-v1"
SCRUB_TODO="$SCRUB_MARK.todo"
DRAIN_SCRUB_TODO=""   # transcripts/ basenames still to scrub, one per line: held from extraction
drain_scrub_migrate() {
  [ -f "$SCRUB_MARK" ] && return 0
  local t0="$SECONDS" todo="" raw="" rebuild="" persist=1 p fc l
  local cap="${SB_SCRUB_MIGRATE_MAX_FILES:-50}" max_s="${SB_SCRUB_MIGRATE_MAX_S:-20}"
  case "$cap" in ''|*[!0-9]*) cap=50 ;; esac
  [ "$cap" -ge 1 ] || cap=1
  case "$max_s" in ''|*[!0-9]*) max_s=20 ;; esac
  if [ -f "$SCRUB_TODO" ]; then
    if ! raw=$(cat "$SCRUB_TODO" 2>/dev/null); then
      sb_log_error "extract-drain.sh" "archive scrub: cannot read $SCRUB_TODO; rebuilt from the archives (attempt counts restart)" 1
      rebuild=1
    fi
  else
    rebuild=1
  fi
  if [ -n "$rebuild" ]; then
    local -a cand=()
    local out rc unread="" errf="$SCRUB_TODO.tmp.err.$$"
    for p in "$BRAIN_DIR"/transcripts/*.txt "$BRAIN_DIR"/dreams/*/transcripts/*.txt; do
      [ -f "$p" ] && cand+=("${p#"$BRAIN_DIR"/}")
    done
    raw=""
    if [ "${#cand[@]}" -gt 0 ]; then
      out=$(cd "$BRAIN_DIR" && LC_ALL=C grep -lE "${_SB_SCRUB_ERE[@]}" -- "${cand[@]}" 2>"$errf"); rc=$?
      if [ "$rc" -gt 1 ]; then
        # grep lists every match among the files it could read and names each one it could not
        # (`grep: <path>: <reason>`, GNU/BSD/MSYS alike): those are listed too. Only a name that
        # IS one of the files handed to grep counts; any other error line (or none) means the
        # listing is incomplete in a way nobody can name.
        local cl nerr=0
        cl=$'\n'$(printf '%s\n' "${cand[@]}")$'\n'
        while IFS= read -r l; do
          l="${l%$'\r'}"; [ -n "$l" ] || continue
          nerr=$((nerr + 1))
          case "$l" in "grep: "*) l="${l#grep: }"; l="${l%%: *}" ;; *) l="" ;; esac
          case "$cl" in *$'\n'"$l"$'\n'*) [ -n "$l" ] && unread="$unread$l"$'\n' && nerr=$((nerr - 1)) ;; esac
        done < "$errf"
        { [ -n "$unread" ] && [ "$nerr" -eq 0 ]; } || persist=""
        sb_log_error "extract-drain.sh" "archive scrub: the listing grep failed (rc=$rc)$( [ -n "$persist" ] && printf '; the unreadable files are listed and held' || printf '; it named no file, so the list is kept for this tick only and rebuilt next tick')" 1
      fi
      rm -f "$errf" 2>/dev/null
      raw="${out//$'\r'/}"$'\n'"$unread"
    fi
  fi
  # Normalize: every entry `path<TAB>attempts` (a bare name from a 0.56 pre-release list is a
  # transcripts/ entry). One awk (the list can hold every archive: no per-entry bash string work).
  todo=$(printf '%s\n' "$raw" | LC_ALL=C awk -F'\t' '
    { sub(/\r$/, "") } $1 == "" || ($1 in seen) { next }
    { seen[$1] = 1; p = $1; if (p !~ /\//) p = "transcripts/" p; print p "\t" (($2 ~ /^[0-9]+$/) ? $2 + 0 : 0) }')
  [ -z "$todo" ] || todo="$todo"$'\n'
  if [ -n "$todo" ] && [ -n "$persist" ] && [ -n "$rebuild" ] \
     && ! { printf '%s' "$todo" > "$SCRUB_TODO.tmp.$$" && mv -f "$SCRUB_TODO.tmp.$$" "$SCRUB_TODO"; } 2>/dev/null; then
    rm -f "$SCRUB_TODO.tmp.$$" 2>/dev/null
    sb_log_error "extract-drain.sh" "archive scrub: cannot write $SCRUB_TODO; the list is kept for this tick and rebuilt next tick" 1
  fi
  # This run's pick: fewest failed attempts, then archives with lines to extract (map order:
  # oldest first), then list order; up to the cap. A selection over a fixed-width key (awk has no
  # portable sort): one pass over the list per pick.
  local pick
  pick=$({ printf '%s\n' "$DRAIN_MAP"; printf '%s\n' '--todo--'; printf '%s' "$todo"; } \
    | LC_ALL=C awk -F'\t' -v n="$cap" '
        sec == 0 && $0 == "--todo--" { sec = 1; next }
        sec == 0 { if ($1 != "" && $4 == "pending") pq["transcripts/" $1] = ++np; next }
        $1 != "" {
          t[++nt] = $1
          key[nt] = sprintf("%09d %d %09d", $2 + 0, (($1 in pq) ? 0 : 1), (($1 in pq) ? pq[$1] : nt))
        }
        END {
          for (k = 1; k <= n; k++) {
            b = 0
            for (i = 1; i <= nt; i++) if (!(i in used) && (b == 0 || key[i] < key[b])) b = i
            if (b == 0) break
            used[b] = 1; print t[b]
          }
        }')
  local scrubbed="" failed="" tried=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # The time bound: one scrub always runs (progress), none starts past MAX_S. An entry not
    # attempted stays listed with its attempt count unchanged.
    [ "$tried" -gt 0 ] && [ $((SECONDS - t0)) -ge "$max_s" ] && break
    tried=$((tried + 1))
    if [ ! -f "$BRAIN_DIR/$p" ] || sb_scrub_archive_file "$BRAIN_DIR/$p"; then scrubbed="$scrubbed$p"$'\n'
    else failed="$failed$p"$'\n'; fi
  done < <(printf '%s\n' "$pick")
  # What is left: the list minus the scrubbed (and vanished) entries, a failed attempt counted.
  local left nleft=0 nstuck=0 c1 c2
  left=$({ printf '%s\n' "$scrubbed" '--failed--' "$failed" '--todo--'; printf '%s' "$todo"; } | LC_ALL=C awk -F'\t' '
    $0 == "--failed--" { s = 1; next } $0 == "--todo--" { s = 2; next }
    s == 0 { if ($0 != "") gone[$0] = 1; next }
    s == 1 { if ($0 != "") bad[$0] = 1; next }
    $1 != "" && !($1 in gone) { print $1 "\t" ($2 + (($1 in bad) ? 1 : 0)) }')
  [ -z "$left" ] || left="$left"$'\n'
  read -r c1 c2 <<< "$(printf '%s' "$left" | LC_ALL=C awk -F'\t' '$1 != "" { n++; if ($2 >= 3) k++ } END { print n + 0, k + 0 }')"   # <<<-bounded: two integers
  nleft="${c1:-0}"; nstuck="${c2:-0}"
  # The batch loop's holds: the transcripts/ entries still listed, as bare basenames.
  DRAIN_SCRUB_TODO=$(printf '%s' "$left" | LC_ALL=C awk -F'\t' 'substr($1, 1, 12) == "transcripts/" { print substr($1, 13) }')
  [ -z "$DRAIN_SCRUB_TODO" ] || DRAIN_SCRUB_TODO="$DRAIN_SCRUB_TODO"$'\n'
  if [ -z "$left" ] && [ -n "$persist" ]; then
    if : 2>/dev/null > "$SCRUB_MARK"; then
      rm -f "$SCRUB_TODO" 2>/dev/null
      sb_drain_tick archive-scrub "done: every archive and dream copy written before 0.56.0 is secret-scrubbed"
    else
      sb_log_error "extract-drain.sh" "archive scrub: cannot write $SCRUB_MARK; the (idempotent) migration re-runs next tick" 1
    fi
    return 0
  fi
  [ -n "$left" ] || return 0
  if [ -n "$persist" ] && ! { printf '%s' "$left" > "$SCRUB_TODO.tmp.$$" && mv -f "$SCRUB_TODO.tmp.$$" "$SCRUB_TODO"; } 2>/dev/null; then
    rm -f "$SCRUB_TODO.tmp.$$" 2>/dev/null
    sb_log_error "extract-drain.sh" "archive scrub: cannot rewrite $SCRUB_TODO; the scrubbed archives are re-checked next tick (idempotent)" 1
  fi
  sb_drain_tick archive-scrub "${nleft} file(s) still to scrub (${nstuck} failed 3+ attempts); those archives are not extracted until then"
  return 0
}

# --- First-tick migration + recreate purge (LLM-free, so it runs BEFORE the defer gate) --------
# A legacy row (no `lines`) advances nothing. sb_drain_cursor_map flags each such archive:
#   baseline    legacy ok, archive unchanged since the row (mtime <= ts, no forward slack: lines a
#               live session appended after the row must be re-mined, X2 S7): a cursor-baseline
#               row at the current line count, no LLM call;
#   legacy-dead legacy error, unchanged: an error row over the whole archive, so it stays
#               dead-lettered (never baselined: that would mark never-extracted lines done) and
#               only later growth is retried;
#   regrow      grown since: nothing here. The batch loop re-mines it chunk-forward from the
#               header end, tagged legacy-regrow (the merge dedup guards the re-read part).
# recreated (line count below its rows): the basename's rows are PURGED, so the stale cursor can
# never resurface once the new file grows past it. Not batch-bounded: it makes no LLM call, and
# a deferred tick on an always-on desk must not leave every legacy archive reading as pending.
sb_drain_migrate() {
  local b c n s nx f mt fl rows="" drop="" ndrop=0 tmp
  drain_scrub_migrate   # changes neither a line count nor an mtime: the map stays valid
  while IFS=$'\t' read -r b c n s nx f mt fl _rest; do
    case "$fl" in
      baseline)
        drain_json_str "$b"
        rows="$rows{\"basename\":$DRAIN_JSON,\"ts\":\"$DRAIN_TS\",\"outcome\":\"baseline\",\"reason\":\"cursor-baseline\",\"from\":0,\"lines\":$n}"$'\n' ;;
      legacy-dead)
        drain_json_str "$b"
        rows="$rows{\"basename\":$DRAIN_JSON,\"ts\":\"$DRAIN_TS\",\"outcome\":\"error\",\"reason\":\"legacy-dead-letter\",\"from\":0,\"lines\":$n}"$'\n' ;;
      recreated)
        drain_json_str "$b"; drop="$drop${drop:+,}$DRAIN_JSON"; ndrop=$((ndrop + 1)) ;;
    esac
  done < <(printf '%s\n' "$DRAIN_MAP")
  [ -n "$rows$drop" ] || return 1
  if [ -n "$drop" ]; then
    tmp="$STATE.tmp.$$"
    # tr -d '\r': Windows jq writes CRLF. Gated on the whole pipe (X2#9): through the pipe a jq
    # failure would otherwise pass for success and replace the ledger with nothing.
    jq -cR --argjson drop "[$drop]" 'fromjson? | select((.basename as $b | $drop | index($b)) == null)' \
      "$STATE" 2>/dev/null | tr -d '\r' > "$tmp"
    if [ "${PIPESTATUS[*]}" = "0 0" ] && mv "$tmp" "$STATE"; then
      sb_drain_tick recreated "purged the done-set rows of $ndrop archive(s) whose line count fell below their cursor"
    else
      rm -f "$tmp" 2>/dev/null
      DRAIN_PURGE_FAILED=1
      sb_log_error "extract-drain.sh" "recreate purge failed for $ndrop archive(s): skipped this tick (no re-extract loop)" 1
    fi
  fi
  if [ -n "$rows" ]; then
    printf '%s' "$rows" >> "$STATE" \
      || sb_log_error "extract-drain.sh" "migration append failed: legacy archives stay unmigrated this tick" 1
  fi
  return 0
}
DRAIN_PURGE_FAILED=""
drain_map
if sb_drain_migrate; then drain_map; fi   # an empty map still runs the scrub (it writes the marker)

if [ "${SB_DRAIN_DEFER_PMODE_ONLY:-0}" = "1" ]; then
  _sb_defer_verdict() { sb_drain_pmode_present; }
else
  _sb_defer_verdict() { sb_drain_should_defer; }
fi
if _sb_defer_verdict; then
  if sb_drain_starved; then
    sb_drain_defer_reset
    sb_drain_tick escape "interactive claude active, backlog starved — forcing ONE escape drain"
    echo "extract-drain: interactive claude active but backlog starved — forcing ONE escape drain" >&2
  else
    sb_drain_defer_bump
    sb_drain_tick defer "interactive claude session active (consecutive=$(sb_drain_defer_count))"
    echo "extract-drain: interactive claude session active — deferring (consecutive=$(sb_drain_defer_count))" >&2
    # The defer exists for ONE reason: a `claude -p` spawned while a session holds the global
    # OAuth lock hangs to its timeout. That applies to extraction and to the consolidation
    # pass — NOT to the engine's four deterministic passes (prune, upkeep, embedding warm,
    # code-map), which spawn no claude and touch no credential. Skipping those too would mean
    # an always-on operator gets NO offline processing at all: on Windows the defer now fires
    # whenever claude.exe is running, and the un-starve escape cannot release it under pure
    # OAuth. So run the LLM-free half here and defer only what actually needs the lock.
    SB_BRAIN_OS_NO_LLM=1 bash "$(dirname "$0")/brain-os-run.sh" >/dev/null 2>&1 || \
      sb_log_error "extract-drain.sh" "brain-os (LLM-free passes, deferred tick) exited nonzero" 1
    exit 0
  fi
else
  sb_drain_defer_reset
  sb_drain_tick drain "no interactive claude — normal drain"
fi

BATCH="${SB_DRAIN_BATCH:-5}"
case "$BATCH" in ''|*[!0-9]*) BATCH=5 ;; esac
MAX_FAILS="${SB_DRAIN_MAX_FAILS:-3}"
case "$MAX_FAILS" in ''|*[!0-9]*) MAX_FAILS=3 ;; esac
MAXB="${SB_EXTRACT_MAX_BYTES:-200000}";        case "$MAXB" in ''|*[!0-9]*) MAXB=200000 ;; esac
QUIET_S="${SB_DRAIN_QUIET_S:-3600}";           case "$QUIET_S" in ''|*[!0-9]*) QUIET_S=3600 ;; esac
DELTA_MIN="${SB_DRAIN_DELTA_MIN_BYTES:-4096}"; case "$DELTA_MIN" in ''|*[!0-9]*) DELTA_MIN=4096 ;; esac
# Too-small (HOOK-5): a SETTLED, never-extracted archive whose body is tiny (e.g. a 378-byte
# workflow-subagent stub) has nothing extractable. It gets an ok/too-small row covering it, without
# an LLM spawn and without taking a batch slot, and stays on disk for episodic search. A tiny tail
# AFTER extracted windows is extracted (X2 S5).
MIN_BODY="${SB_DRAIN_MIN_BYTES:-1024}";        case "$MIN_BODY" in ''|*[!0-9]*) MIN_BODY=1024 ;; esac

do_extract() {  # $1 = txt, $2 = slug, $3 = from, $4 = to (archive lines); honors the test stub
  if [ -n "${SB_EXTRACT_STUB:-}" ]; then
    "$SB_EXTRACT_STUB" "$1" "$2" "$3" "$4"
  else
    sb_extract_transcript "$1" "$2" "$3" "$4"
  fi
}

processed=0
failed=0
attempts=0
# P8 silence-latency (0.48.0): produced-at = archive mtime (from the map), captured-at = the row's
# ts. The gap is the window a session's knowledge sat captured-but-unextracted. An unknown mtime
# reports -1 (unmeasured), never the best-possible 0: the reconcile stats drop -1 rows.
sb_drain_latency_s() {
  case "$1" in ''|0|*[!0-9]*) printf '%d' -1; return ;; esac
  local l=$(( DRAIN_NOW_S - $1 )); [ "$l" -lt 0 ] && l=0
  printf '%d' "$l"
}
# Oldest-first by mtime (the map's order). A pending archive's window is (next, lines]: next skips
# dead-lettered regions. Eligible when >= DELTA_MIN bytes are new or the archive has been quiet
# QUIET_S. Extracted one forward chunk per call; every attempt, failed or not, takes a batch slot.
drain_clock
while IFS=$'\t' read -r base cur lines st next fails mt flag _rest; do
  [ -n "$base" ] || continue
  [ "$attempts" -ge "$BATCH" ] && break
  [ "$st" = "pending" ] || continue
  [ "$flag" = "recreated" ] && [ -n "$DRAIN_PURGE_FAILED" ] && continue
  # Never extract an archive still awaiting its one-time scrub (R2-F#4): the window holds secrets.
  # Held one by one (X2#3): nothing else waits for it.
  case $'\n'"$DRAIN_SCRUB_TODO" in *$'\n'"$base"$'\n'*) continue ;; esac
  tf="$TX_DIR/$base"
  case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
  win=$(sb_archive_window "$tf" "$next" "$lines" "$MAXB") || continue   # vanished since the map
  read -r _hdr wbytes cend <<< "$win"
  if [ $(( DRAIN_NOW_S - mt )) -ge "$QUIET_S" ]; then
    # too-small is for a NEVER-extracted archive (cursor 0, the 0.55 meaning: a stub with nothing
    # to mine). A short settled tail after extracted windows is often the decision that closes the
    # session: it goes to the extractor (X2 S5). An empty window (header only) is done either way.
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    if [ "$wbytes" -eq 0 ] || { [ "$cur" -eq 0 ] && [ "$wbytes" -lt "$MIN_BODY" ]; }; then
      drain_row ok too-small "$next" "$lines"
      continue
    fi
  elif [ "$wbytes" -eq 0 ] || [ "$wbytes" -lt "$DELTA_MIN" ]; then
    continue   # a live archive with a small new tail: wait for more lines, or for it to settle
  fi
  # X2 S6: the one-time migration scrubbed the archives that existed then, but a session still
  # running 0.55 hooks (no scrub) can append keys in clear after the marker. ONE literal grep per
  # archive about to be extracted; on a hit it is scrubbed in place first (sb_scrub_archive_file:
  # atomic, mtime and line count kept, under its archive lock) and the window recomputed (line
  # lengths changed). A failed scrub, or an archive the grep cannot read, is skipped this tick.
  LC_ALL=C grep -qF "${_SB_SCRUB_LITERALS[@]}" -- "$tf" 2>/dev/null; src=$?
  if [ "$src" -eq 0 ]; then
    sb_scrub_archive_file "$tf" || continue   # logged by the scrub
    win=$(sb_archive_window "$tf" "$next" "$lines" "$MAXB") || continue
    read -r _hdr wbytes cend <<< "$win"
  elif [ "$src" -gt 1 ]; then
    sb_log_error "extract-drain.sh" "cannot read $base for the pre-extraction secret check (grep rc=$src); not extracted this tick" 1
    continue
  fi
  slug=$(sb_slug_from_archived_transcript "$tf")
  [ -n "$slug" ] || slug="unknown"
  reason=""; [ "$flag" = "regrow" ] && reason="legacy-regrow"
  from="$next"
  while :; do
    attempts=$((attempts + 1))
    if do_extract "$tf" "$slug" "$from" "$cend" </dev/null; then
      drain_clock
      drain_row ok "$reason" "$from" "$cend" ",\"latency_s\":$(sb_drain_latency_s "$mt")"
      processed=$((processed + 1)); fails=0; from="$cend"
      { [ "$from" -lt "$lines" ] && [ "$attempts" -lt "$BATCH" ]; } || break
      win=$(sb_archive_window "$tf" "$from" "$lines" "$MAXB") || break
      read -r _hdr wbytes cend <<< "$win"
      [ "$cend" -gt "$from" ] || break
    else
      fails=$((fails + 1)); drain_clock
      if [ "$fails" -ge "$MAX_FAILS" ] && [ "${SB_DRAIN_FLOOR:-on}" != "off" ] && sb_floor_transcript "$tf" "$slug"; then
        # Last-resort deterministic floor (P1): the LLM backend has failed MAX_FAILS times on this
        # window. Rather than dead-letter a code-changing session with NOTHING captured, write the
        # files-changed baseline (no LLM; it reads the WHOLE archive, not just the window) and mark
        # the window done. Counts as a real capture (processed). Falls through to 'error' only if
        # even the floor found no file change.
        drain_row ok deterministic-floor "$from" "$cend" ",\"latency_s\":$(sb_drain_latency_s "$mt")"
        processed=$((processed + 1))
      elif [ "$fails" -ge "$MAX_FAILS" ]; then
        # Dead-letter THIS window only: the error row moves `next` past it, so later growth is
        # still extracted, but never the cursor (D177): its lines stay counted as not extracted.
        failed=$((failed + 1))
        drain_row error "" "$from" "$cend" ",\"fails\":$fails"
      else
        failed=$((failed + 1))
        drain_row retry "" "$from" "$cend" ",\"fails\":$fails"
      fi
      break
    fi
  done
done < <(printf '%s\n' "$DRAIN_MAP")

# --- GC sweeps ---
# Session-keyed extraction markers accumulate one file per session; sweep those
# untouched for 30+ days (kept past the review skill's 14-day staleness window,
# and past week-long idle sessions, per deep-review). Also sweeps legacy
# slug-keyed markers (the retired marker-key scheme).
# R2: the raw_line cursors (.last-archived-line-<slug>--<sid>, archive-first) age out the same way,
# except a session that can still resume (X2#8): a .last-archived-line-<key> whose recorded raw
# transcript path still exists is kept, with its legacy .last-extracted-line-<key> sibling;
# deleting it re-archived the resumed session from raw line 0 (a duplicate window). ONE find
# lists the stale ones, builtins read each recorded path, ONE rm.
_gc_stale=$(find "$BRAIN_DIR" -maxdepth 1 \( -name '.last-extracted-line-*' -o -name '.last-archived-line-*' \) -mtime +30 2>/dev/null)
if [ -n "$_gc_stale" ]; then
  _gc_live=$'\n'; _gc_del=()
  while IFS= read -r _gc_f; do      # pass 1: archive cursors whose raw transcript still exists
    case "${_gc_f##*/}" in .last-archived-line-*) ;; *) continue ;; esac
    _gc_p=""; IFS=$'\t' read -r _ _gc_p < "$_gc_f" 2>/dev/null; _gc_p="${_gc_p%$'\r'}"
    [ -n "$_gc_p" ] && [ -e "$_gc_p" ] && _gc_live="$_gc_live${_gc_f##*/.last-archived-line-}"$'\n'
  done < <(printf '%s\n' "$_gc_stale")
  while IFS= read -r _gc_f; do      # pass 2: delete everything else that is stale
    [ -n "$_gc_f" ] || continue
    _gc_k="${_gc_f##*/}"; _gc_k="${_gc_k#.last-archived-line-}"; _gc_k="${_gc_k#.last-extracted-line-}"
    case "$_gc_live" in *$'\n'"$_gc_k"$'\n'*) continue ;; esac
    _gc_del+=("$_gc_f")
  done < <(printf '%s\n' "$_gc_stale")
  [ "${#_gc_del[@]}" -eq 0 ] || rm -f -- "${_gc_del[@]}" 2>/dev/null \
    || sb_log_error "extract-drain.sh" "GC: cannot remove ${#_gc_del[@]} stale extraction cursor file(s) in $BRAIN_DIR" 1
fi
# Per-archive locks (sb_archive_lock, R2-F#3) left by a writer that died: the next writer steals
# one after 60 s, but an archive nobody writes again keeps its lock file. Eviction tombstones
# (.<name>.evicted, X2 S2) protect only a same-day re-creation and are consumed by the compaction
# below; a stale one (an empty ledger skips the compaction) goes too. Both after two days
# (-mtime +1). Scratch files of a hook killed mid-append (.stage-<sid>-<pid>.part) or mid-scrub
# (<archive>.txt.scrub-<pid>.part) sit outside every cap (X2#4): after a day (-mtime +0), well
# past any live writer. ONE find; a failing one is logged.
if ! find "$TX_DIR" -maxdepth 1 -type f \( \( \( -name '.*.txt.lock' -o -name '.*.txt.evicted' \) -mtime +1 \) \
       -o \( -name '*.part' -mtime +0 \) \) -delete 2>/dev/null; then
  sb_log_error "extract-drain.sh" "GC: the lock / tombstone / *.part sweep (find -delete) failed in $TX_DIR" 1
fi
# Observation ledgers (P0 rec 5): one file per session; after 7 days the
# session's transcript has been drained (or pruned past recovery) — sweep.
# Their sent-line markers (<sid>.sent, X2#5) age out with them.
find "$BRAIN_DIR/observations" -maxdepth 1 \( -name '*.jsonl' -o -name '*.sent' \) -mtime +7 -delete 2>/dev/null || true
# Transcripts of our own nested extractor spawns (cwd = BRAIN_DIR/scratch →
# one ~/.claude/projects entry). Derive the encoded name from the live BRAIN_DIR
# (CC encodes '/' and '.' as '-'); keep the substring glob as a fallback for
# default-path entries in case the encoding scheme drifts (deep-review).
SCRATCH_ENC=$(printf '%s' "$BRAIN_DIR/scratch" | sed 's|[/.]|-|g')
for pd in "$HOME/.claude/projects/$SCRATCH_ENC" "$HOME"/.claude/projects/*second-brain-scratch*; do
  [ -d "$pd" ] && find "$pd" -name '*.jsonl' -mtime +3 -delete 2>/dev/null
done
# .extraction-state.jsonl ledger GC (state hygiene), under this tick's drain lock (the ledger's
# only writer). The append-only done-set gains a row per extracted WINDOW (R2 delta drain) and
# keeps rows of archives the cap (sb_prune_transcripts) already evicted, and every SessionStart
# parses it. sb_compact_done_set (lib.sh) drops the rows of vanished archives and unparseable
# rows, and keeps, per live archive, only the rows sb_drain_cursor_map reads: lossless, its output
# is identical before and after (R2-F#10). Atomic tmp+mv; a failure leaves the ledger as it was
# and is logged.
sb_compact_done_set "$STATE" "$TX_DIR" || true

# --- P8 capture reconciliation (0.48.0): one declared-vs-observed row per tick. -----
# declared = archives on disk; observed = archives with nothing left to extract (cursor reached
# the line count, or the rest is dead-lettered); pending = the gap the next ticks must close. All
# three come from ONE sb_drain_cursor_map after the GC (R2: a grown archive is pending again; the
# old basename set called it done forever). Latency stats read the latency_s the ok rows carry.
# The AUDIT row, not the ledger, is the durable metric series: the ledger GC above drops rows
# with their pruned transcripts. Fail-soft: a stats miss degrades to zeros, never blocks the tick.
drain_map
if [ -n "$DRAIN_MAP_FAILED" ]; then
  sb_drain_tick reconcile "map=failed declared=? observed=? pending=? (sb_drain_cursor_map failed, see error-log.jsonl)"
else
  sb_drain_map_counts "$DRAIN_MAP"
  RECON_DECLARED=$SB_DM_TOTAL
  RECON_OBSERVED=$(( SB_DM_DONE + SB_DM_DEAD ))
  RECON_PENDING=$SB_DM_PENDING
  RECON_LAT="0 0 0"
  if [ -s "$STATE" ]; then
    # sampled_n distinguishes "0 0" from real all-zero latency: too-small rows and
    # -1 (unmeasured) sentinels carry no usable latency_s and are excluded here.
    RECON_LAT=$(jq -cR 'fromjson? | select(.outcome == "ok") | .latency_s // empty' "$STATE" 2>/dev/null \
      | grep -E '^[0-9]+$' | sort -n \
      | awk '{ a[NR] = $1 } END { if (NR == 0) print "0 0 0"; else print a[NR], a[int((NR + 1) / 2)], NR }')
    [ -n "$RECON_LAT" ] || RECON_LAT="0 0 0"
  fi
  RECON_MAX=$(printf '%s' "$RECON_LAT" | cut -d' ' -f1)
  RECON_P50=$(printf '%s' "$RECON_LAT" | cut -d' ' -f2)
  RECON_N=$(printf '%s' "$RECON_LAT" | cut -d' ' -f3); : "${RECON_N:=0}"
  # dead_*: every dead-lettered window, whatever the archive's state (X2#1), so a dead window
  # under the cursor stays visible in the durable metric series.
  RECON_DEAD="dead_archives=$SB_DM_DEAD_ARCHIVES dead_windows=$SB_DM_DEAD_WINDOWS dead_lines=$SB_DM_DEAD_LINES"
  sb_drain_tick reconcile "declared=$RECON_DECLARED observed=$RECON_OBSERVED pending=$RECON_PENDING oldest_pending_s=$(sb_drain_oldest_pending_age) max_latency_s=$RECON_MAX p50_latency_s=$RECON_P50 sampled_n=$RECON_N $RECON_DEAD"
fi

# Don't clobber a real failure marker: only report ok if anything succeeded.
# A run where every extraction failed must surface status=fail so the
# SessionStart banner alerts the user (otherwise a broken drainer looks healthy).
# Report the REAL backend the per-transcript extractor recorded (local | claude-cli |
# anthropic-api), not a hardcoded label; default to "drainer" if none was written.
DRAIN_BACKEND=$(jq -r '.backend // "drainer"' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null); : "${DRAIN_BACKEND:=drainer}"
if [ -n "$DRAIN_MAP_FAILED" ]; then
  sb_write_extractor_health "$DRAIN_BACKEND" "fail" "cursor map unavailable: drain accounting failed (drained $processed, $failed failed this run; see error-log.jsonl)"
elif [ "$processed" -eq 0 ] && [ "$failed" -gt 0 ]; then
  sb_write_extractor_health "$DRAIN_BACKEND" "fail" "drained 0, $failed failed this run"
else
  sb_write_extractor_health "$DRAIN_BACKEND" "ok" "drained $processed this run ($failed failed)"
fi

# Retention GC stays OUTSIDE the engine gate on purpose: pruning regenerable artifacts
# (orphaned embeddings entries, *.bak/*.tgz past retention.bak_ttl_days) must happen even when
# the offline engine is disabled, or `bak_ttl_days` goes silently inert on every install that
# turns brain_os off — the same class of bug the auto_improve gating once caused.
[ -f "$(dirname "$0")/sb-prune-archives.sh" ] && bash "$(dirname "$0")/sb-prune-archives.sh" >/dev/null 2>&1 || true

# OFFLINE ENGINE ("brain-os"): every pass that PROCESSES already-captured knowledge —
# retention pruning, deterministic upkeep, the embedding warm pass, the quarantined
# consolidation lane, code-map regen — now lives behind ONE seam instead of four inline
# blocks here. It runs inside this drainer's single-flight lock and defer guards, keeps
# each pass's own config gate, and is optional: `brain_os: false` (or SB_BRAIN_OS=off)
# disables the offline lane entirely and the plugin keeps capturing and retrieving exactly
# as before. Fail-soft here — a broken engine must never wedge the drain cycle.
bash "$(dirname "$0")/brain-os-run.sh" >/dev/null 2>&1 ||   sb_log_error "extract-drain.sh" "brain-os engine exited nonzero (drain cycle unaffected)" 1

exit 0
