#!/bin/bash
# extract-drain.sh — out-of-band extraction drainer. Processes archived
# transcripts that were skipped by the in-session extractor (OAuth recursive
# lock). Run by a systemd user timer, OUTSIDE any Claude session.
#
#   SB_DRAIN_BATCH      transcripts per run (default 5)
#   SB_DRAIN_MAX_FAILS  retries before giving up on a transcript (default 3)
#   SB_EXTRACT_STUB     test-only: path to a stub called instead of the real
#                       extractor, as `$SB_EXTRACT_STUB <txt> <slug>`.
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

# Age (seconds) of the OLDEST not-yet-done .txt in TX_DIR; 0 if none pending.
# mtime via stat -c %Y (GNU) || stat -f %m (BSD/macOS); now via date +%s. The
# oldest-first ls -1tr mirrors the batch loop's own ordering.
sb_drain_oldest_pending_age() {
  local txd="$BRAIN_DIR/transcripts" state="$BRAIN_DIR/.extraction-state.jsonl"
  [ -d "$txd" ] || { printf '0'; return; }
  local now mt tf base age
  now=$(date +%s)
  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    base="${tf##*/}"
    sb_extraction_done "$base" "$state" && continue
    mt=$(stat -c %Y "$tf" 2>/dev/null || stat -f %m "$tf" 2>/dev/null || echo "$now")
    case "$mt" in ''|*[!0-9]*) mt="$now" ;; esac
    age=$(( now - mt )); [ "$age" -lt 0 ] && age=0
    printf '%d' "$age"; return        # ls -1tr is oldest-first -> first pending is oldest
  done < <(ls -1tr "$txd"/*.txt 2>/dev/null)
  printf '0'
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
fi

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

STATE="$BRAIN_DIR/.extraction-state.jsonl"   # TX_DIR set + checked (loudly) above the lock


do_extract() {  # $1 = txt, $2 = slug ; honors the test stub
  if [ -n "${SB_EXTRACT_STUB:-}" ]; then
    "$SB_EXTRACT_STUB" "$1" "$2"
  else
    sb_extract_transcript "$1" "$2"
  fi
}

now() { date -u +%FT%TZ; }

# --- Too-small fast-path (HOOK-5) ---
# Archives whose post-header body is tiny (e.g. 378-byte workflow-subagent
# stubs) have nothing extractable: mark them done WITHOUT an LLM spawn. They
# stay on disk for episodic search — only extraction is skipped. Runs before
# the batch loop so stubs never consume batch slots.
MIN_BODY="${SB_DRAIN_MIN_BYTES:-1024}"
case "$MIN_BODY" in ''|*[!0-9]*) MIN_BODY=1024 ;; esac
if [ "$MIN_BODY" -gt 0 ]; then
  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    base="${tf##*/}"
    sb_extraction_done "$base" "$STATE" && continue
    # Header guard (deep-review): on a file with no ^---$ terminator the sed
    # below deletes to EOF and reports 0 bytes — a malformed/foreign archive
    # would be silently misclassified as too-small. Leave it to the batch path.
    grep -q '^---$' "$tf" 2>/dev/null || continue
    body_bytes=$(sed '1,/^---$/d' "$tf" 2>/dev/null | wc -c | tr -d ' ')
    if [ "${body_bytes:-0}" -lt "$MIN_BODY" ]; then
      printf '{"basename":%s,"ts":"%s","outcome":"ok","reason":"too-small"}\n' \
        "$(jq -Rn --arg b "$base" '$b')" "$(now)" >> "$STATE"
    fi
  done < <(ls -1tr "$TX_DIR"/*.txt 2>/dev/null)
fi

processed=0
failed=0
# oldest-first by mtime (least-recently-modified). Sufficient for a drainer —
# everything pending is processed within a few batches regardless of order.
while IFS= read -r tf; do
  [ -n "$tf" ] || continue
  [ "$processed" -ge "$BATCH" ] && break
  base="${tf##*/}"
  sb_extraction_done "$base" "$STATE" && continue
  slug=$(sb_slug_from_archived_transcript "$tf")
  [ -n "$slug" ] || slug="unknown"
  if do_extract "$tf" "$slug"; then
    printf '{"basename":%s,"ts":"%s","outcome":"ok"}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" >> "$STATE"
    processed=$((processed+1))
  else
    fails=$(sb_extraction_fails "$base" "$STATE"); fails=$((fails+1))
    if [ "$fails" -ge "$MAX_FAILS" ] && [ "${SB_DRAIN_FLOOR:-on}" != "off" ] && sb_floor_transcript "$tf" "$slug"; then
      # Last-resort deterministic floor (P1): the LLM backend has failed MAX_FAILS times — rather
      # than quarantine this code-changing session with NOTHING captured, write the files-changed
      # baseline (no LLM) and mark it done. Counts as a real capture (processed), so the health
      # banner stays honest. Falls through to 'error' only if even the floor found no file change.
      printf '{"basename":%s,"ts":"%s","outcome":"ok","reason":"deterministic-floor"}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" >> "$STATE"
      processed=$((processed+1))
    elif [ "$fails" -ge "$MAX_FAILS" ]; then
      failed=$((failed+1))
      printf '{"basename":%s,"ts":"%s","outcome":"error","fails":%s}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" "$fails" >> "$STATE"
    else
      failed=$((failed+1))
      printf '{"basename":%s,"ts":"%s","outcome":"retry","fails":%s}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" "$fails" >> "$STATE"
    fi
  fi
