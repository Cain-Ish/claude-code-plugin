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

# --- One-time archive scrub (0.56.0, R2-F#4) -----------------------------------------------------
# Archives written before 0.56.0 hold secrets in clear (the appender scrubs every window since). The
# first ticks scrub each one in place with sb_scrub_archive_file (atomic, mtime and line count
# kept, under the per-archive lock the Stop appender takes too), at most SB_DRAIN_BATCH per tick,
# PENDING archives first in the batch loop's order (the extractor reads those; a done archive can
# wait), then the rest; then .archive-scrub-v1 marks it done for good. Resumable: the to-do list
# .archive-scrub-v1.todo is a snapshot, taken on the first tick by ONE grep over every archive, of
# those holding a credential literal (_SB_SCRUB_LITERALS, lib.sh); archives created later are
# scrubbed by the appender. Each tick drops the scrubbed and vanished names; a failed scrub stays
# listed (the scrub logs why). Until an archive leaves the list the batch loop does not extract it
# (DRAIN_SCRUB_TODO), so the extractor never reads an unscrubbed window; a list that cannot be
# read or built holds every extraction for the tick (DRAIN_SCRUB_HOLD). LLM-free: it runs from
# sb_drain_migrate, under the drain lock, before the defer gate.
SCRUB_MARK="$BRAIN_DIR/.archive-scrub-v1"
SCRUB_TODO="$SCRUB_MARK.todo"
DRAIN_SCRUB_TODO=""
DRAIN_SCRUB_HOLD=""
drain_scrub_migrate() {
  [ -f "$SCRUB_MARK" ] && return 0
  local todo="" rc pick b scrubbed="" left="" nleft=0 batch="${SB_DRAIN_BATCH:-5}"
  case "$batch" in ''|*[!0-9]*) batch=5 ;; esac
  if [ -f "$SCRUB_TODO" ]; then
    if ! todo=$(cat "$SCRUB_TODO" 2>/dev/null); then
      DRAIN_SCRUB_HOLD=1
      sb_log_error "extract-drain.sh" "archive scrub: cannot read $SCRUB_TODO; nothing is extracted this tick" 1
      return 0
    fi
  else
    todo=$(cd "$TX_DIR" 2>/dev/null || exit 2
           set -- *.txt; [ -e "$1" ] || exit 1
           LC_ALL=C grep -lF "${_SB_SCRUB_LITERALS[@]}" -- "$@" 2>/dev/null)
    rc=$?
    if [ "$rc" -gt 1 ]; then
      DRAIN_SCRUB_HOLD=1
      sb_log_error "extract-drain.sh" "archive scrub: cannot list the archives to scrub (grep rc=$rc); nothing is extracted this tick, retried next tick" 1
      return 0
    fi
    todo="${todo//$'\r'/}"
    if [ -n "$todo" ] && ! { printf '%s\n' "$todo" > "$SCRUB_TODO.tmp.$$" && mv -f "$SCRUB_TODO.tmp.$$" "$SCRUB_TODO"; } 2>/dev/null; then
      rm -f "$SCRUB_TODO.tmp.$$" 2>/dev/null
      DRAIN_SCRUB_HOLD=1
      sb_log_error "extract-drain.sh" "archive scrub: cannot write $SCRUB_TODO; nothing is extracted this tick, retried next tick" 1
      return 0
    fi
  fi
  # This tick's pick: pending archives in map order, then the rest in list order, BATCH names.
  pick=$({ printf '%s\n' "$DRAIN_MAP"; printf '%s\n' '--todo--'; printf '%s\n' "$todo"; } \
    | LC_ALL=C awk -F'\t' -v n="$batch" '
        sec == 0 && $0 == "--todo--" { sec = 1; next }
        sec == 0 { if ($1 != "" && $4 == "pending") pq[++np] = $1; next }
        $0 != "" { t[++nt] = $0; want[$0] = 1 }
        END {
          for (i = 1; i <= np && k < n; i++) if ((pq[i] in want) && !(pq[i] in out)) { out[pq[i]] = 1; print pq[i]; k++ }
          for (i = 1; i <= nt && k < n; i++) if (!(t[i] in out)) { out[t[i]] = 1; print t[i]; k++ }
        }')
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if [ ! -f "$TX_DIR/$b" ] || sb_scrub_archive_file "$TX_DIR/$b"; then scrubbed="$scrubbed$b"$'\n'; fi
  done < <(printf '%s\n' "$pick")
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    case $'\n'"$scrubbed" in *$'\n'"$b"$'\n'*) continue ;; esac
    left="$left$b"$'\n'; nleft=$((nleft + 1))
  done < <(printf '%s\n' "$todo")
  DRAIN_SCRUB_TODO="$left"
  if [ -z "$left" ]; then
    if : 2>/dev/null > "$SCRUB_MARK"; then
      rm -f "$SCRUB_TODO" 2>/dev/null
      sb_drain_tick archive-scrub "done: every archive written before 0.56.0 is secret-scrubbed"
    else
      sb_log_error "extract-drain.sh" "archive scrub: cannot write $SCRUB_MARK; the (idempotent) migration re-runs next tick" 1
    fi
    return 0
  fi
  if ! { printf '%s' "$left" > "$SCRUB_TODO.tmp.$$" && mv -f "$SCRUB_TODO.tmp.$$" "$SCRUB_TODO"; } 2>/dev/null; then
    rm -f "$SCRUB_TODO.tmp.$$" 2>/dev/null
    sb_log_error "extract-drain.sh" "archive scrub: cannot rewrite $SCRUB_TODO; the scrubbed archives are re-checked next tick (idempotent)" 1
  fi
  sb_drain_tick archive-scrub "${nleft} archive(s) still to scrub; they are not extracted until then"
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
    if jq -cR --argjson drop "[$drop]" 'fromjson? | select((.basename as $b | $drop | index($b)) == null)' \
         "$STATE" > "$tmp" && mv "$tmp" "$STATE"; then
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
  [ -z "$DRAIN_SCRUB_HOLD" ] || continue
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
# R2: the raw_line cursors (.last-archived-line-<slug>--<sid>, archive-first) age out the same way.
find "$BRAIN_DIR" -maxdepth 1 \( -name '.last-extracted-line-*' -o -name '.last-archived-line-*' \) -mtime +30 -delete 2>/dev/null || true
# Per-archive locks (sb_archive_lock, R2-F#3) left by a writer that died: the next writer steals
# one after 60 s, but an archive nobody writes again keeps its lock file. Swept after a day.
find "$TX_DIR" -maxdepth 1 -name '.*.txt.lock' -type f -mtime +1 -delete 2>/dev/null || true
# Observation ledgers (P0 rec 5): one file per session; after 7 days the
# session's transcript has been drained (or pruned past recovery) — sweep.
find "$BRAIN_DIR/observations" -maxdepth 1 -name '*.jsonl' -mtime +7 -delete 2>/dev/null || true
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
