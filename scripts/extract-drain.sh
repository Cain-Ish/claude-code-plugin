#!/bin/bash
# extract-drain.sh — out-of-band extraction drainer. Processes archived
# transcripts that were skipped by the in-session extractor (OAuth recursive
# lock). Run by a systemd user timer, OUTSIDE any Claude session.
#
#   SB_DRAIN_BATCH      transcripts per run (default 5)
#   SB_DRAIN_MAX_FAILS  retries before giving up on a transcript (default 3)
#   SB_EXTRACT_STUB     test-only: path to a stub called instead of the real
#                       extractor, as `$SB_EXTRACT_STUB <txt> <slug>`.
# Always exits 0 (fail-soft).
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
    base=$(basename "$tf")
    sb_extraction_done "$base" "$state" && continue
    mt=$(stat -c %Y "$tf" 2>/dev/null || stat -f %m "$tf" 2>/dev/null || echo "$now")
    case "$mt" in ''|*[!0-9]*) mt="$now" ;; esac
    age=$(( now - mt )); [ "$age" -lt 0 ] && age=0
    printf '%d' "$age"; return        # ls -1tr is oldest-first -> first pending is oldest
  done < <(ls -1tr "$txd"/*.txt 2>/dev/null)
  printf '0'
}

# The forced escape is only SAFE+USEFUL when the attempt can BYPASS the global OAuth
# recursive-lock a live interactive session holds: ANTHROPIC_API_KEY (curl/API backstop —
# self-bounded via --max-time, lock-immune) OR the operator asserting the lock isn't global
# (SB_DRAIN_DEFER_PMODE_ONLY=1). Under pure OAuth + a held lock a forced `claude -p` hangs to
# the timeout and POISON-PILLS good transcripts (the regression commit ee8a74c's defer
# prevents) — so when neither holds we do NOT escape; the loud drain-health banner tells the
# operator to set a key or free a drain window. On the no-API-key (pmode) path we also require
# a timeout/gtimeout binary, since without ANTHROPIC_API_KEY sb_call_extractor wraps claude in
# `timeout` and would otherwise run UNBOUNDED if that binary is absent.
sb_drain_escape_safe() {
  [ -n "${ANTHROPIC_API_KEY:-}" ] && return 0
  [ "${SB_DRAIN_DEFER_PMODE_ONLY:-0}" = "1" ] || return 1
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || return 1
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
  echo "extract-drain: refusing to run inside a Claude Code session" >&2
  exit 0
fi

# Defer (don't fail) while an interactive session is live — UNLESS the backlog
# has starved past a bound, in which case we let exactly ONE drain through. The
# extractor is bounded (timeout x backend + poison-pill), so a forced attempt is
# safe under either premise: at worst it spends one SB_DRAIN_EXTRACT_TIMEOUT and
# at most one poison-retry per starved transcript — never an unbounded hang.
# SB_DRAIN_DEFER_PMODE_ONLY=1 additionally relaxes the BASE verdict to defer only
# on another live `claude -p` (verified-false hang premise; off by default so the
# empty-output quality guard for plain interactive sessions is preserved).
if [ "${SB_DRAIN_DEFER_PMODE_ONLY:-0}" = "1" ]; then
  _sb_defer_verdict() { sb_drain_pmode_present; }
else
  _sb_defer_verdict() { sb_drain_should_defer; }
fi
if _sb_defer_verdict; then
  if sb_drain_starved; then
    sb_drain_defer_reset
    echo "extract-drain: interactive claude active but backlog starved — forcing ONE escape drain" >&2
  else
    sb_drain_defer_bump
    echo "extract-drain: interactive claude session active — deferring (consecutive=$(sb_drain_defer_count))" >&2
    exit 0
  fi
else
  sb_drain_defer_reset
fi

BATCH="${SB_DRAIN_BATCH:-5}"
case "$BATCH" in ''|*[!0-9]*) BATCH=5 ;; esac
MAX_FAILS="${SB_DRAIN_MAX_FAILS:-3}"
case "$MAX_FAILS" in ''|*[!0-9]*) MAX_FAILS=3 ;; esac

TX_DIR="$BRAIN_DIR/transcripts"
STATE="$BRAIN_DIR/.extraction-state.jsonl"
[ -d "$TX_DIR" ] || exit 0

# Single-flight: a slow run must not overlap the next timer fire. Prefer flock
# (auto-releases on exit); fall back to an atomic mkdir-lock (stock macOS / Git-Bash
# have no flock(1)) with a staleness steal so a crashed run can't block forever.
if [ "${SB_DRAIN_FORCE_MKDIR_LOCK:-0}" != "1" ] && command -v flock >/dev/null 2>&1; then
  exec 9>"$BRAIN_DIR/.extract-drain.lock" || exit 0
  flock -n 9 || exit 0
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
      # rmdir+mkdir can "succeed", so write our PID and read it back — only the last
      # writer owns it; the other exits. (Bounded anyway: schedulers fire one/interval.)
      rmdir "$LOCK_DIR" 2>/dev/null; mkdir "$LOCK_DIR" 2>/dev/null || exit 0
      echo "$$" > "$LOCK_DIR/pid" 2>/dev/null
      [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] || exit 0
    else
      exit 0   # another run is active
    fi
  fi
  trap 'rm -f "$LOCK_DIR/pid" 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
fi

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
    base=$(basename "$tf")
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
  base=$(basename "$tf")
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

# SP-D retention GC: regenerable-only pruning (orphaned
# embeddings-cache entries, *.bak/*.tgz past retention.bak_ttl_days) must NOT
# depend on the SP-B auto_improve opt-in — gated behind it, the pruning is
# silently inert on every default install (bak_ttl_days does nothing).
[ -f "$(dirname "$0")/sb-prune-archives.sh" ] && bash "$(dirname "$0")/sb-prune-archives.sh" >/dev/null 2>&1 || true

# SP-B: deterministic consolidation upkeep — opt-in via config.json `auto_improve`. Runs
# here, inside the drainer's single-flight lock + defer guards, so no second timer is
# needed. Content-free only (validate/backfill/reindex); the script self-throttles. LLM
# authoring (raw-drain, dedup, enrich) stays on the explicit /second-brain:maintain path.
if [ "$(sb_config_bool .auto_improve on)" = "on" ]; then
  bash "$(dirname "$0")/maintain-deterministic.sh" >/dev/null 2>&1 || true
fi

# C (opt-in headless-LLM maintainer): a SEPARATE, stronger consent than auto_improve — it runs a
# headless `claude -p` consolidation (costs tokens, needs the OAuth grant) kernel-contained to a
# dream's staging by bubblewrap, leaving it for `dream_accept` review. Self-gated on auto_maintain
# + bwrap; weekly-throttled; never auto-accepts. Off by default.
if [ "$(sb_config_bool .auto_maintain on)" = "on" ]; then
  bash "$(dirname "$0")/maintain-llm-drain.sh" >/dev/null 2>&1 || true
fi

# P3a Task C2: out-of-band code-map regen (deterministic, content-free). Default on;
# the CLI self-gates on git-rev drift (drift.ts isStale) so a fresh tree costs one
# git probe — the heavy walk stays OUT of any Claude session (autonomy + cost).
# Runs inside this drainer's single-flight lock like the maintain blocks above.
# Kill switch: auto_codemap:false in config.json.
if [ "$(sb_config_bool .auto_codemap on)" = "on" ]; then
  # The drainer has no session cwd: target SB_CODEMAP_REPO when set, else the
  # most-recently-active project's root_path from the registry (the same source
  # session-load.sh trusts). Multi-repo users get each repo mapped as it becomes
  # the most recent — a documented v1 limit (plan Task C2).
  CM_REPO="${SB_CODEMAP_REPO:-}"
  if [ -z "$CM_REPO" ] && [ -f "$BRAIN_DIR/projects.jsonl" ]; then
    # -R + per-line fromjson?: ONE garbage line must not kill the whole slurp
    # (a plain -s aborts on it and misreports a present-but-corrupt registry as
    # empty — skeptic-review finding; corrupt projects.jsonl is a real class
    # here and sb_harden_projects_jsonl deliberately leaves unparseable files
    # intact). select(.root_path): the newest record may lack root_path (it is
    # optional) — an older mappable repo must still win. tr -d '\r': Windows jq
    # emits CRLF on stdout (would poison the -d test below with a CR suffix).
    CM_REPO=$(jq -Rrs 'split("\n") | map(fromjson? | select(type=="object") | select(.root_path)) | max_by(.last_session_iso // "") | .root_path // empty' \
      "$BRAIN_DIR/projects.jsonl" 2>/dev/null | tr -d '\r')
  fi
  if [ -n "$CM_REPO" ] && [ -d "$CM_REPO" ]; then
    # Flat dist path — the bundle lives at dist/tools/ (NOT dist/tools/codemap/).
    # Fail LOUD on a missing bundle: a silent
    # `[ -f ] … || true` here would no-op the whole regen forever on a path typo.
    CM_CLI="$(sb_plugin_root)/mcp/dist/tools/code-map-cli.bundle.js"
    if [ -f "$CM_CLI" ] && command -v node >/dev/null 2>&1; then
      # Real failures stay LOUD (error-log). The CLI is a fail-soft boundary —
      # it ALWAYS exits 0 and reports failures as 'code-map: ERROR …' on
      # stderr — so `|| log` alone is DEAD CODE for every failure the CLI can
      # actually hit (skeptic-review must-fix: an unwritable store would
      # silently no-op every tick forever). Capture stderr and match the ERROR
      # marker; `||` still covers node-binary/bundle-load crashes (nonzero).
      CM_ERR=$(CLAUDE_PROJECT_DIR="$CM_REPO" node "$CM_CLI" 2>&1 >/dev/null) || \
        sb_log_error "extract-drain.sh" "codemap regen crashed for $CM_REPO: ${CM_ERR:0:200}" 1
      case "$CM_ERR" in *"code-map: ERROR"*)
        sb_log_error "extract-drain.sh" "codemap regen failed for $CM_REPO: ${CM_ERR:0:200}" 1 ;;
      esac
    else
      sb_log_error "extract-drain.sh" "codemap regen skipped: bundle or node missing ($CM_CLI)" 1
    fi
  else
    # NORMAL state (empty registry pre-first-session), never a silent no-op —
    # but the drainer ticks every 30 min, so an error-log line here is the
    # failed-dream-banner spam class. gate=* + ec=0 routes it to the audit-log
    # TRACE channel (R6b, sb_log_error).
    sb_log_error "extract-drain.sh" "gate=codemap-skip: no target repo (SB_CODEMAP_REPO unset; registry empty or root_path missing: '${CM_REPO:-}')" 0
  fi
fi
exit 0
