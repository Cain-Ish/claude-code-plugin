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

# The whole point is to run outside a session — refuse the recursive-lock context.
if [ "${CLAUDECODE:-}" = "1" ]; then
  echo "extract-drain: refusing to run inside a Claude Code session" >&2
  exit 0
fi

# Defer (don't fail) while an interactive session holds the global OAuth lock.
if sb_drain_should_defer; then
  echo "extract-drain: interactive claude session active — deferring (OAuth lock held)" >&2
  exit 0
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
  STALE="${SB_DRAIN_LOCK_STALE:-1800}"; case "$STALE" in ''|*[!0-9]*) STALE=1800 ;; esac
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    lmtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
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

# --- Too-small fast-path (R1.2, HOOK-5) ---
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
    failed=$((failed+1))
    fails=$(sb_extraction_fails "$base" "$STATE"); fails=$((fails+1))
    if [ "$fails" -ge "$MAX_FAILS" ]; then
      printf '{"basename":%s,"ts":"%s","outcome":"error","fails":%s}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" "$fails" >> "$STATE"
    else
      printf '{"basename":%s,"ts":"%s","outcome":"retry","fails":%s}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" "$fails" >> "$STATE"
    fi
  fi
done < <(ls -1tr "$TX_DIR"/*.txt 2>/dev/null)

# --- GC sweeps (R1.2) ---
# Session-keyed extraction markers accumulate one file per session; sweep those
# untouched for 7+ days (their sessions are long over). Also sweeps legacy
# slug-keyed markers from pre-0.24.38.
find "$BRAIN_DIR" -maxdepth 1 -name '.last-extracted-line-*' -mtime +7 -delete 2>/dev/null || true
# Transcripts of our own nested extractor spawns (cwd = BRAIN_DIR/scratch →
# they all land in one ~/.claude/projects entry). Pure junk byproducts.
for pd in "$HOME"/.claude/projects/*second-brain-scratch*; do
  [ -d "$pd" ] && find "$pd" -name '*.jsonl' -mtime +3 -delete 2>/dev/null
done

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

# SP-B: deterministic consolidation upkeep — opt-in via config.json `auto_improve`. Runs
# here, inside the drainer's single-flight lock + defer guards, so no second timer is
# needed. Content-free only (validate/backfill/reindex); the script self-throttles. LLM
# authoring (raw-drain, dedup, enrich) stays on the explicit /second-brain:maintain path.
if [ "$(sb_config_bool .auto_improve off)" = "on" ]; then
  bash "$(dirname "$0")/maintain-deterministic.sh" >/dev/null 2>&1 || true
fi

# C (opt-in headless-LLM maintainer): a SEPARATE, stronger consent than auto_improve — it runs a
# headless `claude -p` consolidation (costs tokens, needs the OAuth grant) kernel-contained to a
# dream's staging by bubblewrap, leaving it for `dream_accept` review. Self-gated on auto_maintain
# + bwrap; weekly-throttled; never auto-accepts. Off by default.
if [ "$(sb_config_bool .auto_maintain off)" = "on" ]; then
  bash "$(dirname "$0")/maintain-llm-drain.sh" >/dev/null 2>&1 || true
fi
exit 0