done < <(ls -1tr "$TX_DIR"/*.txt 2>/dev/null)

# --- GC sweeps ---
# Session-keyed extraction markers accumulate one file per session; sweep those
# untouched for 30+ days (kept past the review skill's 14-day staleness window,
# and past week-long idle sessions, per deep-review). Also sweeps legacy
# slug-keyed markers (the retired marker-key scheme).
find "$BRAIN_DIR" -maxdepth 1 -name '.last-extracted-line-*' -mtime +30 -delete 2>/dev/null || true
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
# .extraction-state.jsonl ledger GC (state hygiene): the append-only done-set keeps
# one row per transcript forever, but transcripts are pruned by the 100-file / 5MB
# archive cap (sb_prune_transcripts) — leaving dead rows that grow the ledger without
# bound. Rewrite it keeping only rows whose basename still exists under transcripts/.
# Atomic tmp+mv; a torn/corrupt row is dropped by fromjson? (same tolerance the
# done/fails readers use). Lossless: a live transcript's terminal state is preserved.
if [ -s "$STATE" ]; then
  LIVE_BN=$(ls -1 "$TX_DIR" 2>/dev/null | jq -Rsc 'split("\n") | map(select(length>0))' 2>/dev/null)
  [ -n "$LIVE_BN" ] || LIVE_BN='[]'
  STATE_TMP="$STATE.tmp.$$"
  if jq -cR --argjson live "$LIVE_BN" \
       'fromjson? | select(.basename as $b | $live | index($b) != null)' \
       "$STATE" > "$STATE_TMP" 2>/dev/null; then
    mv "$STATE_TMP" "$STATE" 2>/dev/null || rm -f "$STATE_TMP" 2>/dev/null
  else
    rm -f "$STATE_TMP" 2>/dev/null
  fi
fi

# Don't clobber a real failure marker: only report ok if anything succeeded.
# A run where every extraction failed must surface status=fail so the
# SessionStart banner alerts the user (otherwise a broken drainer looks healthy).
# Report the REAL backend the per-transcript extractor recorded (local | claude-cli |
# anthropic-api), not a hardcoded label; default to "drainer" if none was written.
DRAIN_BACKEND=$(jq -r '.backend // "drainer"' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null); : "${DRAIN_BACKEND:=drainer}"
if [ "$processed" -eq 0 ] && [ "$failed" -gt 0 ]; then
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
